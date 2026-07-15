"""
gen_block0_testvectors.py
Simulate TCN Block 0 in integer arithmetic that exactly matches the RTL.

Block 0: in_ch=1, out_ch=4, kernel_size=3, dilation=1, FRAC_BITS=8, HAS_RES_CONV=1

Fixed-point convention (Q8.8):
  float_val = int16_val / 256
  MAC accumulates INT16 * INT16 → INT32 (Q16.16)
  After MAC: right-shift accumulator by 8 → back to Q8.8 scale
  Add Q8.8 bias → Q8.8 result
  ReLU: clip to [0, 32767]

Writes:
  ../testvectors/b0_input_*.hex      - one per test sequence
  ../testvectors/b0_expected_*.hex   - expected block0 output per sequence
  ../testvectors/b0_vectors.txt      - human-readable summary
"""

import os
import numpy as np

HEX_DIR = "../weights"
TV_DIR  = "../testvectors"

FRAC_BITS = 8
IN_CH     = 1
OUT_CH    = 4
KERNEL    = 3
DILATION  = 1
DATA_MIN  = -32768
DATA_MAX  =  32767

os.makedirs(TV_DIR, exist_ok=True)


def load_s16(path):
    """Load a hex file as a list of signed 16-bit integers."""
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16)
            if v >= 0x8000:
                v -= 0x10000
            vals.append(v)
    return vals


def write_hex_s16(path, vals):
    with open(path, "w") as f:
        for v in vals:
            f.write(f"{int(v) & 0xFFFF:04x}\n")


def rtl_causal_conv(xs, weights, bias, in_ch, out_ch, kernel_size,
                    dilation=1, frac_bits=8, apply_relu=True):
    """
    Simulate causal_conv1d in integer arithmetic matching the RTL.
    xs: list of length-in_ch lists (one per time step)
    weights: flat list, layout [out_ch][in_ch][k] (out_ch-major)
    bias: list of out_ch values
    Returns: list of length-out_ch lists (one per time step)
    """
    depth = (kernel_size - 1) * dilation
    # shift_reg[ch][0..depth]: index 0 = newest, depth = oldest
    shift_regs = [[0] * (depth + 1) for _ in range(in_ch)]
    results = []

    for x in xs:
        # update shift registers (newest at index 0)
        for ch in range(in_ch):
            shift_regs[ch] = [x[ch]] + shift_regs[ch][:-1]

        out = []
        for oc in range(out_ch):
            acc = 0
            for ic in range(in_ch):
                for k in range(kernel_size):
                    tap = shift_regs[ic][k * dilation]
                    w_idx = oc * (in_ch * kernel_size) + ic * kernel_size + k
                    acc += tap * weights[w_idx]
            # right-shift accumulator (Q16.16 → Q8.8)
            acc = acc >> frac_bits        # Python >> is arithmetic for signed ints
            # add bias (Q8.8)
            acc += bias[oc]
            # saturate to INT16
            acc = max(DATA_MIN, min(DATA_MAX, acc))
            # relu
            if apply_relu:
                acc = max(0, acc)
            out.append(acc)
        results.append(out)

    return results


def simulate_block0(xs):
    """
    Run xs (list of INT16 scalar values) through Block 0.
    Returns list of length-4 output vectors (one per time step).
    """
    # ── Load weights ───────────────────────────────────────────────────────
    w1 = load_s16(f"{HEX_DIR}/block0_conv1_weights.hex")   # 12 entries
    b1 = load_s16(f"{HEX_DIR}/block0_conv1_bias.hex")       # 4 entries
    w2 = load_s16(f"{HEX_DIR}/block0_conv2_weights.hex")   # 48 entries
    b2 = load_s16(f"{HEX_DIR}/block0_conv2_bias.hex")       # 4 entries
    wr = load_s16(f"{HEX_DIR}/block0_res_weights.hex")     # 4 entries (K=1)
    br = load_s16(f"{HEX_DIR}/block0_res_bias.hex")         # 4 entries

    xs_vec = [[v] for v in xs]    # wrap each scalar in a list (1 channel)

    # conv1: in=1, out=4, K=3, dil=1, relu
    conv1_out = rtl_causal_conv(xs_vec, w1, b1,
                                in_ch=IN_CH, out_ch=OUT_CH,
                                kernel_size=KERNEL, dilation=DILATION,
                                frac_bits=FRAC_BITS, apply_relu=True)

    # conv2: in=4, out=4, K=3, dil=1, relu
    conv2_out = rtl_causal_conv(conv1_out, w2, b2,
                                in_ch=OUT_CH, out_ch=OUT_CH,
                                kernel_size=KERNEL, dilation=DILATION,
                                frac_bits=FRAC_BITS, apply_relu=True)

    # residual 1×1: in=1, out=4, K=1, NO relu
    res_out = rtl_causal_conv(xs_vec, wr, br,
                              in_ch=IN_CH, out_ch=OUT_CH,
                              kernel_size=1, dilation=1,
                              frac_bits=FRAC_BITS, apply_relu=False)

    # final: relu(conv2 + res)
    block_out = []
    for t in range(len(xs)):
        out = []
        for ch in range(OUT_CH):
            v = conv2_out[t][ch] + res_out[t][ch]
            v = max(DATA_MIN, min(DATA_MAX, v))   # saturate
            v = max(0, v)                           # relu
            out.append(v)
        block_out.append(out)

    return block_out


def main():
    # ── Test sequences ──────────────────────────────────────────────────────
    # Values are in Q8.8 scale: 256 = 1.0 float
    sequences = {
        "const_pos":   [256] * 5,                  # 1.0 repeated
        "const_neg":   [-256] * 5,                 # -1.0 (relu → 0 expected on most outputs)
        "ramp":        [i * 64 for i in range(5)], # 0, 0.25, 0.5, 0.75, 1.0
        "alternating": [256, -256, 256, -256, 256], # alternating ±1.0
    }

    log_lines = []
    log_lines.append(f"Block0 test vectors: Q8.8 (FRAC_BITS={FRAC_BITS})")
    log_lines.append(f"in_ch={IN_CH} out_ch={OUT_CH} K={KERNEL} dil={DILATION} HAS_RES=1")
    log_lines.append("=" * 60)

    for name, xs in sequences.items():
        out = simulate_block0(xs)

        # write input hex (flat: one entry per time step)
        write_hex_s16(f"{TV_DIR}/b0_input_{name}.hex", xs)

        # write output hex (flat: out_ch values per time step, channel-major within step)
        flat_out = [v for step in out for v in step]
        write_hex_s16(f"{TV_DIR}/b0_expected_{name}.hex", flat_out)

        log_lines.append(f"\n[{name}]")
        log_lines.append(f"  inputs (Q8.8 int):  {xs}")
        for t, step in enumerate(out):
            step_f = [f"{v/256:.3f}" for v in step]
            log_lines.append(f"  t={t} out(int)={step}  (~float:{step_f})")

    with open(f"{TV_DIR}/b0_vectors.txt", "w") as f:
        f.write("\n".join(log_lines) + "\n")

    print("\n".join(log_lines))
    print(f"\nWritten to {TV_DIR}/")


if __name__ == "__main__":
    main()
