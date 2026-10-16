#!/usr/bin/env python3
"""
quant.py -- the integer golden model: exactly what the TCN v2 RTL computes.

Takes a trained float QosTCN, folds BatchNorm into the convolutions, quantises
every weight, bias and lookup table to Q8.8 (int16), and runs inference in
integers only. The RTL must reproduce `int_forward` bit for bit; the float
model is only for training.

Arithmetic (all Q8.8, FRAC = 8):
  lookup     x[c, t] = table_c[bin(t)]                    int16
  conv       acc = sum_{i,k} w[o,i,k] * x[i, t - k*d]      int32 (assert, no wrap)
             (positions before 0 are zero -- causal padding)
             y = sat16((acc >> 8) + b[o])                 arithmetic shift, floor
             y = relu(y) for conv1 and conv2; residual 1x1 has no ReLU
  block      out = relu(sat16(conv2 + res))
  head       flatten [C, N] -> logits = sat32((sum w*h) >> 8) + b, argmax
Saturation (not wrap-around) on every narrowing; the ECG RTL truncated, which
wraps on overflow -- v2 saturates.

  python3 quant.py results/first-sweep/model_N8.pt --n 8      # accuracy, float vs int
"""
import argparse

import numpy as np
import torch

from hw_encoding import FRAC_BITS
from model import QosTCN

Q = 1 << FRAC_BITS
I16 = (-(1 << 15), (1 << 15) - 1)
I32 = (-(1 << 31), (1 << 31) - 1)


def q16(a):
    return np.clip(np.round(np.asarray(a, np.float64) * Q), *I16).astype(np.int64)


def sat(a, lim):
    return np.clip(a, *lim)


def fold_bn(conv, bn):
    """Conv1d + eval-mode BatchNorm1d -> one conv's (weight, bias), float."""
    w = conv.weight.detach().double().numpy()
    b = conv.bias.detach().double().numpy() if conv.bias is not None else np.zeros(w.shape[0])
    s = (bn.weight / torch.sqrt(bn.running_var + bn.eps)).detach().double().numpy()
    return w * s[:, None, None], (b - bn.running_mean.detach().double().numpy()) * s + bn.bias.detach().double().numpy()


class IntModel:
    """Quantised parameters of a QosTCN, plus its integer forward pass."""

    def __init__(self, model: QosTCN, n: int):
        model = model.eval()
        self.n = n
        if model.head_mode != "flatten":
            raise ValueError("the RTL head is flatten; train with --head flatten")
        e = model.embed
        self.tables = None if e is None else [q16(t.weight.detach().numpy()) for t in (e.size, e.ipt, e.dir, e.push)]
        self.blocks = []
        for blk in model.blocks:
            w1, b1 = fold_bn(blk.conv1.conv, blk.bn1)
            w2, b2 = fold_bn(blk.conv2.conv, blk.bn2)
            res = None
            if isinstance(blk.res, torch.nn.Conv1d):
                res = (q16(blk.res.weight.detach().numpy()), q16(blk.res.bias.detach().numpy()))
            self.blocks.append(dict(d=blk.conv1.conv.dilation[0], k=blk.conv1.conv.kernel_size[0],
                                    w1=q16(w1), b1=q16(b1), w2=q16(w2), b2=q16(b2), res=res))
        self.head_w = q16(model.head.weight.detach().numpy())
        self.head_b = q16(model.head.bias.detach().numpy())

    # ── integer pieces, each one an RTL stage ────────────────────────────────
    def lookup(self, xq):
        """[B, 4, n] Q8.8 record inputs -> [B, C_in, n] table outputs (int)."""
        if self.tables is None:
            return xq.astype(np.int64)
        size_b = np.clip(xq[:, 1] >> 1, 0, 255)
        ipt_b = np.clip(xq[:, 0] >> 6, 0, 67)
        dir_b = np.where(xq[:, 2] > 0, 2, np.where(xq[:, 2] < 0, 1, 0))
        push_b = (xq[:, 3] > 0).astype(np.int64)
        parts = [t[i] for t, i in zip(self.tables, (size_b, ipt_b, dir_b, push_b))]   # [B, n, e]
        return np.concatenate(parts, axis=2).transpose(0, 2, 1)

    @staticmethod
    def conv(x, w, b, d, relu):
        """Causal dilated conv on int Q8.8: x [B, Ci, n], w [Co, Ci, K]."""
        B, ci, n = x.shape
        co, _, k = w.shape
        acc = np.zeros((B, co, n), np.int64)
        for kk in range(k):
            sh = (k - 1 - kk) * d             # tap kk reads position t - sh
            if sh >= n:
                continue
            xs = np.zeros_like(x)
            xs[:, :, sh:] = x[:, :, :n - sh]
            acc += np.einsum("oi,bit->bot", w[:, :, kk], xs)
        assert acc.min() >= I32[0] and acc.max() <= I32[1], "accumulator would wrap"
        y = sat((acc >> FRAC_BITS) + b[None, :, None], I16)
        return np.maximum(y, 0) if relu else y

    def int_forward(self, xq):
        """[B, 4, n] int16 Q8.8 inputs -> (logits int64 [B, classes], argmax)."""
        h = self.lookup(np.asarray(xq, np.int64))
        for blk in self.blocks:
            y = self.conv(h, blk["w1"], blk["b1"], blk["d"], True)
            y = self.conv(y, blk["w2"], blk["b2"], blk["d"], True)
            r = h if blk["res"] is None else self.conv(h, blk["res"][0][:, :, None] if blk["res"][0].ndim == 2
                                                         else blk["res"][0], blk["res"][1], 1, False)
            h = np.maximum(sat(y + r, I16), 0)
        flat = h.reshape(h.shape[0], -1)                                  # [B, C*n], channel-major
        acc = flat @ self.head_w.T
        assert np.abs(acc).max() <= I32[1], "head accumulator would wrap"
        logits = sat((acc >> FRAC_BITS) + self.head_b[None, :], I32)
        return logits, logits.argmax(1)


def main():
    import train as T
    ap = argparse.ArgumentParser()
    ap.add_argument("model_pt")
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--channels", type=int, nargs="+", default=[32, 32, 64])
    ap.add_argument("--per-day", type=int, default=20000)
    args = ap.parse_args()
    m = QosTCN(channels=tuple(args.channels), n_classes=5, head="flatten", n=args.n, embed=True)
    m.load_state_dict(torch.load(args.model_pt, map_location="cpu"))
    m.eval()
    x, y, _, _ = T.load(T.days("2022-10-10", "2022-10-16"), args.per_day, args.n, 7)
    with torch.no_grad():
        pf = m(torch.from_numpy(x.astype(np.float32) / 256.0)).argmax(1).numpy()
    im = IntModel(m, args.n)
    pi = np.concatenate([im.int_forward(x[i:i + 4096])[1] for i in range(0, len(x), 4096)])
    print(f"N={args.n}: float  acc {np.mean(pf == y):.4f}  macro-F1 {T.macro_f1(y, pf, 5):.4f}")
    print(f"N={args.n}: int16  acc {np.mean(pi == y):.4f}  macro-F1 {T.macro_f1(y, pi, 5):.4f}")
    print(f"        float/int agree on {100 * np.mean(pf == pi):.2f}% of flows")


if __name__ == "__main__":
    main()
