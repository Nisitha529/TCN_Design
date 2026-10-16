#!/usr/bin/env python3
"""
export_rtl.py -- a trained QosTCN -> the hex files qos_tcn_engine reads, plus
test vectors from real flows with the golden model's answers.

  python3 export_rtl.py results/first-sweep/model_N4.pt --n 4 --out ../rtl_implementation/weights/qos_N4

Writes into --out:
  emb_size.hex emb_ipt.hex emb_dir.hex emb_push.hex     lookup tables (dim 0 at the LSB end)
  b{1,2,3}_c1_{w,b}.hex b{1,2,3}_c2_{w,b}.hex b{1,2,3}_res_{w,b}.hex
                                                         win_conv layout: word (og*CI+i)*K+k,
                                                         P lanes, lane 0 at the LSB end
  head_w.hex head_b.hex                                  word j = c*N+t, class 0 at the LSB end
  engine_params.txt                                      the qos_tcn_engine parameters to use
  tv_window.hex tv_mask.hex tv_class.hex tv_logits.hex   test vectors (one flow per line)

The weights are the folded, Q8.8-quantised ones from quant.IntModel -- the same
numbers the golden model computes with -- so the RTL can be checked bit for bit.
"""
import argparse
import os

import numpy as np
import torch

from hw_encoding import encode_inputs, pack_slot
from model import QosTCN
from quant import IntModel

DW = 16


def pack(vals, bits=DW):
    word = 0
    for j, v in enumerate(vals):
        word |= (int(v) & ((1 << bits) - 1)) << (j * bits)
    return format(word, f"0{max(1, len(vals) * bits // 4)}x")


def write_lines(path, lines):
    with open(path, "w") as f:
        f.writelines(line + "\n" for line in lines)


def conv_words(w, p):
    """w [CO, CI, K] -> win_conv weight words."""
    co, ci, k = w.shape
    return [pack([w[og * p + lane, i, kk] for lane in range(p)])
            for og in range(co // p) for i in range(ci) for kk in range(k)]


def main():
    import train as T
    ap = argparse.ArgumentParser()
    ap.add_argument("model_pt")
    ap.add_argument("--n", type=int, required=True)
    ap.add_argument("--channels", type=int, nargs="+", default=[32, 32, 64])
    ap.add_argument("--lanes", type=int, nargs=3, default=None,
                    help="P per block (default: half of each block's channels)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--vectors", type=int, default=200)
    args = ap.parse_args()

    m = QosTCN(channels=tuple(args.channels), n_classes=5, head="flatten", n=args.n, embed=True)
    m.load_state_dict(torch.load(args.model_pt, map_location="cpu"))
    m.eval()
    im = IntModel(m, args.n)
    lanes = args.lanes or [max(1, c // 2) for c in args.channels]
    os.makedirs(args.out, exist_ok=True)
    o = lambda name: os.path.join(args.out, name)  # noqa: E731

    for name, tab in zip(("size", "ipt", "dir", "push"), im.tables):
        write_lines(o(f"emb_{name}.hex"), [pack(row) for row in tab])
    for bi, (blk, p) in enumerate(zip(im.blocks, lanes), 1):
        write_lines(o(f"b{bi}_c1_w.hex"), conv_words(blk["w1"], p))
        write_lines(o(f"b{bi}_c1_b.hex"), [pack([v]) for v in blk["b1"]])
        write_lines(o(f"b{bi}_c2_w.hex"), conv_words(blk["w2"], p))
        write_lines(o(f"b{bi}_c2_b.hex"), [pack([v]) for v in blk["b2"]])
        if blk["res"] is not None:
            write_lines(o(f"b{bi}_res_w.hex"), conv_words(blk["res"][0], p))
            write_lines(o(f"b{bi}_res_b.hex"), [pack([v]) for v in blk["res"][1]])
        else:                                    # identity residual: files unused, keep $readmemh quiet
            write_lines(o(f"b{bi}_res_w.hex"), ["0"])
            write_lines(o(f"b{bi}_res_b.hex"), ["0"])
    ncls = im.head_w.shape[0]
    write_lines(o("head_w.hex"), [pack(im.head_w[:, j]) for j in range(im.head_w.shape[1])])
    write_lines(o("head_b.hex"), [pack([v]) for v in im.head_b])

    emb = m.embed
    params = dict(N=args.n, ES=emb.size.embedding_dim, EI=emb.ipt.embedding_dim, ED=emb.dir.embedding_dim,
                  EP=emb.push.embedding_dim, C1=args.channels[0], C2=args.channels[1], C3=args.channels[2],
                  D1=im.blocks[0]["d"], D2=im.blocks[1]["d"], D3=im.blocks[2]["d"], K=im.blocks[0]["k"],
                  P1=lanes[0], P2=lanes[1], P3=lanes[2], NCLS=ncls)
    write_lines(o("engine_params.txt"), [f"{k}={v}" for k, v in params.items()])

    # ── test vectors: real October flows, as flow_window would deliver them ──
    n = args.n
    rng = np.random.default_rng(11)
    z = np.load(os.path.join(T.CACHE, "tls-20221012.npz"))
    pick = rng.choice(len(z["qos"]), size=args.vectors, replace=False)
    # make sure short flows (padding) are well represented
    short = np.flatnonzero(z["plen"] < n)
    if len(short):
        pick[: args.vectors // 4] = rng.choice(short, size=args.vectors // 4, replace=False)
    plen = z["plen"][pick]
    valid = np.arange(n)[None, :] < plen[:, None]
    ipt, size, dirb, push = (z[f][pick, :n] for f in ("ipt_u", "size", "dirb", "push"))
    logits, cls = im.int_forward(encode_inputs(ipt, size, dirb, push, valid))
    win_lines, mask_lines = [], []
    for v in range(len(pick)):
        slots = [pack_slot(size[v, t], dirb[v, t], ipt[v, t], push[v, t]) if valid[v, t] else 0 for t in range(n)]
        win_lines.append(pack(slots, 32))
        mask_lines.append(format(int(sum(1 << t for t in range(n) if valid[v, t])), "x"))
    write_lines(o("tv_window.hex"), win_lines)
    write_lines(o("tv_mask.hex"), mask_lines)
    write_lines(o("tv_class.hex"), [format(int(c), "x") for c in cls])
    write_lines(o("tv_logits.hex"), [pack(row, 32) for row in logits])
    print(f"exported to {args.out}: {params}")
    print(f"{len(pick)} test vectors ({int((plen < n).sum())} short flows); "
          f"golden class counts {np.bincount(cls, minlength=ncls).tolist()}")


if __name__ == "__main__":
    main()
