"""
gen_full_chain.py
Simulate the full ECG TCN in Q8.8 integer arithmetic matching the RTL.

Chain: Block0 → Block1 → Block2 → Block3 → GAP(WINDOW_LEN) → Linear Head
Output: N_CLASSES=3 class scores (Q8.8 integers, no final activation)

Block configs:
  B0: in=1,  out=4,  K=3, dil=1, HAS_RES=1
  B1: in=4,  out=4,  K=3, dil=2, HAS_RES=0
  B2: in=4,  out=8,  K=3, dil=4, HAS_RES=1
  B3: in=8,  out=8,  K=3, dil=8, HAS_RES=0

GAP:  average over WINDOW_LEN time steps  =  sum >>> LOG_WINDOW
Head: y[j] = ( sum_i  gap[i] * w[j*8+i] ) >>> FRAC_BITS + b[j]   (no relu)
"""

import os

HEX_DIR   = "../weights"
TV_DIR    = "../testvectors"
FRAC_BITS = 8
DATA_MIN  = -32768
DATA_MAX  =  32767
WINDOW_LEN = 8          # must be a power of 2
LOG_WINDOW = 3          # log2(WINDOW_LEN)
N_CLASSES  = 3
FEAT_DIM   = 8          # block3 OUT_CH

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


def simulate_block(n, in_ch, out_ch, K, dil, has_res, xs_raw):
    w1 = load_s16(f"{HEX_DIR}/block{n}_conv1_weights.hex")
    b1 = load_s16(f"{HEX_DIR}/block{n}_conv1_bias.hex")
    w2 = load_s16(f"{HEX_DIR}/block{n}_conv2_weights.hex")
    b2 = load_s16(f"{HEX_DIR}/block{n}_conv2_bias.hex")

    conv1 = rtl_causal_conv(xs_raw, w1, b1, in_ch, out_ch, K, dil,
                            frac_bits=FRAC_BITS, apply_relu=True)
    conv2 = rtl_causal_conv(conv1,  w2, b2, out_ch, out_ch, K, dil,
                            frac_bits=FRAC_BITS, apply_relu=True)

    if has_res:
        wr = load_s16(f"{HEX_DIR}/block{n}_res_weights.hex")
        br = load_s16(f"{HEX_DIR}/block{n}_res_bias.hex")
        res = rtl_causal_conv(xs_raw, wr, br, in_ch, out_ch, 1, 1,
                              frac_bits=FRAC_BITS, apply_relu=False)
    else:
        res = [list(x) for x in xs_raw]

    out = []
    for t in range(len(xs_raw)):
        row = []
        for ch in range(out_ch):
            v = conv2[t][ch] + res[t][ch]
            v = max(DATA_MIN, min(DATA_MAX, v))
            v = max(0, v)
            row.append(v)
        out.append(row)
    return out


def rtl_gap(xs, feat_dim, log_window):
    """Average WINDOW_LEN vectors: sum then arithmetic right-shift."""
    acc = [0] * feat_dim
    for x in xs:
        for i in range(feat_dim):
            acc[i] += x[i]
    return [a >> log_window for a in acc]


def rtl_linear_head(gap, head_w, head_b, n_classes, feat_dim, frac_bits):
    """Linear head: y[j] = (sum_i gap[i]*w[j*feat_dim+i]) >> frac_bits + b[j]."""
    out = []
    for j in range(n_classes):
        acc = 0
        for i in range(feat_dim):
            acc += gap[i] * head_w[j * feat_dim + i]
        acc = acc >> frac_bits
        acc += head_b[j]
        acc = max(DATA_MIN, min(DATA_MAX, acc))
        out.append(acc)
    return out


def run_case(name, xs_1ch):
    """Run a single test case through the full chain. Returns (scores, pred)."""
    head_w = load_s16(f"{HEX_DIR}/head_weights.hex")
    head_b = load_s16(f"{HEX_DIR}/head_bias.hex")

    b0 = simulate_block(0, 1, 4, 3, 1, True,  xs_1ch)
    b1 = simulate_block(1, 4, 4, 3, 2, False, b0)
    b2 = simulate_block(2, 4, 8, 3, 4, True,  b1)
    b3 = simulate_block(3, 8, 8, 3, 8, False, b2)
    gap    = rtl_gap(b3, FEAT_DIM, LOG_WINDOW)
    scores = rtl_linear_head(gap, head_w, head_b, N_CLASSES, FEAT_DIM, FRAC_BITS)
    pred   = scores.index(max(scores))
    return scores, pred


# ── Test cases: chosen to cover all 3 predicted classes ────────────────────
TEST_CASES = [
    ("const_0",    [[   0]] * WINDOW_LEN),           # pred class 0
    ("const_256",  [[ 256]] * WINDOW_LEN),           # pred class 1
    ("const_n512", [[-512]] * WINDOW_LEN),           # pred class 2
    ("alt_256",    [[256 if i % 2 == 0 else -256]    # pred class 1 (varied)
                    for i in range(WINDOW_LEN)]),
]


def main():
    print(f"Full chain: WINDOW_LEN={WINDOW_LEN}, Q8.8 (FRAC_BITS={FRAC_BITS})")
    print(f"{'Test case':<14} {'inputs (t=0..7)':<42} {'scores [c0,c1,c2]':<34} pred")
    print("-" * 100)

    for name, xs in TEST_CASES:
        flat_in = [x[0] for x in xs]
        scores, pred = run_case(name, xs)
        print(f"  {name:<12} {str(flat_in):<42} {str(scores):<34} class {pred}")

        write_hex_s16(f"{TV_DIR}/chain_{name}_input.hex",    flat_in)
        write_hex_s16(f"{TV_DIR}/chain_{name}_expected.hex", scores)

    print("\nSV testbench constants (copy into tb_top_ecg_tcn.sv):\n")
    for idx, (name, xs) in enumerate(TEST_CASES):
        flat_in = [x[0] for x in xs]
        scores, pred = run_case(name, xs)
        in_str  = ", ".join(f"16'sd{v}" for v in flat_in)
        exp_str = ", ".join(f"16'sd{s}" for s in scores)
        print(f"  // Test {idx}: {name}  → pred class {pred}")
        print(f"  test_in[{idx}]  = '{{ {in_str} }};")
        print(f"  test_exp[{idx}] = '{{ {exp_str} }};")
        print()


if __name__ == "__main__":
    main()
