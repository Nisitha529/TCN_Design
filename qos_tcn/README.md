# qos_tcn — QoS traffic-classification TCN (software model)

The reference model for the hardware TCN: it classifies a TLS flow into a QoS class from its first
N payload packets, using only values the P4 data plane can produce. Data: CESNET-TLS-Year22 (real ISP
backbone traffic), stored outside this repo in `../../datasets/cesnet/` (see the README there).

| File | Role |
|---|---|
| `hw_encoding.py` | **The contract with the hardware.** Record field units (ipt in 1.048576 ms steps, payload size, direction, push) and the TCN input-stage conversion to Q8.8, all integer. `python3 hw_encoding.py` self-tests it. |
| `qos_map.py` | 23 service categories → 5 QoS classes (realtime, streaming, interactive, bulk, background). **A draft for review.** |
| `prepare.py` | Day files (`.csv.xz`) → compact caches in hardware units (`../../datasets/cesnet/cache/`). Drops SNI, IPs, ASN and ports: they name the service outright. |
| `model.py` | The TCN, built from the same blocks as `rtl/blocks/tcn_block.v` (causal conv, BN folded, ReLU, residual), plus per-field lookup-table inputs and a choice of output layer. |
| `train.py` | Time-split training and evaluation, sweep over N, a gradient-boosted-trees baseline, and month-by-month drift. |

```bash
python3 prepare.py                   # once; ~1 min per day
python3 train.py --run first-sweep   # N = 4 8 16 30 → results/first-sweep/metrics.json
```

## Splits (by time, never by shuffling flows)

* train 2022-09-01 … 09-21 (100k flows sampled per day)
* validation 09-22 … 09-25
* test 10-10 … 10-16 — two weeks after training ends
* drift: one Wednesday per month, Jan–Dec 2022

## Results: `results/first-sweep` (2.1M training flows, Sep 1–21; test Oct 10–16)

Model: lookup-table inputs, 32/32/64 channels, dilations 1/2/4, flatten head, 8 epochs.

| N | TCN macro-F1 | Trees macro-F1 | TCN acc | Flows reaching N | MACs / flow |
|---:|---:|---:|---:|---:|---:|
| 4 | 0.794 | 0.795 | 0.808 | 97.7 % | 128k |
| **8** | **0.891** | 0.879 | 0.903 | 79.4 % | 255k |
| 16 | 0.911 | 0.889 | 0.922 | 30.7 % | 511k |
| 30 | 0.914 | 0.890 | 0.924 | 20.1 % | 958k |

Drift, macro-F1 of the **September-trained** model on one Wednesday per month (N = 8):

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | **Sep** | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.55 | 0.57 | 0.68 | 0.71 | 0.75 | 0.78 | 0.85 | 0.89 | **0.92** | 0.89 | 0.83 | 0.80 |

Reading it:

* **The TCN matches the trees at N = 4 and beats them from N = 8 on** (+1.2 to +2.4 points).
* **N = 8 is the hardware choice.** N = 16/30 add only 2 points, but just 31 %/20 % of flows reach
  that many packets — the rest would be classified at flow end, late, which defeats early QoS.
  N = 8 decides for 79 % of flows on their 8th payload packet, at half the compute of N = 16.
* **Accuracy decays with time distance from training** (0.92 → 0.80 three months later, 0.55
  eight months earlier). This is the measured case for runtime weight reload and periodic retraining
  in the closed loop.
* Every class has recall ≥ 0.89 at N = 8.

The integer Q8.8 model (`quant.py`) and the RTL engine reproduce the trained N = 4 and N = 8 models
bit for bit on real flows (`rtl_implementation/tb/window/run_window_tests.sh`).

## Early findings (smoke test: train on 2022-01-12, test on 2022-02-16, N = 8, 200k flows)

| Model | Macro-F1 | Params | MACs / classification |
|---|---:|---:|---:|
| Gradient-boosted trees on the same inputs | **0.806** | — | — |
| TCN 16/16/32, raw inputs, average-pool head | 0.624 | 8.3k | 62k |
| same, last-position head | 0.619 | 8.3k | 62k |
| same, flatten head | 0.628 | 9.4k | 63k |
| TCN 32/32/64, raw inputs, flatten head | 0.707 | 33.6k | 244k |
| TCN 16/16/32, **lookup-table inputs**, flatten head | 0.734 | 12.4k | 68k |
| TCN 32/32/64, **lookup-table inputs**, flatten head | 0.774 | 37.4k | 255k |

What this says:

1. **How the inputs enter matters most.** Feeding payload size as one number makes the convolution
   work hard to isolate exact sizes (a 517-byte ClientHello, a certificate chain of a given length),
   which is exactly what trees split on. Per-field **lookup tables** (size bin → 8 values, ipt bin → 4,
   direction → 2, push → 1) close most of the gap. In hardware each table is a small ROM read with no
   multiplier — the size table is 256 × 8 × 16 bit ≈ 32 kbit.
2. The output layer barely matters at this size; flatten is kept because it is cheap (C·N·5 MACs) and
   keeps packet position.
3. Width matters. 32/32/64 is about 255k MACs per classification — ~4k cycles with 64 parallel
   multipliers, i.e. ~16 µs at 250 MHz, ~60k classifications/s per engine. More engines, or a smaller
   model if the sweep allows, close the gap to ISP flow rates.
4. **The trees are a serious baseline.** The paper has to show what the TCN buys over them: accuracy
   at small N, robustness over months (drift), and that one hardware engine serves other tasks by
   reloading weights. If trees stay ahead, a tree-plus-TCN design is a legitimate result too.
