#!/bin/bash
# run_wrf.sh - run an unpacked WRF case and report mean seconds per time step.
# Usage: cases/wrf/run_wrf.sh <case> <mpi-ranks> <omp-threads>
# Env:   WRF_DIR  WRF build with main/wrf.exe and run/ (default /mnt/shared/opt/apps/WRF)
#        CASES    (default /mnt/shared/cases/wrf)
#        HOSTFILE (default /mnt/shared/hostfile)   RUNS (default /mnt/shared/runs)
set -euo pipefail

name="${1:?usage: run_wrf.sh <case> <ranks> <threads>}"
NP="${2:?ranks}"; NT="${3:?threads}"
WRF_DIR="${WRF_DIR:-/mnt/shared/opt/apps/WRF}"
CASES="${CASES:-/mnt/shared/cases/wrf}"
HOSTFILE="${HOSTFILE:-/mnt/shared/hostfile}"
RUNS="${RUNS:-/mnt/shared/runs}"

[[ -x "$WRF_DIR/main/wrf.exe" ]] || { echo "no wrf.exe in $WRF_DIR/main" >&2; exit 1; }
[[ -f "$CASES/$name/namelist.input" ]] || { echo "no case at $CASES/$name (run get_case.sh)" >&2; exit 1; }

RUN="$RUNS/wrf-$name-$(date +%Y%m%d-%H%M%S)-${NP}x${NT}"
mkdir -p "$RUN"
# WRF's run/ directory holds the physics lookup tables wrf.exe needs
for f in "$WRF_DIR"/run/*; do ln -sf "$f" "$RUN/"; done
for f in "$CASES/$name"/*; do ln -sf "$f" "$RUN/"; done
rm -f "$RUN/namelist.input"; cp "$CASES/$name/namelist.input" "$RUN/"   # a real copy, so it can be edited per run

{
  echo "date: $(date -Is)"; echo "case: $name"; echo "ranks x threads: $NP x $NT"
  echo "wrf: $(git -C "$WRF_DIR" describe --tags 2>/dev/null || echo unknown)"
  mpirun --version | head -1
} > "$RUN/env.txt"

cd "$RUN"
PPN=$(( (NP + 2) / 3 ))
export OMP_NUM_THREADS="$NT" OMP_PLACES=cores OMP_PROC_BIND=close
/usr/bin/time -v mpirun -np "$NP" --hostfile "$HOSTFILE" \
  --map-by "ppr:${PPN}:node:PE=${NT}" --bind-to core \
  -x OMP_NUM_THREADS -x OMP_PLACES -x OMP_PROC_BIND ./wrf.exe 2> time.txt || true

tail -3 rsl.error.0000
if grep -q 'SUCCESS COMPLETE WRF' rsl.error.0000; then
  # NCAR method: mean of "Timing for main" lines, skipping the first step
  awk '/Timing for main/ {n++; if (n>1) {s+=$(NF-2); c++}} END {
       if (c) printf "steps timed: %d  mean s/step: %.4f\n", c, s/c}' rsl.error.0000 | tee result.txt
else
  echo "WRF did not finish: see $RUN/rsl.error.*" | tee result.txt
fi
command -v backup-results >/dev/null && backup-results "${RUN#/mnt/shared/}" || true
echo "run saved in $RUN"
