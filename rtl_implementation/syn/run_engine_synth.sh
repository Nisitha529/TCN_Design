#!/bin/bash
# Synthesise qos_tcn_engine (through syn_engine_wrap) for both target families:
#   Vivado 2020.2, Artix-7 200T (xc7a200tfbg484-2)  -- synthesis; Fmax estimated
#                                                      from post-synthesis slack
#   Quartus Lite,  Cyclone IV EP4CE115 (DE2-115)    -- synthesis, fit, timing:
#                                                      Fmax from the timing analyser
#
#   bash syn/run_engine_synth.sh [OUTDIR] [WEIGHTS]     (from rtl_implementation/)
#     OUTDIR   default: /tmp/qos_engine_synth
#     WEIGHTS  default: weights/qos_N8  (must hold engine_params.txt)
#
# Both tools run in parallel; expect 10-30 minutes. Reports land in OUTDIR.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/qos_engine_synth}"
WD="$(cd "$R/${2:-weights/qos_N8}" && pwd)"
VIV="${VIVADO_BIN:-/tools/Xilinx/Vivado/2020.2/bin}"
QB="${QUARTUS_BIN:-/data/intelFPGA_lite/25.1std/quartus/bin}"
mkdir -p "$OUT/vivado" "$OUT/quartus"

# engine parameters exactly as the weights were exported
declare -A P
while IFS='=' read -r k v; do P[$k]=$v; done < "$WD/engine_params.txt"
GEN=""; QPAR=""
for k in N C1 C2 C3 D1 D2 D3 P1 P2 P3 NCLS; do
  GEN="$GEN -generic $k=${P[$k]}"
  QPAR="${QPAR}set_parameter -name $k ${P[$k]}"$'\n'
done
SRCS="$R/rtl/window/win_conv.sv $R/rtl/window/win_block.sv $R/rtl/window/win_head.sv \
      $R/rtl/window/qos_input_stage.sv $R/rtl/window/qos_tcn_engine.sv $R/syn/syn_engine_wrap.sv"

# ── Vivado ────────────────────────────────────────────────────────────────────
cat > "$OUT/vivado/run.tcl" <<EOF
foreach f {$SRCS} { read_verilog -sv \$f }
synth_design -top syn_engine_wrap -part xc7a200tfbg484-2 -mode out_of_context $GEN -generic WDIR=\"$WD\"
create_clock -period 4.0 -name clk [get_ports clk]
report_utilization -file $OUT/vivado/util.rpt
report_utilization -hierarchical -file $OUT/vivado/util_hier.rpt
report_timing_summary -file $OUT/vivado/timing.rpt
report_timing -max_paths 5 -file $OUT/vivado/paths.rpt
EOF
( cd "$OUT/vivado" && timeout 3600 "$VIV/vivado" -mode batch -nojournal -nolog -source run.tcl > vivado.log 2>&1 ) &

# ── Quartus ───────────────────────────────────────────────────────────────────
Q="$OUT/quartus"
{
  echo 'set_global_assignment -name FAMILY "Cyclone IV E"'
  echo 'set_global_assignment -name DEVICE EP4CE115F29C7'
  echo 'set_global_assignment -name TOP_LEVEL_ENTITY syn_engine_wrap'
  for f in $SRCS; do echo "set_global_assignment -name SYSTEMVERILOG_FILE $f"; done
  echo 'set_global_assignment -name SDC_FILE engine.sdc'
  echo "set_parameter -name WDIR \"$WD\""
  printf "%s" "$QPAR"
} > "$Q/engine.qsf"
echo 'create_clock -name clk -period 20.0 [get_ports clk]' > "$Q/engine.sdc"
echo 'PROJECT_REVISION = "engine"' > "$Q/engine.qpf"
( cd "$Q" && timeout 3600 "$QB/quartus_map" engine > map.log 2>&1 \
          && timeout 3600 "$QB/quartus_fit" engine > fit.log 2>&1 \
          && timeout 1800 "$QB/quartus_sta" engine > sta.log 2>&1 ) &
wait

# ── summary ───────────────────────────────────────────────────────────────────
echo "== Vivado, Artix-7 200T (post-synthesis)"
grep -E "^\| (Slice LUTs|Slice Registers|Block RAM Tile|DSPs) " "$OUT/vivado/util.rpt" | sed 's/^/  /'
grep -A6 "Design Timing Summary" "$OUT/vivado/timing.rpt" | tail -1 | \
  awk '{printf "  WNS at 250 MHz: %s ns  ->  est. Fmax %.0f MHz\n", $1, 1000/(4-$1)}'
grep -iE "^ERROR|readmem" "$OUT/vivado/vivado.log" | head -3 | sed 's/^/  /'
echo "== Quartus, Cyclone IV EP4CE115 (fitted)"
grep -E "Total logic elements|Total registers|Total memory bits|Embedded Multiplier 9-bit" \
  "$Q/output_files/engine.fit.summary" 2>/dev/null | sed 's/^/  /'
grep -A3 "Fmax" "$Q/output_files/engine.sta.rpt" 2>/dev/null | grep -E "MHz" | head -2 | sed 's/^/  Fmax: /'
grep -E "^Error" "$Q/map.log" "$Q/fit.log" 2>/dev/null | head -3 | sed 's/^/  /'
echo "reports: $OUT"
