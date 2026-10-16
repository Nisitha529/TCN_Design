#!/bin/bash
# TCN v2 window engine tests (from rtl_implementation/):
#   bash tb/window/run_window_tests.sh            # all
#   bash tb/window/run_window_tests.sh conv       # win_conv only (fast)
#
#  * win_conv against the golden model's convolution, five shapes covering the
#    real model's layers (dilation 4 padding, the 1x1 residual, P = 4..64)
#  * the whole engine on real CESNET flows with trained weights, for every
#    weights/qos_N*/ directory export_rtl.py has written: class and all logits
#    bit for bit against qos_tcn/quant.py
set -u
D="$(cd "$(dirname "$0")" && pwd)"
R="$D/../.."
RTL="$R/rtl/window"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
rc=0
what="${1:-all}"

result() { # $1=label $2=log
  local res; res=$(grep -oE "Results: [0-9]+ passed, [0-9]+ failed" "$2" | tail -1)
  if echo "$res" | grep -q ", 0 failed"; then echo "ok   $1  $(grep -E '^(win_conv|qos_tcn_engine)' "$2" | sed 's/^[^:]*: //')"
  else echo "FAIL $1: ${res:-no result}"; grep -E "mismatch|logit|TIMEOUT" "$2" | head -6 | sed 's/^/     /'; rc=1; fi
}

if [ "$what" = all ] || [ "$what" = conv ]; then
  for cfg in "15 32 3 1 8 8 1" "32 32 3 4 8 16 1" "32 64 1 1 8 64 0" "64 64 3 4 8 32 1" "4 8 3 2 4 4 0"; do
    set -- $cfg
    V="$W/v_$(echo $cfg | tr ' ' _)"
    python3 "$D/gen_conv_vectors.py" "$V" $cfg 40 > /dev/null
    iverilog -g2012 -Ptb_win_conv.CI=$1 -Ptb_win_conv.CO=$2 -Ptb_win_conv.K=$3 -Ptb_win_conv.D=$4 \
      -Ptb_win_conv.N=$5 -Ptb_win_conv.P=$6 -Ptb_win_conv.RELU=$7 -Ptb_win_conv.NV=40 \
      -Ptb_win_conv.VDIR=\"$V\" -o "$W/wc.vvp" "$RTL/win_conv.sv" "$D/tb_win_conv.sv" 2> "$W/b.log" \
      || { echo "FAIL win_conv $cfg: build"; head -3 "$W/b.log"; rc=1; continue; }
    timeout 300 vvp -n "$W/wc.vvp" > "$W/wc.log" 2>&1
    result "win_conv CI=$1 CO=$2 K=$3 D=$4 N=$5 P=$6 RELU=$7" "$W/wc.log"
  done
fi

if [ "$what" = all ] || [ "$what" = engine ]; then
  for WD in "$R"/weights/qos_N*/; do
    [ -f "$WD/engine_params.txt" ] || continue
    P=$(sed 's/^/-Ptb_qos_tcn_engine./' "$WD/engine_params.txt" | tr '\n' ' ')
    NV=$(wc -l < "$WD/tv_class.hex")
    iverilog -g2012 $P -Ptb_qos_tcn_engine.NV=$NV -Ptb_qos_tcn_engine.WDIR=\"${WD%/}\" -o "$W/eng.vvp" \
      "$RTL/win_conv.sv" "$RTL/win_block.sv" "$RTL/win_head.sv" "$RTL/qos_input_stage.sv" \
      "$RTL/qos_tcn_engine.sv" "$D/tb_qos_tcn_engine.sv" 2> "$W/b.log" \
      || { echo "FAIL engine $(basename "$WD"): build"; grep -v sorry "$W/b.log" | head -3; rc=1; continue; }
    timeout 3000 vvp -n "$W/eng.vvp" > "$W/eng.log" 2>&1
    result "engine $(basename "$WD") ($NV real flows)" "$W/eng.log"
  done
fi
exit $rc
