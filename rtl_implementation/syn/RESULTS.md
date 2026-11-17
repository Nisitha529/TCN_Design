# Synthesis results (2026-11-17)

Every module of the TCN v2 hardware, synthesized for the two devices we can build for here:

* **Vivado 2020.2, Artix-7 xc7a200tfbg484-2**, the largest licensed Xilinx part (the VCU118's VU9P is
  not licensed). Out-of-context, so the numbers are the module alone.
* **Quartus Lite 25.1, Cyclone IV E EP4CE115F29C7**, the DE2-115. Full fit and timing analysis.

The RTL is the version that passes `tb/window/run_window_tests.sh`: five convolution shapes, and the
whole engine bit-exact on 200 real CESNET flows for both N = 4 and N = 8.

Reproduce: `bash syn/run_all_synth.sh OUTDIR` from `rtl_implementation/` (about 1 h 45 min, mostly
the N = 8 Cyclone IV fit), then `python3 syn/summarize_synth.py OUTDIR`. The raw reports for this
run are in `../../syn_runs/2026-11-17/` (outside the repo).

## The engine (`qos_tcn_engine`, trained QoS model, 5 classes)

| | Artix-7 200T, N = 8 | Artix-7 200T, N = 4 | Cyclone IV (DE2-115), N = 8 | Cyclone IV (DE2-115), N = 4 |
|---|---:|---:|---:|---:|
| Logic | 51,901 LUT (39%) | 30,315 LUT (23%) | 98,954 LE (**86%**) | 58,560 LE (51%) |
| Registers | 62,509 FF (23%) | 31,275 FF (12%) | 66,233 | 36,243 |
| Block RAM | 26.5 tiles (7%) | 27.5 tiles | 584 kbit (15%) | 563 kbit (14%) |
| Multipliers | 186 DSP48 (25%) | 186 DSP48 | 362 × 9-bit = 181 × 18×18 (68%) | same |
| **Fmax** | **66 MHz routed** (79 est. after synthesis) | 79 est. | **45 MHz** (slow 85 °C) | **44 MHz** |
| Cycles per flow | 10,481 | 5,253 | 10,481 | 5,253 |
| Time per flow at Fmax | 159 µs | ~66 µs | 233 µs | 119 µs |
| Flows/s (one flow in flight) | ~6,300 | ~15,000 | ~4,300 | ~8,400 |

Both sizes fit both devices. The N = 8 Cyclone IV fit took 73 minutes at 86% full (N = 4: 4 minutes).

### What limits the clock

1. **The convolution's single-cycle finish.** Routed critical path on the Artix-7 (block 3, conv 2):
   weight block RAM → DSP multiply → 32-bit accumulate → `>>> 8` + bias → saturate → output register.
   15 logic levels (11 carry chains), 15.1 ns. On the Cyclone IV the same path is the worst one into
   the conv blocks (−0.97 ns at 20 ns, ~48 MHz). Splitting it as `mac_lane` + `requant` already do
   (accumulate in one cycle, finish in the next two; 324 and 360 MHz standalone) is the fix.
2. **The head's argmax** (Cyclone IV only, worst path overall, 22.4 ns): it compares each logit with
   `logits[best]`, so each of the 4 comparisons waits for the previous one's mux. It runs once per
   flow; a 2-level compare tree, or spreading it over 2 cycles, removes it.

With both fixed the engine should clear the DE2-115's 50 MHz comfortably. The Artix-7 target after
pipelining is ~200 MHz, the speed of the slowest supporting module.

### Where the area goes (Artix-7, N = 8, per instance)

