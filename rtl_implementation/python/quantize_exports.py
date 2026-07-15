"""
quantize_export.py
Loads the trained MinECG_TCN, folds BN into conv weights, quantizes
to INT16 (Q8.8 fixed-point), and writes one .hex file per layer.

Fixed-point format: Q8.8
  FRAC_BITS = 8
  scale     = 2^8 = 256
  int_val   = round(float_val * 256), clipped to [-32768, 32767]
  stored as 16-bit two's complement hex, one value per line

Weight BRAM address layout (out_ch major):
  address = out_ch * (in_ch * kernel_size) + in_ch * kernel_size + k
"""

import sys, os
import numpy as np
import torch
import torch.nn as nn

sys.path.insert(0, os.path.dirname(__file__))

# ── reproduce model architecture from notebook ──────────────────────────
class CausalConv1d(nn.Module):
    def __init__(self, in_ch, out_ch, kernel_size, dilation):
        super().__init__()
        self.pad  = (kernel_size - 1) * dilation
        self.conv = nn.Conv1d(in_ch, out_ch, kernel_size,
                              dilation=dilation, padding=self.pad)
    def forward(self, x):
        out = self.conv(x)
        return out[:, :, :-self.pad] if self.pad > 0 else out

class TCNBlock(nn.Module):
    def __init__(self, in_ch, out_ch, kernel_size, dilation):
        super().__init__()
        self.conv1 = CausalConv1d(in_ch,  out_ch, kernel_size, dilation)
        self.conv2 = CausalConv1d(out_ch, out_ch, kernel_size, dilation)
        self.bn1   = nn.BatchNorm1d(out_ch)
        self.bn2   = nn.BatchNorm1d(out_ch)
        self.relu  = nn.ReLU()
        self.res   = nn.Conv1d(in_ch, out_ch, 1) if in_ch != out_ch else nn.Identity()
    def forward(self, x):
        out = self.relu(self.bn1(self.conv1(x)))
        out = self.relu(self.bn2(self.conv2(out)))
        return self.relu(out + self.res(x))

class ECG_TCN(nn.Module):
    def __init__(self, in_ch=1, num_classes=3, channels=None, kernel_size=5):
        super().__init__()
        if channels is None:
            channels = [32, 32, 64, 64]
        blocks = []
        for i, ch in enumerate(channels):
            ic = in_ch if i == 0 else channels[i - 1]
            blocks.append(TCNBlock(ic, ch, kernel_size, dilation=2**i))
        self.network = nn.Sequential(*blocks)
        self.pool    = nn.AdaptiveAvgPool1d(1)
        self.head    = nn.Linear(channels[-1], num_classes)
    def forward(self, x):
        out = self.network(x)
        out = self.pool(out).squeeze(-1)
        return self.head(out)

# ── quantization helpers ─────────────────────────────────────────────────
FRAC_BITS = 8
SCALE     = 2 ** FRAC_BITS   # 256
INT16_MIN = -32768
INT16_MAX =  32767

def quantize(arr):
    """Float ndarray → INT16 ndarray (Q8.8)."""
    return np.clip(np.round(arr * SCALE), INT16_MIN, INT16_MAX).astype(np.int16)

def to_hex_lines(int16_arr):
    """Flat INT16 array → list of 4-char two's complement hex strings."""
    return [f'{int(v) & 0xFFFF:04x}' for v in int16_arr.flatten()]

def write_hex(path, int16_arr):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = to_hex_lines(int16_arr)
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f'  wrote {len(lines):>6} entries → {path}')

# ── BN folding ───────────────────────────────────────────────────────────
def fold_bn(conv_weight, conv_bias, bn):
    """
    Fold BatchNorm1d into Conv1d weights and bias.
    Returns (w_fold, b_fold) as float32 ndarrays.

    Shapes:
      conv_weight : (out_ch, in_ch, kernel_size)
      conv_bias   : (out_ch,)  or None
      bn          : nn.BatchNorm1d

    For each output channel i:
      scale_i  = gamma_i / sqrt(var_i + eps)
      w_fold_i = conv_weight_i * scale_i
      b_fold_i = beta_i - mean_i * scale_i   (+ conv_bias_i * scale_i if present)
    """
    gamma = bn.weight.detach().numpy()          # (out_ch,)
    beta  = bn.bias.detach().numpy()
    mean  = bn.running_mean.detach().numpy()
    var   = bn.running_var.detach().numpy()
    eps   = bn.eps

    scale = gamma / np.sqrt(var + eps)          # (out_ch,)

    W = conv_weight.detach().numpy()            # (out_ch, in_ch, kernel_size)
    # broadcast scale over (in_ch, kernel_size) dims
    w_fold = W * scale[:, np.newaxis, np.newaxis]

    b_conv = conv_bias.detach().numpy() if conv_bias is not None \
             else np.zeros_like(mean)
    b_fold = beta + (b_conv - mean) * scale

    return w_fold.astype(np.float32), b_fold.astype(np.float32)

