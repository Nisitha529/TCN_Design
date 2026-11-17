#!/bin/bash
# run_all_synth.sh -- every synthesis run for the TCN hardware, one after another.
#
#   bash syn/run_all_synth.sh OUTDIR [JOB ...]        (from rtl_implementation/)
#
# Jobs (default: all, in this order). Each runs with a hard timeout; a failed or
# timed-out job is recorded and the next one starts. Jobs run SEQUENTIALLY on
# purpose: Vivado and Quartus together on the full engine ran out of memory.
#
#   prim     mac_lane, requant                      Vivado + Quartus
#   stream   feature_buffer (64-bit, 1024 deep), flow_window (N=8; 2^12 rows for
#            the DE2-115, 2^14 for the Artix-7)   Vivado + Quartus
#   engine8v qos_tcn_engine N=8: synthesis AND place & route   Vivado (Artix-7 200T)
#   engine8q qos_tcn_engine N=8: synthesis, fit, timing        Quartus (Cyclone IV E)
#   engine4v qos_tcn_engine N=4: synthesis                     Vivado
#   engine4q qos_tcn_engine N=4: synthesis, fit, timing        Quartus (in case N=8
#            does not fit the DE2-115)
#   ecg      legacy top_ecg_tcn                                Vivado + Quartus
#
# Targets: Vivado 2020.2 xc7a200tfbg484-2 (the largest licensed Xilinx part
# here; the VU9P is not licensed), clock constraint 4 ns (engine: 10 ns). Quartus Lite
# EP4CE115F29C7 (the DE2-115), clock constraint 20 ns (the board's 50 MHz).
# After every job, summarize_synth.py rewrites OUTDIR/SUMMARY.md.
set -u
R="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"; shift
JOBS=("$@"); [ ${#JOBS[@]} -eq 0 ] && JOBS=(prim stream engine8v engine8q engine4v engine4q ecg)
VIV="${VIVADO_BIN:-/tools/Xilinx/Vivado/2020.2/bin}"
QB="${QUARTUS_BIN:-/data/intelFPGA_lite/25.1std/quartus/bin}"
VPART=xc7a200tfbg484-2
QDEV=EP4CE115F29C7
STATUS="$OUT/status.log"
log() { echo "$(date '+%F %T')  $*" | tee -a "$STATUS"; }

WIN="$R/rtl/window/win_conv.sv $R/rtl/window/win_block.sv $R/rtl/window/win_head.sv \
     $R/rtl/window/qos_input_stage.sv $R/rtl/window/qos_tcn_engine.sv $R/syn/syn_engine_wrap.sv"
PKG="$R/rtl/stream/qos_record_pkg.sv"

# ── Vivado: out-of-context synthesis, optional place & route ──────────────────
# viv NAME TOP "FILES" "GENERICS" "CLOCKS" IMPL(0/1) TIMEOUT [PERIOD_NS]
# PERIOD defaults to 4 ns. The engine gets 10 ns: it reaches roughly 70-80 MHz,
# and a constraint 2.5x too tight makes the router spend hours on a path it
# can never close. Fmax = 1000 / (PERIOD - WNS) either way.
viv() {
  local name=$1 top=$2 files=$3 gens=$4 clocks=$5 impl=$6 to=$7 per=${8:-4.0} d="$OUT/$1"
  mkdir -p "$d"; local t="$d/run.tcl"; echo "$per" > "$d/period.txt"
  { for f in $files; do echo "read_verilog -sv $f"; done
    echo "synth_design -top $top -part $VPART -mode out_of_context $gens"
    for c in $clocks; do echo "create_clock -period $per -name $c [get_ports $c]"; done
    [ "$(echo $clocks | wc -w)" -gt 1 ] && echo "set_clock_groups -asynchronous $(for c in $clocks; do printf -- '-group %s ' $c; done)"
    echo "report_utilization -file $d/util.rpt"
    echo "report_utilization -hierarchical -file $d/util_hier.rpt"
    echo "report_timing_summary -file $d/timing.rpt"
    echo "report_timing -max_paths 5 -file $d/paths.rpt"
    if [ "$impl" = 1 ]; then
      echo "opt_design"; echo "place_design"; echo "route_design"
      echo "report_utilization -file $d/impl_util.rpt"
      echo "report_timing_summary -file $d/impl_timing.rpt"
      echo "report_timing -max_paths 5 -file $d/impl_paths.rpt"
    fi
  } > "$t"
  log "START vivado $name"
  ( cd "$d" && timeout "$to" "$VIV/vivado" -mode batch -nojournal -nolog -source run.tcl > vivado.log 2>&1 )
  local rc=$?; log "END   vivado $name rc=$rc"
}

# ── Quartus: synthesis, fit, timing ───────────────────────────────────────────
# qrt NAME TOP "FILES" "PARAMS(k=v ...)" "CLOCKS" TIMEOUT_EACH
qrt() {
  local name=$1 top=$2 files=$3 params=$4 clocks=$5 to=$6 d="$OUT/$1"
  mkdir -p "$d"
  { echo 'set_global_assignment -name FAMILY "Cyclone IV E"'
    echo "set_global_assignment -name DEVICE $QDEV"
    echo "set_global_assignment -name TOP_LEVEL_ENTITY $top"
    echo 'set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL'
    for f in $files; do echo "set_global_assignment -name SYSTEMVERILOG_FILE $f"; done
    echo 'set_global_assignment -name SDC_FILE top.sdc'
    for kv in $params; do echo "set_parameter -name ${kv%%=*} ${kv#*=}"; done
  } > "$d/top.qsf"
  { for c in $clocks; do echo "create_clock -name $c -period 20.0 [get_ports $c]"; done
    [ "$(echo $clocks | wc -w)" -gt 1 ] && echo "set_clock_groups -asynchronous $(for c in $clocks; do printf -- '-group {%s} ' $c; done)"
  } > "$d/top.sdc"
  echo 'PROJECT_REVISION = "top"' > "$d/top.qpf"
  log "START quartus $name"
  ( cd "$d" && timeout "$to" "$QB/quartus_map" top > map.log 2>&1 ) || { log "END   quartus $name FAILED at map rc=$?"; return; }
  ( cd "$d" && timeout "$to" "$QB/quartus_fit" top > fit.log 2>&1 ) || { log "END   quartus $name FAILED at fit rc=$?"; return; }
  ( cd "$d" && timeout "$to" "$QB/quartus_sta" top > sta.log 2>&1 ) || { log "END   quartus $name FAILED at sta rc=$?"; return; }
  log "END   quartus $name ok"
}

# A generated top level that passes string parameters (weight paths) as
# literals, so Vivado and Quartus receive them identically.
engine_top() { # $1=weights dir  $2=out file
  declare -A P
  while IFS='=' read -r k v; do P[$k]=$v; done < "$1/engine_params.txt"
  cat > "$2" <<EOF
module syn_top (input wire clk, input wire rst_n, output wire obs);
  syn_engine_wrap #(.N(${P[N]}), .C1(${P[C1]}), .C2(${P[C2]}), .C3(${P[C3]}),
    .D1(${P[D1]}), .D2(${P[D2]}), .D3(${P[D3]}), .P1(${P[P1]}), .P2(${P[P2]}), .P3(${P[P3]}),
    .NCLS(${P[NCLS]}), .WDIR("$1")) u (.clk(clk), .rst_n(rst_n), .obs(obs));
endmodule
EOF
}

ecg_top() { # $1=out file
  local W="$R/weights" p=""
  for b in 0 1 2 3; do
    p="$p .B${b}_W1(\"$W/block${b}_conv1_weights.hex\"), .B${b}_B1(\"$W/block${b}_conv1_bias.hex\"),"
    p="$p .B${b}_W2(\"$W/block${b}_conv2_weights.hex\"), .B${b}_B2(\"$W/block${b}_conv2_bias.hex\"),"
  done
  for b in 0 2; do
    p="$p .B${b}_RW(\"$W/block${b}_res_weights.hex\"), .B${b}_RB(\"$W/block${b}_res_bias.hex\"),"
  done
  p="$p .HEAD_W(\"$W/head_weights.hex\"), .HEAD_B(\"$W/head_bias.hex\")"
  cat > "$1" <<EOF
module syn_top (input wire clk, input wire rst_n, input wire en, input wire [15:0] data_in,
                output wire [47:0] class_out, output wire valid_out);
  top_ecg_tcn #($p) u (.clk(clk), .rst_n(rst_n), .en(en), .data_in(data_in),
                       .class_out(class_out), .valid_out(valid_out));
endmodule
EOF
}