| Instance | LUT | FF | DSP |
|---|---:|---:|---:|
| block 1: conv1 / conv2 / residual (CI 15 → 32) | 3,249 / 7,333 / 1,048 | ~4,120 each | 16 each |
| block 2: conv1 / conv2 (32 → 32) | 3,203 / 7,338 | ~4,120 each | 16 each |
| block 3: conv1 / conv2 / residual (32 → 64) | 4,375 / **14,586** / 2,295 | ~8,250 each | 32 each |
| residual adders (blocks 1 / 2 / 3) | 768 / 1,803 / 3,591 | 3,845 / 3,845 / 7,685 | 0 |
| head, input stage | 349, 886 | 188, 1,122 | 10, 0 |

* **Registers are the activations.** Each conv's ~4,100 (or ~8,200) FFs are exactly its output
  window, N × CO × 16 bits, held in flip-flops.
* **LUTs are most likely the input select.** Each conv picks one of N × CI input values per cycle
  through a 16-bit multiplexer, and conv LUTs grow with it: block 3's conv2 (8 × 64 = 512 inputs) is
  the largest at 14.6k. (Why each block's conv1 is about half its conv2 is not yet explained.)

Keeping activations in block RAM (a planned step) addresses both: the FFs become RAM bits and the wide
multiplexer becomes a RAM address. On the DE2-115, where N = 8 fills 86% today, that is most of the
room needed for more lanes or a second engine.

### Fixed since the first engine synthesis (2026-11-16)

* **DSPs halved**: 362 → 186 DSP48. Each of the 176 conv lanes is one DSP, as intended
  (block 1: 3 convs × 16, block 2: 2 × 16, its residual being the identity, block 3: 3 × 32). The
  head's 5 lanes take 2 DSPs each (10); not worth chasing.
* **LUTs** 63,348 → 50,870 after synthesis.
* **Quartus out of memory**: writing conv outputs through a variable part-select
  (`y[(t*CO + og*P + p)*DW +: DW] <= ...`) made Quartus use 8.6 GB for a single block-3 conv, and the
  whole engine was killed at 14 GB. Fixed-position output registers with enables: whole engine
  elaborates in 1.0 GB, 25 s.

## Supporting modules

| Module | Artix-7 200T (4 ns constraint) | Cyclone IV |
|---|---|---|
| `mac_lane` (16×16 → 32, 2-stage) | 1 LUT, 3 FF, 1 DSP48 · 324 MHz | 67 LE, 2 × 9-bit mult · 228 MHz |
| `requant` (32 → 16, round, saturate, ReLU) | 53 LUT, 43 FF · 360 MHz | 44 LE · 304 MHz |
| `feature_buffer` (64-bit, 1024 deep, two clocks) | 110 LUT, 152 FF, 2 BRAM · **met 250 MHz** | 159 LE, 64 kbit · 116 / 132 MHz |
| `flow_window` N = 8, 2^14 flows | 207 LUT, 401 FF, 132.5 BRAM · 212 MHz | not run: the 4.2 Mbit of slots exceed the device's 4.0 Mbit |
| `flow_window` N = 8, 2^12 flows | 151 LUT, 311 FF, 33 BRAM · 212 MHz | 1,045 LE, 1.06 Mbit · 104 MHz |

`flow_window` is limited by its valid-bit read-modify-write (block RAM → 3 LUTs → block RAM). It runs
on the engine's clock, so 212 MHz is ample. Its memory scales with flows tracked × N × 32 bits:
2^14 flows is 36% of the Artix-7's block RAM, and 2^12 is the practical size for the DE2-115.

## Legacy ECG TCN (`top_ecg_tcn`, streaming, one multiplier per conv)

| Artix-7 200T | Cyclone IV |
|---|---|
| 6,493 LUT, 7,691 FF, 3.5 BRAM, 33 DSP48 · 59 MHz est. | 7,803 LE, 4,824 registers, 112 kbit, 20 × 9-bit mult · 65 MHz |

## Device capacity

Artix-7 200T: 134,600 LUT, 269,200 FF, 365 BRAM tiles (36 kbit), 740 DSP48.
EP4CE115: 114,480 LE, 3,981,312 memory bits, 532 9-bit multipliers (266 18×18).