# ── main export ──────────────────────────────────────────────────────────
def export(model_path, out_dir, channels=[4,4,8,8], kernel_size=3):
    model = ECG_TCN(in_ch=1, num_classes=3,
                    channels=channels, kernel_size=kernel_size)
    model.load_state_dict(torch.load(model_path, map_location='cpu'))
    model.eval()

    print(f'\nExporting: {model_path}')
    print(f'FRAC_BITS={FRAC_BITS}  SCALE={SCALE}  Q8.8\n')

    in_ch_list = [1] + channels[:-1]   # [1, 4, 4, 8]

    for blk_idx, block in enumerate(model.network):
        d        = 2 ** blk_idx
        in_ch    = in_ch_list[blk_idx]
        out_ch   = channels[blk_idx]
        prefix   = f'{out_dir}/block{blk_idx}'

        print(f'Block {blk_idx}  dilation={d}  {in_ch}→{out_ch}')

        # ── conv1 (in_ch → out_ch) ──
        w1, b1 = fold_bn(block.conv1.conv.weight,
                          block.conv1.conv.bias,
                          block.bn1)
        # weight layout: [out_ch][in_ch][k]
        write_hex(f'{prefix}_conv1_weights.hex', quantize(w1))
        write_hex(f'{prefix}_conv1_bias.hex',    quantize(b1))

        # ── conv2 (out_ch → out_ch) ──
        w2, b2 = fold_bn(block.conv2.conv.weight,
                          block.conv2.conv.bias,
                          block.bn2)
        write_hex(f'{prefix}_conv2_weights.hex', quantize(w2))
        write_hex(f'{prefix}_conv2_bias.hex',    quantize(b2))

        # ── residual 1×1 conv (only when in_ch != out_ch) ──
        if in_ch != out_ch:
            res_w = block.res.weight.detach().numpy()   # (out_ch, in_ch, 1)
            res_b = block.res.bias.detach().numpy()
            write_hex(f'{prefix}_res_weights.hex', quantize(res_w))
            write_hex(f'{prefix}_res_bias.hex',    quantize(res_b))

        print()

    # ── final linear head ──
    head_w = model.head.weight.detach().numpy()   # (3, 8)
    head_b = model.head.bias.detach().numpy()     # (3,)
    print('Linear head  8→3')
    write_hex(f'{out_dir}/head_weights.hex', quantize(head_w))
    write_hex(f'{out_dir}/head_bias.hex',    quantize(head_b))

    print('\nExport complete.')
    return model

# ── generate test vectors ────────────────────────────────────────────────
def gen_testvectors(model, out_dir, n=8, seq_len=360, seed=99):
    """
    Run n ECG samples through the float model, also through the
    INT16 input quantized model, and save both to .hex for RTL comparison.
    """
    from ecg_data import build_dataset  # reuse notebook dataset builder
    # or inline a small generator:
    rng = np.random.default_rng(seed)
    X   = rng.uniform(-1, 1, (n, 1, seq_len)).astype(np.float32)

    # quantize inputs to INT16 then back to float (simulate RTL input)
    X_q = (np.clip(np.round(X * SCALE), INT16_MIN, INT16_MAX) / SCALE).astype(np.float32)

    model.eval()
    with torch.no_grad():
        logits = model(torch.tensor(X_q)).numpy()
    preds = np.argmax(logits, axis=1)

    os.makedirs(out_dir, exist_ok=True)

    # save inputs as hex (seq_len × n samples)
    for i in range(n):
        x_int = quantize(X[i, 0])    # (seq_len,)
        write_hex(f'{out_dir}/input_{i:02d}.hex', x_int)

    # save expected class outputs
    with open(f'{out_dir}/expected_classes.txt', 'w') as f:
        for i, p in enumerate(preds):
            f.write(f'sample {i:02d}  class={p}  logits={logits[i]}\n')

    print(f'\nTest vectors written to {out_dir}/')
    print(f'Predictions: {preds}')

if __name__ == '__main__':
    MODEL_PATH = 'ecg_tcn_rtl.pth'
    HEX_DIR    = '../weights'
    TV_DIR     = '../testvectors'

    trained_model = export(MODEL_PATH, HEX_DIR)
    # gen_testvectors(trained_model, TV_DIR)   # uncomment after training