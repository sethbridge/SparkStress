#!/bin/bash
# CPU-only sustained stress + thermal-throttle watcher (DGX Spark / GB10, ARM sm_121).
#
# Triggers when the average CPU frequency drops below CPU_THRESH (per-mille of max)
# for CPU_NEED consecutive 2s samples — i.e. a thermal clock drop under full load.
#
# Config (env):
#   LOGDIR     directory for log/summary/status   (default: /tmp/sparkstress)
#   GUARD      max run seconds before giving up   (default: 3600)
#   CPU_THRESH avg freq ratio, per-mille          (default: 900 = 90%)
#   CPU_NEED   consecutive samples to confirm     (default: 4  => ~8s)
#
# Exit codes: 0 = CPU thermal throttle detected, 1 = stressor died, 2 = guard timeout.
set -u
LOGDIR="${LOGDIR:-/tmp/sparkstress}"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/cpu_stress.log"
SUM="$LOGDIR/cpu_stress_summary.txt"
rm -f "$LOG" "$SUM"

STRESS_PID=""
cleanup() { [ -n "$STRESS_PID" ] && kill "$STRESS_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

stress-ng --cpu "$(nproc)" --cpu-method all >/dev/null 2>&1 &
STRESS_PID=$!
{
  echo "=== cpu stress start $(date) ==="
  echo "stress-ng pid=$STRESS_PID on $(nproc) cores"
} > "$LOG"

GUARD="${GUARD:-3600}"
CPU_THRESH="${CPU_THRESH:-900}"
CPU_NEED="${CPU_NEED:-4}"
START=$(date +%s)
CPU_CON=0

while true; do
  if ! kill -0 "$STRESS_PID" 2>/dev/null; then
    echo "$(date '+%H:%M:%S') stress-ng died" >>"$LOG"
    echo "CPU_STRESSOR_DIED" >"$SUM"
    exit 1
  fi
  NOW=$(date +%s)
  if [ $((NOW - START)) -gt "$GUARD" ]; then
    UNITS="$GUARD s"; [ "$GUARD" -ge 60 ] && UNITS="$((GUARD/60)) min"
    echo "$(date '+%H:%M:%S') no throttle within ${GUARD}s; stopping" >>"$LOG"
    echo "TIMEOUT no cpu thermal throttle within $UNITS" >"$SUM"
    break
  fi

  # average per-core frequency ratio vs scaling_max_freq, in per-mille
  SUMR=0; N=0
  for f in /sys/devices/system/cpu/cpu*/cpufreq; do
    cur=$(cat "$f/scaling_cur_freq" 2>/dev/null); max=$(cat "$f/scaling_max_freq" 2>/dev/null)
    [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ] || continue
    N=$((N+1)); SUMR=$((SUMR + 1000*cur/max))
  done
  RATIO=1000; [ "$N" -ge 15 ] && RATIO=$((SUMR/N))

  # hottest thermal zone
  MAXT=0
  for t in /sys/class/thermal/thermal_zone*/temp; do
    v=$(cat "$t" 2>/dev/null); [ -n "$v" ] && [ "$v" -gt "$MAXT" ] && MAXT=$v
  done

  echo "$(date '+%H:%M:%S') cpu_ratio=${RATIO} max_temp=${MAXT} load=$(cut -d' ' -f1 /proc/loadavg)" >>"$LOG"

  if [ "$RATIO" -lt "$CPU_THRESH" ]; then CPU_CON=$((CPU_CON+1)); else CPU_CON=0; fi
  if [ "$CPU_CON" -ge "$CPU_NEED" ]; then
    echo "$(date '+%H:%M:%S') CPU_THERMAL_TRIP ratio=${RATIO}/1000 for ${CPU_NEED} samples" >>"$LOG"
    echo "CPU thermal throttle: avg freq ${RATIO}/1000 sustained for ${CPU_NEED} samples" >"$SUM"
    exit 0
  fi
  sleep 2
done
cleanup
echo "stopped $(date)" >>"$LOG"
exit 2
