# TCN_Design

A **temporal convolutional network (TCN) accelerator in RTL** that classifies encrypted network
flows into QoS classes at line rate. It is one part of an FPGA network-processing system for
ISP and enterprise networks:

* a **P4 packet processor**, compiled to RTL by our own P4-to-RTL compiler
  ([P4_Compiler_Design](https://github.com/Nisitha529/P4_Compiler_Design), "p4rtl"),
* this **TCN accelerator**, which reads per-packet features from the P4 pipeline and decides what kind
  of traffic each flow is, from its first few packets,
* an **LLM on a host PC**, connected over PCIe, which turns operator intent and the TCN's results into
  P4 match-action table updates (queue, DSCP and rate policy per traffic class).

Target board: **Xilinx VCU118** (Virtex UltraScale+ VU9P, 100G CMAC, PCIe QDMA).

---

## System overview

```
                     ┌──────────────────────── VCU118 FPGA ────────────────────────────────┐
  100G ─► CMAC ─► P4 pipeline (p4rtl) ──────────────────────────────────────► CMAC ─► 100G
                   │ FeatureExport: one 64-bit record per packet        ▲ class → queue / DSCP / meter
                   ▼                                                     │   (write-back: to build)
                 feature_buffer  (deep FIFO, crosses into the TCN clock) │
                   ▼                                                     │
                 flow_window     (first 8 packets of each flow)          │
                   ▼                                                     │
                 qos_tcn_engine  (lookup tables → 3 TCN blocks → head) ──┘──► {flow, QoS class}
                     └──────────────────────────────────┬─────────────────────────────────┘
                                                        │ PCIe (QDMA): statistics, tables, new weights
                                     HOST PC:  collector → LLM → validator → P4 table writes
```

The TCN sees only what the P4 pipeline can compute per packet: **payload size, direction, time since
the previous packet, and the TCP PSH flag**. It never inspects payload, so it keeps working on
encrypted traffic (TLS 1.3, QUIC, Encrypted Client Hello).

---

## How the project got here

### 1. Learning the TCN (done)
`init_tcn_designs/`: the TCN papers' reference tasks (adding problem, pixel MNIST), plus ECG and
HAR classification notebooks, to understand causal dilated convolutions and residual blocks.

### 2. First TCN in RTL (done)
`rtl_implementation/rtl/{primitives,blocks}` and `top_ecg_tcn.v`: an ECG TCN in Q8.8 fixed point
(MAC unit, saturating adder, shift registers, causal conv, TCN block), verified bit-exact against the
PyTorch model. It processes one sample stream with one multiplier per convolution. It showed how
the arithmetic works, and that this streaming style is too slow for network flow rates.

### 3. Connecting P4 to the TCN (done, in the compiler repo)
The p4rtl compiler gained what the TCN needs:
* **`FeatureExport<T>`**, a new P4 extern: each `push()` sends one record out of an AXI4-Stream port,
  never stalls the packet path, and counts every record it has to drop;
* `++` bit concatenation, a VCU118 board target, a machine-readable control-plane map
  (`<app>_cp_map.json`) for the host software, and measured read-after-write distances for
  `Register`s.

### 4. Choosing the application and the data (done)
* **Application:** QoS through **encrypted-traffic classification**. It fits an ISP/enterprise product, and
  its actions (queues, meters, DSCP) already exist in p4rtl. Intrusion detection is kept as a possible
  second task on the same hardware. QoE was set aside: labelled ground truth is scarce, and it is judged
  per session over seconds, not per flow.
* **Dataset:** **CESNET-TLS-Year22**: a full year of real traffic from an ISP backbone (100 Gbps links,
  ~0.5M users), 180 services, with each flow's first 30 packets recorded. CESNET-QUIC22 is the second
  dataset. Fetched day by day from Zenodo over a slow link (see `../datasets/cesnet/README.md`).
* **Labels:** 23 service categories mapped to 5 QoS classes: realtime, streaming, interactive, bulk,
  background (`qos_tcn/qos_map.py`, still a draft for review).
* **Splits by time:** train on 1–21 Sep 2022, test on 10–16 Oct 2022, and test drift on one day per month.

### 5. The model (done; `qos_tcn/`)
* Inputs encoded **bit-exactly as the hardware will compute them** (`hw_encoding.py`). Server name,
  IP addresses and ports are excluded, since they name the service outright.
* Same TCN as the ECG work (3 blocks, kernel 3, dilations 1/2/4, 32/32/64 channels), with two changes:
  **lookup-table inputs** (each field picks a learned vector; in hardware a ROM read) and a
  **flatten output layer** that keeps packet position.
* **Classify on the first N = 8 payload packets.** That decides for 79% of flows on their 8th packet;
  shorter flows are classified when they end (FIN).
* Plain **Q8.8 quantisation** after training matches the float model (same class for 99.2% of flows),
  and `quant.py` is the integer golden model the RTL must reproduce exactly.

### 6. TCN v2 hardware (core done; `rtl_implementation/rtl/{stream,window}`)
| Module | Job |
|---|---|
| `stream/feature_buffer.sv` | deep dual-clock FIFO between the P4 and TCN clocks; back-pressures rather than drops, so loss is counted once |
| `stream/flow_window.sv` | stores each flow's first N packet records and outputs the window on packet N, or early on FIN (`last` bit) |
| `stream/qos_record_pkg.sv` | the 64-bit record format, shared with `qos_tcn/hw_encoding.py` |
| `window/qos_input_stage.sv` | packet fields → buckets → lookup-table ROMs |
| `window/win_conv.sv` | parameterised causal dilated convolution over a whole window, P parallel multiply-add lanes |
| `window/win_block.sv` | one TCN block: conv 1 ∥ residual, then conv 2, saturating add, ReLU |
| `window/win_head.sv` | flatten linear layer + argmax |
| `window/qos_tcn_engine.sv` | the full classifier: input stage → 3 blocks → head |

Why a new compute core instead of the ECG blocks: the window engine sees all 8 packets at once, so
causal padding is a single comparison, no state has to be cleared between flows, and speed scales with
the number of lanes P. It keeps the same arithmetic, saturating instead of wrapping on overflow.

---

## Results so far

**Accuracy** (macro-F1, test week two weeks after training; 2.1M training flows):

| Packets seen (N) | TCN | Gradient-boosted trees | Flows reaching N |
|---:|---:|---:|---:|
| 4 | 0.794 | 0.795 | 97.7% |
| **8** | **0.891** | 0.879 | 79.4% |
| 16 | 0.911 | 0.889 | 30.7% |
| 30 | 0.914 | 0.890 | 20.1% |

**Drift**: the September-trained N = 8 model scores 0.92 in September, 0.80 by December and 0.55 in
January. Accuracy decays with distance in time, which is the case for runtime weight reload and
periodic retraining.

**Hardware** (simulation, iverilog + Vivado xsim):
* `qos_tcn_engine` reproduces the trained N = 4 and N = 8 models **bit for bit** (class and all logits)
  on 200 real CESNET flows each.
* N = 8: **10,481 cycles per flow**, i.e. 42 µs at 250 MHz, ~24k flows/s with one flow in flight.
* `feature_buffer`, behind the real p4rtl-generated pipeline: no packet is ever stalled, and
  records received + records dropped = packets sent.
* Every testbench is checked against deliberately broken versions of its module, to make sure it can fail.

---

## Repository layout

```
init_tcn_designs/         learning notebooks (adding problem, pixel MNIST, ECG, HAR)
qos_tcn/                  QoS model: encoding contract, data prep, training, golden model, RTL export
  results/first-sweep/    trained models (N = 4, 8, 16, 30) and metrics.json
rtl_implementation/
  rtl/primitives, blocks  ECG-era building blocks (Q8.8 MAC, adder, shift register, causal conv, block)
  rtl/stream              feature_buffer, flow_window, record format
  rtl/window              TCN v2 compute engine
  constraints/            clock-crossing constraints for feature_buffer
  weights/qos_N4, qos_N8  exported trained weights + real-flow test vectors
  tb/                     testbenches (stream/, window/, blocks/, primitives/)
resources/                reference papers
```
The CESNET data and caches live outside the repo, in `../datasets/cesnet/`.

## Running it

```bash
# data: per-day caches in hardware units (once; ~1 min per day)
cd qos_tcn && python3 prepare.py

# train and evaluate (N = 4 8 16 30, with tree baseline and drift)
python3 train.py --run first-sweep

# golden model vs float model
python3 quant.py results/first-sweep/model_N8.pt --n 8

# export weights + test vectors for the RTL
python3 export_rtl.py results/first-sweep/model_N8.pt --n 8 --out ../rtl_implementation/weights/qos_N8

# hardware tests (from rtl_implementation/)
bash tb/stream/run_feature_buffer.sh     # buffer, flow_window, p4rtl integration
bash tb/window/run_window_tests.sh       # win_conv shapes + full engine on real flows
```
Needs Python 3 with PyTorch, NumPy, pandas, scikit-learn; Icarus Verilog (`iverilog -g2012`);
optionally Vivado for xsim and synthesis. The p4rtl integration test expects the compiler repo as a
sibling directory (`../Compiler_design`) or `P4RTL_FEPROBE` set.

---

## Roadmap

### Next: the hardware's limits
- [ ] **Synthesis sweep of `win_conv`** (lanes P = 4/16/64, channels 15/32/64) on the licensed Artix-7:
      LUTs, DSPs, block RAM and Fmax, to find where the design breaks before restructuring it.
- [ ] **Throughput**: let flows overlap across the three blocks (block 3 limits it to ~80k flows/s), add
      lanes, or replicate engines. Target ≥ 100k flows/s per engine.
- [ ] **Full-chain test**: real flows as records through `feature_buffer` → `flow_window` → engine,
      against the golden model.

### Closing the data-plane loop
- [ ] **Class write-back**: the TCN's per-flow class into a P4 `Register` (a hardware write port in p4rtl),
      so the pipeline applies queue/DSCP/meter by class within microseconds.
- [ ] **`ids.p4`**: payload length (IPv4 and IPv6), flow direction, coarse inter-packet time,
      per-flow packet index, FIN/RST → `last`.
- [ ] **Flow timeouts** for flows that end without a FIN.
- [ ] **Runtime weight loading** over AXI4-Lite, so a retrained model can be installed without a rebuild.

### On the board and the host
- [ ] VCU118 integration: CMAC (100G) → p4rtl → TCN, QDMA (PCIe) BAR mapped to the control-plane map.
- [ ] Host software: collector for TCN results and counters; LLM agent that writes per-class QoS
      policy, constrained by the compiler-generated schema and checked by a validator.
- [ ] Retraining loop driven by measured drift.

### Evaluation and paper
- [ ] Accuracy vs packets seen, against trees and in-switch baselines (NetBeacon-, BoS-style).
- [ ] Throughput, latency, resources and power on the VCU118 (needs a VU9P synthesis licence).
- [ ] Closed-loop experiments: time to apply a policy, benign traffic affected, LLM proposals rejected.
- [ ] Second dataset (CESNET-QUIC22) and, optionally, a second task (intrusion detection) on the same hardware.

### Open decisions
- The 5-class QoS mapping (`qos_tcn/qos_map.py`).
- Local or hosted LLM.
- A VU9P synthesis licence for real resource and timing numbers.

---

## References
In `resources/`: Bai et al., *An Empirical Evaluation of Generic Convolutional and Recurrent Networks
for Sequence Modeling*; *Optimizing TCN Inference on FPGA-Based Accelerators*; *Real-Time In-Network
Machine Learning on P4 Programmable FPGA SmartNICs*; *Network traffic prediction based on transformer
and temporal convolutional network*.
Dataset: *CESNET-TLS-Year22: A year-spanning TLS network traffic dataset from backbone lines*,
*Scientific Data* (2024), https://doi.org/10.1038/s41597-024-03927-4.
