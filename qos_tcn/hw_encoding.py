"""
hw_encoding.py -- the per-packet values exactly as the hardware will compute them.

This file is the contract between three places that must agree bit for bit:
  * ids.p4, which builds the FeatureExport record from each packet,
  * the TCN's input stage (RTL), which turns record fields into Q8.8 inputs,
  * the training pipeline here, which must train on the same values.
Everything below is integer arithmetic so the RTL can mirror it exactly.

Record fields (from ids.p4, see datasets/cesnet/DATA_NOTES.md)
  ipt_u   16 b  inter-packet time in units of 2^18 cycles at 250 MHz
                (= 1.048576 ms), saturating at 65535 (~68.7 s). The first
                packet of a flow has ipt_u = 0.
  size    11 b  transport payload bytes (0..1460 seen; 2047 max)
  dir      1 b  1 = same direction as the flow's first packet, 0 = reverse
  push     1 b  TCP PSH flag

TCN input stage (record -> four Q8.8 channels, value * 256 as int16)
  ch0  ipt   log2(1 + ipt_u) with 2 fractional bits: a leading-one detector
             plus the next two bits. 0 .. 16.75, step 0.25.
  ch1  size  size / 1024  ->  Q8.8 integer = size >> 2.   0 .. ~1.43
  ch2  dir   +1 / -1      ->  +256 / -256
  ch3  push  0 / 1        ->  0 / 256
  A padding position (flow shorter than the window) is all zeros; a real
  packet always has dir = +-1, so the two are distinguishable.
"""
import numpy as np

CLK_HZ = 250_000_000
IPT_SHIFT = 18                          # ipt_u = (cycle delta) >> 18
IPT_UNIT_NS = (1 << IPT_SHIFT) * 1e9 / CLK_HZ   # 1048576 ns = 1.048576 ms
IPT_MAX = (1 << 16) - 1
SIZE_MAX = (1 << 11) - 1
FRAC_BITS = 8                           # Q8.8, as in the existing TCN RTL
N_CH = 4


def ipt_ms_to_units(ipt_ms):
    """Dataset IPT (integer milliseconds) -> the hardware's ipt_u field.

    1 unit = 2^18 / 250e6 s = 1.048576 ms, so units = ms * 10^6 / 2^20,
    truncated (the hardware shifts a cycle difference right, i.e. floors),
    then saturated to 16 bits.
    """
    ipt_ms = np.asarray(ipt_ms, dtype=np.int64)
    return np.minimum((ipt_ms * 1_000_000) >> 20, IPT_MAX).astype(np.uint16)


def log2_q2(v):
    """floor-ish log2 of v >= 1 with 2 fractional bits, as integer quarters.

    Hardware: e = index of the leading one; the fraction is the two bits just
    below it. Returns 4*e + frac (so value = result / 4).
    """
    v = np.asarray(v, dtype=np.int64)
    e = np.zeros_like(v)
    for b in range(1, 18):              # leading-one position, 0..17
        e = np.where(v >= (1 << b), b, e)
    frac = ((v << 2) >> e) & 3          # two bits below the leading one
    return 4 * e + frac


def encode_inputs(ipt_u, size, dirb, push, valid):
    """Record fields [n, W] -> TCN inputs, int16 Q8.8, shape [n, 4, W].

    `valid` marks real packets; padding positions come out as all zeros.
    """
    ipt_q = log2_q2(np.asarray(ipt_u, dtype=np.int64) + 1) << (FRAC_BITS - 2)
    size_q = np.minimum(np.asarray(size, dtype=np.int64), SIZE_MAX) >> 2
    dir_q = np.where(np.asarray(dirb) != 0, 256, -256)
    push_q = np.where(np.asarray(push) != 0, 256, 0)
    x = np.stack([ipt_q, size_q, dir_q, push_q], axis=1)          # [n, 4, W]
    x = np.where(np.asarray(valid, dtype=bool)[:, None, :], x, 0)
    return x.astype(np.int16)


# ── The 64-bit FeatureExport record (ids.p4 -> feature_buffer -> flow_window) ──
# ids.p4 builds it high bits first with ++ and an explicit 9-bit zero pad, so
# p4rtl's tdata is exactly 64 bits (p4rtl itself only pads to a byte multiple):
#   push(flow_id ++ pkt_idx ++ size ++ dir ++ ipt_u ++ push ++ last ++ 9w0)
# `last` marks the flow's end (TCP FIN/RST) so a flow shorter than N is still
# classified; with pkt_idx = 31 the record carries no packet, only that flush.
# Mirrored by rtl/stream/qos_record_pkg.sv -- keep the two in step.
REC_FIELDS = [("flow_id", 20), ("pkt_idx", 5), ("size", 11), ("dir", 1),
              ("ipt_u", 16), ("push", 1), ("last", 1), ("pad", 9)]
REC_W = 64
assert sum(w for _, w in REC_FIELDS) == REC_W

# One stored packet in flow_window (a "slot"): the record minus flow_id,
# pkt_idx and the pad, in 32 bits:  {3'b0, size[10:0], dir, ipt_u[15:0], push}
SLOT_W = 32


def pack_record(**f):
    r, sh = 0, REC_W
    for name, w in REC_FIELDS:
        sh -= w
        v = int(f.get(name, 0))
        assert 0 <= v < (1 << w), f"{name}={v} does not fit {w} bits"
        r |= v << sh
    return r


def unpack_record(r):
    out, sh = {}, REC_W
    for name, w in REC_FIELDS:
        sh -= w
        out[name] = (r >> sh) & ((1 << w) - 1)
    return out


def pack_slot(size, dirb, ipt_u, push):
    return (int(size) << 18) | (int(dirb) << 17) | (int(ipt_u) << 1) | int(push)


def self_test():
    # ipt: 0 ms -> unit 0 -> log2(1) = 0; 1 ms -> 0 units; 2 ms -> 1 unit -> 1.0
    assert ipt_ms_to_units([0, 1, 2, 1049, 10**6]).tolist() == [0, 0, 1, 1000, IPT_MAX]
    assert (log2_q2([1, 2, 3, 4, 5, 6, 7, 8]) / 4).tolist() == \
        [0.0, 1.0, 1.5, 2.0, 2.25, 2.5, 2.75, 3.0]
    x = encode_inputs([[0, 1]], [[517, 0]], [[1, 0]], [[1, 0]], [[1, 0]])
    assert x[0, :, 0].tolist() == [0, 129, 256, 256]    # 517 >> 2 = 129
    assert x[0, :, 1].tolist() == [0, 0, 0, 0]          # padding
    r = pack_record(flow_id=0xABCDE, pkt_idx=7, size=1460, dir=1, ipt_u=0xBEEF, push=1)
    assert unpack_record(r) == dict(flow_id=0xABCDE, pkt_idx=7, size=1460, dir=1,
                                    ipt_u=0xBEEF, push=1, last=0, pad=0)
    assert pack_slot(1460, 1, 0xBEEF, 1) >> 18 == 1460 and pack_slot(0, 0, 1, 0) == 2
    print("hw_encoding self-test OK; 1 ipt unit = %.6f ms" % (IPT_UNIT_NS / 1e6))


if __name__ == "__main__":
    self_test()
