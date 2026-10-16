#!/bin/bash
# Run tb_feature_buffer in the configurations that matter:
#   fast reader   TCN clock faster than the p4rtl clock
#   slow reader   TCN clock slower -- the realistic case, and the one that
#                 fills the buffer and back-pressures p4rtl
#   tiny depth    ADDR_WIDTH=2, so the pointers wrap (and the Gray full/empty
#                 compares are exercised) every few records
#
#   bash tb/stream/run_feature_buffer.sh      (from rtl_implementation/)
set -u
D="$(cd "$(dirname "$0")" && pwd)"
RTL="$D/../../rtl/stream"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
rc=0

run() { # $1=label, rest = -P overrides
  local label="$1"; shift
  local p=() res
  for kv in "$@"; do p+=("-Ptb_feature_buffer.$kv"); done
  if ! iverilog -g2012 "${p[@]}" -o "$W/fb.vvp" \
        "$RTL/feature_buffer.sv" "$D/tb_feature_buffer.sv" 2> "$W/build.log"; then
    echo "FAIL $label: build error"; head -5 "$W/build.log"; rc=1; return
  fi
  timeout 300 vvp -n "$W/fb.vvp" > "$W/run.log" 2>&1
  res=$(grep -oE "Results: [0-9]+ passed, [0-9]+ failed" "$W/run.log" | tail -1)
  if echo "$res" | grep -q ", 0 failed" ; then
    echo "ok   $label: $res"
  else
    echo "FAIL $label: ${res:-no result}"
    grep -E "\[FAIL\]|TIMEOUT" "$W/run.log" | head -8 | sed 's/^/     /'; rc=1
  fi
}

run "fast reader (s 4.0ns, m 3.1ns, depth 16)"  S_PERIOD=4.0 M_PERIOD=3.1 ADDR_WIDTH=4
run "slow reader (s 4.0ns, m 7.3ns, depth 16)"  S_PERIOD=4.0 M_PERIOD=7.3 ADDR_WIDTH=4
run "tiny depth  (s 4.0ns, m 5.0ns, depth 4)"   S_PERIOD=4.0 M_PERIOD=5.0 ADDR_WIDTH=2
run "deep        (s 4.0ns, m 6.1ns, depth 1024)" S_PERIOD=4.0 M_PERIOD=6.1 ADDR_WIDTH=10

# ── Integration: the real p4rtl pipeline (feprobe) feeding the buffer ────────
# Needs the generated feprobe from the compiler repo; set P4RTL_FEPROBE if it
# is not the sibling checkout.
FE="${P4RTL_FEPROBE:-$D/../../../../Compiler_design/p4_to_rtl/generated/feprobe}"
run_int() { # $1=label, rest = -P overrides
  local label="$1"; shift
  local p=() res
  for kv in "$@"; do p+=("-Ptb_p4rtl_to_buffer.$kv"); done
  if ! iverilog -g2012 "${p[@]}" -o "$W/int.vvp" "$FE"/feprobe_pkg.sv \
        $(ls "$FE"/*.sv | grep -v _pkg) "$RTL/feature_buffer.sv" \
        "$D/tb_p4rtl_to_buffer.sv" 2> "$W/ibuild.log"; then
    echo "FAIL $label: build error"; grep -vE "sorry|warning" "$W/ibuild.log" | head -5; rc=1; return
  fi
  timeout 300 vvp -n "$W/int.vvp" > "$W/irun.log" 2>&1
  res=$(grep -oE "Results: [0-9]+ passed, [0-9]+ failed" "$W/irun.log" | tail -1)
  if echo "$res" | grep -q ", 0 failed" ; then
    echo "ok   $label: $res"
    grep -E "^ +(packets sent|p4rtl pushed|buffer high)" "$W/irun.log" | sed "s/^ */       /"
  else
    echo "FAIL $label: ${res:-no result}"
    grep -E "\[FAIL\]|TIMEOUT|packets sent|p4rtl pushed|high watermark" "$W/irun.log" | head -10 | sed 's/^/     /'; rc=1
  fi
}
# ── flow_window: per-flow windows of N records ───────────────────────────────
for n in 4 8 16; do
  if ! iverilog -g2012 -Ptb_flow_window.N=$n -o "$W/fw.vvp" "$RTL/qos_record_pkg.sv" \
        "$RTL/flow_window.sv" "$D/tb_flow_window.sv" 2> "$W/fwb.log"; then
    echo "FAIL flow_window N=$n: build error"; grep -vE "sorry|warning" "$W/fwb.log" | head -5; rc=1; continue
  fi
  timeout 300 vvp -n "$W/fw.vvp" > "$W/fw.log" 2>&1
  res=$(grep -oE "Results: [0-9]+ passed, [0-9]+ failed" "$W/fw.log" | tail -1)
  if echo "$res" | grep -q ", 0 failed"; then
    echo "ok   flow_window N=$n: $res  ($(grep -oE '[0-9]+ windows \([^)]*\)' "$W/fw.log"))"
  else
    echo "FAIL flow_window N=$n: ${res:-no result}"; grep -E "\[FAIL\]|TIMEOUT" "$W/fw.log" | sed 's/^/     /'; rc=1
  fi
done

if [ -f "$FE/feprobe_top.sv" ]; then
  run_int "p4rtl -> buffer, deep, slow consumer"   ADDR_WIDTH=8 TREADY_PCT=50 EXPECT_DROPS=0
  run_int "p4rtl -> buffer, tiny, stalled consumer" ADDR_WIDTH=2 TREADY_PCT=3  EXPECT_DROPS=1
else
  echo "skip p4rtl integration: no feprobe at $FE (set P4RTL_FEPROBE)"
fi
exit $rc
