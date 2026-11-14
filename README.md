# SparkStress

CPU + GPU sustained-load thermal stress test for the **NVIDIA DGX Spark** (GB10 SoC:
20-core ARM — 10× Cortex-X925 @ 3.9 GHz + 10× Cortex-A725 @ 2.8 GHz — with an
integrated Blackwell GPU, CUDA `sm_121`).

It runs full CPU and GPU load in parallel and watches for a *thermal* slowdown —
either a CPU frequency drop or a GPU thermal-throttle reason — then stops the load
and reports what tripped. Useful for validating cooling, firmware power-management
behavior, and sustained-load performance on the Spark.

## Files

| File | Purpose |
| --- | --- |
| `gpu_stress.cu` | cuBLAS SGEMM (8192³) GPU stressor, ~21 TFLOPS sustained on GB10. Paces the host with a per-GEMM sync (no enqueue backlog) and writes a heartbeat + throughput to a status file. |
| `cpu_stress.sh` | CPU-only stress (all cores) + thermal watcher. |
| `cpu_gpu_stress.sh` | Combined CPU+GPU stress + thermal watcher. |
| `Makefile` | Builds `gpu_stress` (`NVCC`, `ARCH`, `CFLAGS` overridable). |
| `samples/` | Real excerpts from the first runs on this box, with findings. |

## Requirements

- DGX Spark (or any GB10) with the NVIDIA driver, `nvidia-smi`
- `stress-ng`
- CUDA toolkit with cuBLAS (tested with CUDA 13.0)

## Build

```sh
make            # -> ./gpu_stress
```

## Usage

```sh
./cpu_stress.sh       # CPU only
./cpu_gpu_stress.sh   # CPU + GPU (needs ./gpu_stress)
```

Both scripts run until they trip, a stressor dies, or the guard elapses.
Live progress: `tail -f $LOGDIR/thermal.log` (or `cpu_stress.log`).

Config via environment (defaults in parentheses):

| Var | Meaning | Default |
| --- | --- | --- |
| `LOGDIR` | where log/summary/status files go | `/tmp/sparkstress` |
| `GUARD` | max run seconds before giving up | `3600` |
| `CPU_THRESH` | CPU trip threshold, avg freq per-mille of max | `900` |
| `CPU_NEED` | consecutive 2 s samples required (CPU) | `4` |
| `GPU_NEED` | consecutive 2 s samples required (GPU) | `3` |
| `GHOSTRESS` | path to the `gpu_stress` binary | `<script dir>/gpu_stress` |

Exit codes: `0` thermal throttle detected, `1` a stressor died unexpectedly,
`2` guard timeout (no throttle observed).

## Detection logic

Every 2 s the watcher samples:

- **CPU:** per-core `scaling_cur_freq / scaling_max_freq` across all 20 cpufreq
  policies. The governor is `performance`, so cores sit at max unless hardware
  limits them — a sustained avg ratio below 90% ⇒ thermal clock drop.
- **GPU:** `nvidia-smi -q -d PERFORMANCE` throttle reasons. A trip requires
  `HW Thermal Slowdown` or `SW Thermal Slowdown` reading `Active`
  (the `SW Power Cap` bit is deliberately *not* a trigger — see findings below).
- **Liveness:** both stressors must be alive; the GPU heartbeat
  (`gpu_status.txt`) confirms real GPU work.

**Do not** use raw "SM clock vs `clocks.max.sm`" as a signal: under sustained
load the GB10 settles around 2.4 GHz of the 3.003 GHz max even when healthy,
which would false-positive immediately.

## Findings from the first runs (2026-11-14)

1. **CPU-only:** 20 cores pinned at 100% of max for the entire run; hottest
   thermal zone climbed 71.6 °C → 90.3 °C in ~2 min 40 s without a single clock
   drop (see `samples/cpu_only_excerpt.log`).
2. **GPU-only:** settled at ~74–79 °C, ~93 W, SM ~2411 MHz, ~21 TFLOPS
   SGEMM, throttle bits `0x0` after 60 s — real thermal headroom.
3. **CPU+GPU:** temperatures went *flat* (GPU 64–72 °C) while the GPU was
   power-trimmed: 92 W → ~47 W, SM 2411 → ~2200 MHz, throughput −26%
   (21k → 15.6k GFLOPS) — all with throttle bits `0x0`
   (see `samples/cpu_gpu_excerpt.log`).

**Interpretation:** GB10 is a unified package with one shared power budget.
Under combined load, firmware reallocates power between CPU and GPU *instead of
letting temperatures rise*, so true thermal throttling is preempted by
firmware-level power sharing. That power-based slowdown (−26% GPU compute) is
real, measurable, and reproducible, but it does not surface in
`clocks_event_reasons.active` or the named throttle reasons.

## Caveats

- These tests max out the machine. Anything else running (in particular a vLLM
  model server on the same GPU) will be slow for the duration, and the GPU
  stressor competes directly with it.
- `nvidia-smi -q -d PERFORMANCE` is the source of truth for throttle reasons on
  this driver; the hex `clocks_event_reasons.active` bitmask stayed `0x0`
  even during the power-trimming observed above.
- `gpu_stress` has no idle mode; kill it (SIGTERM/SIGKILL) to stop.
