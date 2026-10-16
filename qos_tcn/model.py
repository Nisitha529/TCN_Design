"""
model.py -- the QoS TCN, shaped so it maps onto the existing RTL blocks.

Per block (same as rtl/blocks/tcn_block.v and python/quantize_exports.py):
    y = relu(bn1(causal_conv1(x)))
    y = relu(bn2(causal_conv2(y)))
    out = relu(y + res(x))          res = 1x1 conv when channels change
BatchNorm is folded into the conv weights for hardware (quantize_exports.py
already does this), so it costs nothing on the FPGA.

Head: global average pooling over the N packet positions, then one linear
layer. In hardware the pooling is a sum and one constant multiply by 1/N.

Input: [batch, 4, N] Q8.8 values / 256 (hw_encoding.encode_inputs), causal
over packets, padded with zeros past the end of short flows.
"""
import torch
import torch.nn as nn


class CausalConv1d(nn.Module):
    def __init__(self, cin, cout, k, d):
        super().__init__()
        self.pad = (k - 1) * d
        self.conv = nn.Conv1d(cin, cout, k, dilation=d)

    def forward(self, x):
        return self.conv(nn.functional.pad(x, (self.pad, 0)))


class TCNBlock(nn.Module):
    def __init__(self, cin, cout, k, d, dropout=0.0):
        super().__init__()
        self.conv1 = CausalConv1d(cin, cout, k, d)
        self.bn1 = nn.BatchNorm1d(cout)
        self.conv2 = CausalConv1d(cout, cout, k, d)
        self.bn2 = nn.BatchNorm1d(cout)
        self.drop = nn.Dropout(dropout)
        self.res = nn.Conv1d(cin, cout, 1) if cin != cout else nn.Identity()

    def forward(self, x):
        y = torch.relu(self.bn1(self.conv1(x)))
        y = self.drop(torch.relu(self.bn2(self.conv2(y))))
        return torch.relu(y + self.res(x))


class EmbedInput(nn.Module):
    """Per-field lookup tables instead of feeding raw numbers to the first conv.

    A convolution sees `size` as one continuous value and needs many units to
    carve out narrow ranges, while the discriminative signal is often an
    exact-ish size (a 517-byte ClientHello, a certificate chain of a given
    length). Trees get that for free; this gives the TCN the same thing.

    In hardware each table is a small ROM indexed by bits the input stage
    already has -- no multiplier:
      size  bin = size >> 3          (Q8.8 size_q >> 1)  0..255   -> e_size
      ipt   bin = log2 quarter step  (Q8.8 ipt_q >> 6)   0..67    -> e_ipt
      dir   0 = padding, 1 = reverse, 2 = forward                 -> e_dir
      push  0 / 1                                                 -> e_push
    Outputs are concatenated into the TCN's input channels.
    """
    def __init__(self, e_size=8, e_ipt=4, e_dir=2, e_push=1):
        super().__init__()
        self.size = nn.Embedding(256, e_size)
        self.ipt = nn.Embedding(68, e_ipt)
        self.dir = nn.Embedding(3, e_dir)
        self.push = nn.Embedding(2, e_push)
        self.out_channels = e_size + e_ipt + e_dir + e_push

    def forward(self, x):
        q = torch.round(x * 256).long()                       # back to Q8.8 ints
        size_b = (q[:, 1] >> 1).clamp(0, 255)
        ipt_b = (q[:, 0] >> 6).clamp(0, 67)
        dir_b = torch.where(q[:, 2] > 0, 2, torch.where(q[:, 2] < 0, 1, 0))
        push_b = (q[:, 3] > 0).long()
        e = torch.cat([self.size(size_b), self.ipt(ipt_b), self.dir(dir_b), self.push(push_b)], dim=2)
        return e.transpose(1, 2)                              # [B, C, n]


class QosTCN(nn.Module):
    """head:
      "gap"      mean over positions, then Linear(C)       -- position-blind
      "last"     the last position's features, Linear(C)   -- relies on the
                 receptive field covering the window
      "flatten"  all positions, Linear(C * n)              -- keeps WHERE each
                 packet sits; costs C * n * classes MACs (1,280 at C=32, n=8)
    Position matters for this task: packet 1 is the TLS ClientHello, the next
    ones carry the server's certificate chain, and their exact sizes are a
    service fingerprint. A position-blind head throws that away.
    """
    def __init__(self, n_in=4, channels=(16, 16, 32), dilations=(1, 2, 4), k=3,
                 n_classes=5, dropout=0.1, head="gap", n=None, embed=False):
        super().__init__()
        self.embed = EmbedInput() if embed else None
        if embed:
            n_in = self.embed.out_channels
        self.n_in = n_in
        blocks, c = [], n_in
        for ch, d in zip(channels, dilations):
            blocks.append(TCNBlock(c, ch, k, d, dropout))
            c = ch
        self.blocks = nn.Sequential(*blocks)
        if head == "flatten" and not n:
            raise ValueError("head='flatten' needs the window length n")
        self.head_mode, self.n = head, n
        self.head = nn.Linear(c * n if head == "flatten" else c, n_classes)
        self.k, self.dilations, self.channels = k, dilations, channels

    def forward(self, x):
        if self.embed is not None:
            x = self.embed(x)
        h = self.blocks(x)
        if self.head_mode == "gap":
            h = h.mean(dim=2)
        elif self.head_mode == "last":
            h = h[:, :, -1]
        else:
            h = h.flatten(1)
        return self.head(h)

    def receptive_field(self):
        return 1 + 2 * (self.k - 1) * sum(self.dilations)

    def macs_per_inference(self, n):
        """Multiply-accumulates for one classification over n positions
        (window-recompute mode: the whole window is run once)."""
        macs, c = 0, self.n_in
        for ch in self.channels:
            per_pos = c * ch * self.k + ch * ch * self.k + (c * ch if c != ch else 0)
            macs += per_pos * n
            c = ch
        return macs + self.head.in_features * self.head.out_features


if __name__ == "__main__":
    m = QosTCN()
    print(m)
    print("params:", sum(p.numel() for p in m.parameters()),
          "| receptive field:", m.receptive_field(), "packets",
          "| MACs/inference at N=8:", m.macs_per_inference(8), "at N=30:", m.macs_per_inference(30))
    print(m(torch.zeros(2, 4, 8)).shape)
