#!/usr/bin/env python3
"""
gen_conv_vectors.py -- random test vectors for win_conv, from the golden model.

Writes, into OUTDIR:
  w.hex  weight words (P lanes, lane 0 at the LSB end), address (og*CI+i)*K+k
  b.hex  biases, one per line
  x.hex  NV input windows, one per line, position-major x[(t*CI+i)*16 +: 16]
  y.hex  NV expected outputs, same layout with CO channels
The expected outputs come from qos_tcn/quant.py's IntModel.conv -- the same
function the full golden model uses -- so this checks the RTL against it.

  gen_conv_vectors.py OUTDIR CI CO K D N P RELU [NV]
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "qos_tcn"))
from quant import IntModel  # noqa: E402

DW = 16


def hexw(v, bits):
    return format(int(v) & ((1 << bits) - 1), f"0{bits // 4}x")


def pack(vals, bits=DW):
    """vals[0] at the LSB end."""
    word = 0
    for j, v in enumerate(vals):
        word |= (int(v) & ((1 << bits) - 1)) << (j * bits)
    return format(word, f"0{len(vals) * bits // 4}x")


def main():
    out, ci, co, k, d, n, p, relu = sys.argv[1], *map(int, sys.argv[2:9])
    nv = int(sys.argv[9]) if len(sys.argv) > 9 else 50
    rng = np.random.default_rng(ci * 1000 + co * 10 + k + d)
    os.makedirs(out, exist_ok=True)
    w = np.clip(np.round(rng.normal(0, 0.25, (co, ci, k)) * 256), -32768, 32767).astype(np.int64)
    b = np.clip(np.round(rng.normal(0, 0.5, co) * 256), -32768, 32767).astype(np.int64)
    # inputs: mostly non-negative (post-ReLU), some negative, a few large
    x = rng.integers(-300, 1500, (nv, ci, n)).astype(np.int64)
    x[rng.random(x.shape) < 0.3] = 0
    x[0] = 32767                                    # a saturating case
    x[1] = -32768
    y = IntModel.conv(x, w, b, d, bool(relu))        # [nv, co, n]

    with open(os.path.join(out, "w.hex"), "w") as f:
        for og in range(co // p):
            for i in range(ci):
                for kk in range(k):
                    f.write(pack([w[og * p + lane, i, kk] for lane in range(p)]) + "\n")
    with open(os.path.join(out, "b.hex"), "w") as f:
        f.writelines(hexw(v, DW) + "\n" for v in b)
    with open(os.path.join(out, "x.hex"), "w") as f:
        for v in range(nv):
            f.write(pack([x[v, i, t] for t in range(n) for i in range(ci)]) + "\n")
    with open(os.path.join(out, "y.hex"), "w") as f:
        for v in range(nv):
            f.write(pack([y[v, o, t] for t in range(n) for o in range(co)]) + "\n")
    print(f"{nv} vectors: CI={ci} CO={co} K={k} D={d} N={n} P={p} RELU={relu}  "
          f"(saturated outputs: {int(np.sum((y == 32767) | (y == -32768)))})")


if __name__ == "__main__":
    main()
