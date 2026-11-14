#!/bin/bash
# Combined CPU+GPU sustained stress with thermal-throttle watcher (DGX Spark / GB10).
#
# Loads:
#   CPU: stress-ng, all cores, --cpu-method all
#   GPU: ./gpu_stress (cuBLAS SGEMM 8192^3, ~21 TFLOPS on GB10) — must be built first (make)
#
# Triggers when EITHER:
#   CPU  — avg frequency below CPU_THRESH per-mille of max for CPU_NEED samples (~8s)
#   GPU  — nvidia-smi "HW Thermal Slowdown" or "SW Thermal Slowdown" reason Active
#          for GPU_NEED samples (~6s)
#
# Config (env):
#   LOGDIR     directory for log/summary/status   (default: /tmp/sparkstress)
#   GUARD      max run seconds before giving up   (default: 3600)
#   GHOSTRESS  path to the gpu_stress binary      (default: <script dir>/gpu_stress)
#   CPU_THRESH / CPU_NEED / GPU_NEED              thresholds (defaults 900 / 4 / 3)
#
# Exit codes: 0 = thermal throttle detected (CPU or GPU), 1 = a stressor died, 2 = guard timeout.
set -u
LOGDIR="${LOGDIR:-/tmp/sparkstress}"
mkdir -p "$LOGDIR"
LOG="$LOGDIR/thermal.log"
SUM="$LOGDIR/thermal_summary.txt"
STATUS="$LOGDIR/gpu_status.txt"
rm -f "$LOG" "$SUM" "$STATUS"

GHOSTRESS="${GHOSTRESS:-$(cd "$(dirname "$0")" && pwd)/gpu_stress}"
[ -x "$GHOSTRESS" ] || { echo "error: gpu_stress not found/built at $GHOSTRESS (run: make)" >&2; exit 1; }

STRESS_PID=""; GSPID=""
cleanup() {
  [ -n "$STRESS_PID" ] && kill "$STRESS_PID" 2>/dev/null
  [ -n "$GSPID" ] && kill "$GSPID" 2>/dev/null
}
trap cleanup EXIT INT TERM

stress-ng --cpu "$(nproc)" --cpu-method all >/dev/null 2>&1 &
STRESS_PID=$!
"$GHOSTRESS" "$STATUS" >/dev/null 2>&1 &
GSPID=$!
{
  echo "=== combined stress start $(date) ==="
  echo "cpu stress-ng pid=$STRESS_PID ($(nproc) cores) ; gpu_stress pid=$GSPID"
  echo "baseline gpu: $(nvidia-smi --query-gpu=temperature.gpu,clocks.sm,power.draw --format=csv,noheader,nounits 2>/dev/null)"
} > "$LOG"

GUARD="${GUARD:-3600}"
CPU_THRESH="${CPU_THRESH:-900}"
CPU_NEED="${CPU_NEED:-4}"
GPU_NEED="${GPU_NEED:-3}"
START=$(date +%s)
CPU_CON=0; GPU_CON=0
PEAK_GF=0

# returns 0 if a GPU thermal throttle reason (HW/SW Thermal Slowdown) is currently Active
gpu_throttle() {
  # status is the last field; "Active" alone means throttling, "Not Active" means not
  nvidia-smi -q -d PERFORMANCE 2>/dev/null | awk '
    /(HW Thermal Slowdown|SW Thermal Slowdown)[[:space:]]*:/ {
      if ($NF == "Active" && $(NF-1) != "Not") { print "ACTIVE"; exit }
    }' | grep -q ACTIVE
}

while true; do
  # liveness
  if ! kill -0 "$STRESS_PID" 2>/dev/null; then
    echo "$(date '+%H:%M:%S') cpu stress-ng died" >>"$LOG"; echo "CPU_STRESSOR_DIED" >"$SUM"; exit 1
  fi
  if ! kill -0 "$GSPID" 2>/dev/null; then
    echo "$(date '+%H:%M:%S') gpu_stress died" >>"$LOG"; echo "GPU_STRESSOR_DIED" >"$SUM"; exit 1
  fi

  NOW=$(date +%s)
  if [ $((NOW - START)) -gt "$GUARD" ]; then
    UNITS="$GUARD s"; [ "$GUARD" -ge 60 ] && UNITS="$((GUARD/60)) min"
    echo "$(date '+%H:%M:%S') no throttle within ${GUARD}s; stopping" >>"$LOG"
    echo "TIMEOUT no thermal throttle within $UNITS" >"$SUM"
    break
  fi

  # --- CPU freq ratio ---
  SUMR=0; N=0
  for f in /sys/devices/system/cpu/cpu*/cpufreq; do
    cur=$(cat "$f/scaling_cur_freq" 2>/dev/null); max=$(cat "$f/scaling_max_freq" 2>/dev/null)
    [ -n "$cur" ] && [ -n "$max" ] && [ "$max" -gt 0 ] || continue
    N=$((N+1)); SUMR=$((SUMR + 1000*cur/max))
  done
  RATIO=1000; [ "$N" -ge 15 ] && RATIO=$((SUMR/N))

  # --- GPU ---
  IFS=', ' read -r UTIL TEMP SM PWR BITS < <(nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,clocks.sm,power.draw,clocks_event_reasons.active --format=csv,noheader,nounits 2>/dev/null)
  GF=$(tail -1 "$STATUS" 2>/dev/null | grep -o 'gflops=[0-9.]*' | cut -d= -f2)
  [ -n "$GF" ] && awk -v g="$GF" -v p="$PEAK_GF" 'BEGIN{exit (g>p)?0:1}' && PEAK_GF=$GF

  GPU_T="none"
  gpu_throttle && GPU_T="THERMAL_ACTIVE"

  echo "$(date '+%H:%M:%S') cpu_ratio=${RATIO} gpu_temp=${TEMP:-?} gpu_sm=${SM:-?} gpu_pwr=${PWR:-?}W gpu_util=${UTIL:-?}% gflops=${GF:-?} bits=${BITS:-?} gpu_th=${GPU_T} load=$(cut -d' ' -f1 /proc/loadavg)" >>"$LOG"

  # --- CPU thermal ---
  if [ "$RATIO" -lt "$CPU_THRESH" ]; then CPU_CON=$((CPU_CON+1)); else CPU_CON=0; fi
  if [ "$CPU_CON" -ge "$CPU_NEED" ]; then
    echo "$(date '+%H:%M:%S') CPU_THERMAL_TRIP ratio=${RATIO}/1000 for ${CPU_NEED} samples" >>"$LOG"
    echo "CPU thermal throttle: avg freq ${RATIO}/1000 sustained for ${CPU_NEED} samples" >"$SUM"
    exit 0
  fi

  # --- GPU thermal ---
  if [ "$GPU_T" = "THERMAL_ACTIVE" ]; then
    GPU_CON=$((GPU_CON+1))
    if [ "$GPU_CON" -ge "$GPU_NEED" ]; then
      echo "$(date '+%H:%M:%S') GPU_THERMAL_TRIP ${GPU_NEED} samples, temp=${TEMP} sm=${SM} pwr=${PWR}W gflops=${GF}" >>"$LOG"
      echo "GPU thermal throttle active for ${GPU_NEED} samples: temp=${TEMP}C sm=${SM}MHz pwr=${PWR}W gflops=${GF}" >"$SUM"
      exit 0
    fi
  else
    GPU_CON=0
  fi
  sleep 2
done
cleanup
echo "stopped $(date)" >>"$LOG"
exit 2
