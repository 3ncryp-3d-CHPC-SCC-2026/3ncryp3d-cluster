#!/bin/bash
# run_bench.sh - run HPL, HPCG or HPCC across the cluster, keep the inputs and
# output together, back the run up to local disk, and (if tools/ilo.env
# exists) log power/temperatures alongside it.
#
# Usage: benchmarks/run_bench.sh hpl|hpcg|hpcc [extra gen_inputs.py args]
#   e.g. benchmarks/run_bench.sh hpl --nb 256 384
#        benchmarks/run_bench.sh hpl --nodes 1 --cores 8 --mem-gb 15   (practice)
# Env:   PREFIX   (default /mnt/shared/opt/bench)
#        HOSTFILE (default /mnt/shared/hostfile)
#        RUNS     (default /mnt/shared/runs)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/mnt/shared/opt/bench}"
HOSTFILE="${HOSTFILE:-/mnt/shared/hostfile}"
RUNS="${RUNS:-/mnt/shared/runs}"
BENCH="${1:?usage: run_bench.sh hpl|hpcg|hpcc [gen_inputs args]}"
shift

case "$BENCH" in
  hpl)  BIN="$PREFIX/bin/xhpl" ;;
  hpcg) BIN="$PREFIX/bin/xhpcg" ;;
  hpcc) BIN="$PREFIX/bin/hpcc" ;;
  *) echo "unknown benchmark $BENCH" >&2; exit 2 ;;
esac
[[ -x "$BIN" ]] || { echo "$BIN missing: run benchmarks/build_stack.sh first" >&2; exit 1; }

RUN="$RUNS/$BENCH-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
python3 "$HERE/gen_inputs.py" --out "$RUN" "$@" | tee "$RUN/sizing.txt"
NP="$(awk '/^ranks/ {print $2}' "$RUN/sizing.txt")"
NODES="$(awk '/^ranks/ {gsub(/\(/,"",$3); print $3}' "$RUN/sizing.txt")"

MPI=(mpirun -np "$NP" --map-by core --bind-to core --report-bindings)
if (( NODES > 1 )); then
  [[ -f "$HOSTFILE" ]] || { echo "multi-node run needs $HOSTFILE" >&2; exit 1; }
  MPI+=(--hostfile "$HOSTFILE")
fi
if [[ "$BENCH" == hpcg ]]; then
  # HPCG is memory-bandwidth bound: 1 rank per core, 1 OpenMP thread each
  MPI+=(-x OMP_NUM_THREADS=1)
fi

{
  echo "date:   $(date -Is)"
  echo "host:   $(hostname)"
  echo "binary: $BIN"
  echo "mpi:    $(mpirun --version | head -1)"
  echo "cmd:    ${MPI[*]} $BIN"
  lscpu | grep -E 'Model name|^CPU\(s\)|MHz' || true
} > "$RUN/env.txt"

cd "$RUN"
if [[ -f "$HERE/../tools/ilo.env" ]]; then
  "$HERE/../tools/power-monitor.sh" -i 5 -o "$RUN/power.csv" -- "${MPI[@]}" "$BIN" 2>&1 | tee "$RUN/output.txt"
else
  "${MPI[@]}" "$BIN" 2>&1 | tee "$RUN/output.txt"
fi

echo
case "$BENCH" in
  hpl)  grep -E '^W[RC]' "$RUN/output.txt" | awk '{print "N="$2" NB="$3" P="$4" Q="$5" time="$6"s GFLOPS="$7}' || true
        grep -E 'PASSED|FAILED' "$RUN/output.txt" | head -3 || true ;;
  hpcg) grep -h -E 'GFLOP/s rating of' HPCG-Benchmark*.txt 2>/dev/null | tail -2 || true ;;
  hpcc) grep -E '^(HPL_Tflops|StarDGEMM_Gflops|PTRANS_GBs|MPIRandomAccess_GUPs|StarSTREAM_Triad|MPIFFT_Gflops)=' hpccoutf.txt 2>/dev/null || true ;;
esac
if command -v backup-results >/dev/null; then
  backup-results "${RUN#/mnt/shared/}" || echo "WARN: backup to /scratch failed" >&2
fi
echo "run saved in $RUN"
