#!/usr/bin/env python3
"""
gen_requant_vectors.py -- test vectors for rtl/primitives/requant.sv.

The expected values use exactly the operations of IntModel.conv in
qos_tcn/quant.py: numpy's arithmetic >> on int64, then clip to int16, then
(for conv1/conv2) max(., 0). So the RTL is checked against the golden model's
own arithmetic, not against a re-statement of it.

Writes OUTDIR/rq.hex, one vector per line:  acc(8 hex) bias(4) y_relu(4) y_lin(4)

  gen_requant_vectors.py OUTDIR [N_RANDOM]
"""
import os
import sys

import numpy as np

ACC_W, DW, FRAC = 32, 16, 8
I16 = (-(1 << 15), (1 << 15) - 1)


def main():
    out = sys.argv[1]
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 200_000
    rng = np.random.default_rng(2026)
    os.makedirs(out, exist_ok=True)

    lo, hi = -(1 << (ACC_W - 1)), (1 << (ACC_W - 1)) - 1
    corners_acc = [0, 1, -1, 255, 256, 257, -255, -256, -257, lo, hi, lo + 1, hi - 1,
                   (I16[1] << FRAC), (I16[1] << FRAC) + 255, (I16[1] + 1) << FRAC,
                   (I16[0] << FRAC), (I16[0] << FRAC) - 1, ((I16[0] - 1) << FRAC)]
    corners_b = [0, 1, -1, I16[0], I16[1]]
    acc = [a for a in corners_acc for _ in corners_b]
    bias = [b for _ in corners_acc for b in corners_b]
    # values near the saturation edges, where off-by-one errors live
    edge = np.concatenate([rng.integers((I16[1] - 300) << FRAC, (I16[1] + 300) << FRAC, n // 10),
                           rng.integers((I16[0] - 300) << FRAC, (I16[0] + 300) << FRAC, n // 10)])
    rand = np.concatenate([rng.integers(lo, hi, n // 2, endpoint=True),
                           rng.integers(-(1 << 22), 1 << 22, n - n // 2)])     # typical magnitudes
    acc = np.concatenate([np.array(acc, np.int64), edge, rand]).astype(np.int64)
    bias = np.concatenate([np.array(bias, np.int64),
                           rng.integers(I16[0], I16[1], len(acc) - len(bias), endpoint=True)]).astype(np.int64)

    y_lin = np.clip((acc >> FRAC) + bias, *I16)          # quant.py: sat((acc >> 8) + b)
    y_relu = np.maximum(y_lin, 0)                         # quant.py: relu

    with open(os.path.join(out, "rq.hex"), "w") as f:
        for a, b, r, l in zip(acc, bias, y_relu, y_lin):
            f.write(f"{int(a) & 0xFFFFFFFF:08x}{int(b) & 0xFFFF:04x}{int(r) & 0xFFFF:04x}{int(l) & 0xFFFF:04x}\n")
    print(len(acc))


if __name__ == "__main__":
    main()
