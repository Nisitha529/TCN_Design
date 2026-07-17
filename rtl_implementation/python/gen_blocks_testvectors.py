"""
gen_blocks_testvectors.py
Simulate TCN Blocks 1, 2, 3 in integer arithmetic matching the RTL.

Block configs:
  Block 1: in=4, out=4,  K=3, dil=2, HAS_RES_CONV=0 (identity)
  Block 2: in=4, out=8,  K=3, dil=4, HAS_RES_CONV=1
  Block 3: in=8, out=8,  K=3, dil=8, HAS_RES_CONV=0 (identity)

Fixed-point convention (Q8.8):
  float_val = int16_val / 256
  MAC: INT16 * INT16 → INT32 (Q16.16)
  After MAC: right-shift by FRAC_BITS=8 → Q8.8
  Add Q8.8 bias → Q8.8 result
  ReLU: clip to [0, 32767]
"""

import os

HEX_DIR  = "../weights"
TV_DIR   = "../testvectors"
FRAC_BITS = 8
DATA_MIN  = -32768
DATA_MAX  =  32767

os.makedirs(TV_DIR, exist_ok=True)


def load_s16(path):
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
    xs      : list of length-in_ch lists (one per time step)
    weights : flat list, layout [out_ch][in_ch][k] (out_ch-major)
    bias    : list of out_ch values
    Returns : list of length-out_ch lists (one per time step)
    """
    depth = (kernel_size - 1) * dilation
    shift_regs = [[0] * (depth + 1) for _ in range(in_ch)]
    results = []

    for x in xs:
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
            acc = acc >> frac_bits
            acc += bias[oc]
            acc = max(DATA_MIN, min(DATA_MAX, acc))
            if apply_relu:
                acc = max(0, acc)
            out.append(acc)
        results.append(out)

    return results


def simulate_block(blk, xs_raw):
    """
    Simulate a single TCN block.
    blk    : dict with keys in_ch, out_ch, K, dil, has_res
    xs_raw : list of per-sample input vectors (each length in_ch)
    Returns: list of per-sample output vectors (each length out_ch)
    """
    n     = blk["n"]
    in_ch = blk["in_ch"]
    out_ch= blk["out_ch"]
    K     = blk["K"]
    dil   = blk["dil"]

    w1 = load_s16(f"{HEX_DIR}/block{n}_conv1_weights.hex")
    b1 = load_s16(f"{HEX_DIR}/block{n}_conv1_bias.hex")
    w2 = load_s16(f"{HEX_DIR}/block{n}_conv2_weights.hex")
    b2 = load_s16(f"{HEX_DIR}/block{n}_conv2_bias.hex")

    conv1_out = rtl_causal_conv(xs_raw, w1, b1,
                                in_ch=in_ch, out_ch=out_ch,
                                kernel_size=K, dilation=dil,
                                frac_bits=FRAC_BITS, apply_relu=True)

    conv2_out = rtl_causal_conv(conv1_out, w2, b2,
                                in_ch=out_ch, out_ch=out_ch,
                                kernel_size=K, dilation=dil,
                                frac_bits=FRAC_BITS, apply_relu=True)

    if blk["has_res"]:
        wr = load_s16(f"{HEX_DIR}/block{n}_res_weights.hex")
        br = load_s16(f"{HEX_DIR}/block{n}_res_bias.hex")
        res_out = rtl_causal_conv(xs_raw, wr, br,
                                  in_ch=in_ch, out_ch=out_ch,
                                  kernel_size=1, dilation=1,
                                  frac_bits=FRAC_BITS, apply_relu=False)
    else:
        # identity: res = x, padded/truncated to out_ch (in_ch == out_ch here)
        res_out = [list(x) for x in xs_raw]

    block_out = []
    for t in range(len(xs_raw)):
        row = []
        for ch in range(out_ch):
            v = conv2_out[t][ch] + res_out[t][ch]
            v = max(DATA_MIN, min(DATA_MAX, v))
            v = max(0, v)
            row.append(v)
        block_out.append(row)

    return block_out


BLOCKS = [
    dict(n=1, in_ch=4, out_ch=4, K=3, dil=2, has_res=False),
    dict(n=2, in_ch=4, out_ch=8, K=3, dil=4, has_res=True),
    dict(n=3, in_ch=8, out_ch=8, K=3, dil=8, has_res=False),
]

N_SAMPLES = 5


def main():
    for blk in BLOCKS:
        n      = blk["n"]
        in_ch  = blk["in_ch"]
        out_ch = blk["out_ch"]

        # constant-1.0 input: all channels = 256 (= 1.0 in Q8.8)
        xs_raw = [[256] * in_ch for _ in range(N_SAMPLES)]

        out = simulate_block(blk, xs_raw)

        tag = f"b{n}_const"
        write_hex_s16(f"{TV_DIR}/{tag}_input.hex",
                      [v for step in xs_raw for v in step])
        write_hex_s16(f"{TV_DIR}/{tag}_expected.hex",
                      [v for step in out for v in step])

        print(f"\nBlock {n}: in={in_ch} out={out_ch} K={blk['K']} "
              f"dil={blk['dil']} has_res={blk['has_res']}")
        for t, row in enumerate(out):
            print(f"  t={t}: {row}")


if __name__ == "__main__":
    main()