summ() { python3 "$R/syn/summarize_synth.py" "$OUT" > /dev/null 2>&1 || true; }

log "=== run_all_synth: jobs ${JOBS[*]}  ->  $OUT"
for job in "${JOBS[@]}"; do
  case $job in
    prim)
      viv prim_mac_lane_v mac_lane "$R/rtl/primitives/mac_lane.sv" "" clk 0 1800
      viv prim_requant_v  requant  "$R/rtl/primitives/requant.sv"  "" clk 0 1800
      qrt prim_mac_lane_q mac_lane "$R/rtl/primitives/mac_lane.sv" "" clk 1800
      qrt prim_requant_q  requant  "$R/rtl/primitives/requant.sv"  "" clk 1800 ;;
    stream)
      viv stream_feature_buffer_v feature_buffer "$R/rtl/stream/feature_buffer.sv" \
          "-generic DATA_WIDTH=64 -generic ADDR_WIDTH=10" "s_clk m_clk" 0 1800
      qrt stream_feature_buffer_q feature_buffer "$R/rtl/stream/feature_buffer.sv" \
          "DATA_WIDTH=64 ADDR_WIDTH=10" "s_clk m_clk" 3600
      viv stream_flow_window_f14_v syn_flow_window_wrap "$PKG $R/rtl/stream/flow_window.sv $R/syn/syn_flow_window_wrap.sv" \
          "-generic FLOW_BITS=14 -generic N=8" clk 0 3600
      viv stream_flow_window_f12_v syn_flow_window_wrap "$PKG $R/rtl/stream/flow_window.sv $R/syn/syn_flow_window_wrap.sv" \
          "-generic FLOW_BITS=12 -generic N=8" clk 0 3600
      qrt stream_flow_window_f12_q syn_flow_window_wrap "$PKG $R/rtl/stream/flow_window.sv $R/syn/syn_flow_window_wrap.sv" \
          "FLOW_BITS=12 N=8" clk 3600 ;;
    engine8v)
      mkdir -p "$OUT/engine8_v"; engine_top "$R/weights/qos_N8" "$OUT/engine8_v/syn_top.sv"
      viv engine8_v syn_top "$WIN $OUT/engine8_v/syn_top.sv" "" clk 1 14400 10.0 ;;
    engine8q)
      mkdir -p "$OUT/engine8_q"; engine_top "$R/weights/qos_N8" "$OUT/engine8_q/syn_top.sv"
      qrt engine8_q syn_top "$WIN $OUT/engine8_q/syn_top.sv" "" clk 14400 ;;
    engine4v)
      mkdir -p "$OUT/engine4_v"; engine_top "$R/weights/qos_N4" "$OUT/engine4_v/syn_top.sv"
      viv engine4_v syn_top "$WIN $OUT/engine4_v/syn_top.sv" "" clk 0 7200 10.0 ;;
    engine4q)
      mkdir -p "$OUT/engine4_q"; engine_top "$R/weights/qos_N4" "$OUT/engine4_q/syn_top.sv"
      qrt engine4_q syn_top "$WIN $OUT/engine4_q/syn_top.sv" "" clk 7200 ;;
    ecg)
      local_src="$R/rtl/primitives/mac_unit.v $R/rtl/primitives/adder_sat.v $R/rtl/primitives/relu.v \
                 $R/rtl/primitives/shift_reg.sv $R/rtl/blocks/causal_conv1d.sv $R/rtl/blocks/tcn_block.v \
                 $R/rtl/top_ecg_tcn.v"
      mkdir -p "$OUT/ecg_v" "$OUT/ecg_q"; ecg_top "$OUT/ecg_v/syn_top.sv"; cp "$OUT/ecg_v/syn_top.sv" "$OUT/ecg_q/"
      viv ecg_v syn_top "$local_src $OUT/ecg_v/syn_top.sv" "" clk 0 3600
      qrt ecg_q syn_top "$local_src $OUT/ecg_q/syn_top.sv" "" clk 3600 ;;
    *) log "unknown job $job" ;;
  esac
  summ
done
summ
log "=== ALL DONE"
