#!/bin/bash
# run_io500.sh - run IO500 ISC26 v2 against the NFS share from all nodes.
#
# Usage: benchmarks/io500/run_io500.sh [ranks-per-node]   (default 8)
# Env:   PREFIX   io500 build (default /mnt/shared/opt/io500)
#        DATADIR  test files  (default /mnt/shared/io500-data, NFS on node3's SSD RAID 0)
#        HOSTFILE (default /mnt/shared/hostfile)
#        RUNS     (default /mnt/shared/runs)
set -euo pipefail

PREFIX="${PREFIX:-/mnt/shared/opt/io500}"
DATADIR="${DATADIR:-/mnt/shared/io500-data}"
HOSTFILE="${HOSTFILE:-/mnt/shared/hostfile}"
RUNS="${RUNS:-/mnt/shared/runs}"
PPN="${1:-8}"

[[ -x "$PREFIX/io500" ]] || { echo "build first: benchmarks/io500/build_io500.sh" >&2; exit 1; }
[[ -f "$HOSTFILE" ]] || { echo "missing $HOSTFILE" >&2; exit 1; }
case "$DATADIR" in /dev/shm*|/tmp*|/run*) echo "DATADIR must be on persistent storage" >&2; exit 1 ;; esac
fstype="$(findmnt -no FSTYPE --target "$(dirname "$DATADIR")" | head -1)"
[[ "$fstype" != tmpfs ]] || { echo "DATADIR is on tmpfs: not allowed" >&2; exit 1; }

NODES="$(grep -cv '^\s*\(#\|$\)' "$HOSTFILE")"
NP=$(( NODES * PPN ))
RUN="$RUNS/io500-$(date +%Y%m%d-%H%M%S)-${NP}r"
mkdir -p "$RUN" "$DATADIR"

# Start from the official SCC config shipped with this IO500 tag; only point
# its data/result directories at our storage. To tune, pass CONFIG=<file>;
# the config actually used is kept with the results.
CONFIG="${CONFIG:-$PREFIX/config-scc.ini}"
[[ -f "$CONFIG" ]] || { echo "missing $CONFIG" >&2; exit 1; }
sed -e "s|^datadir = .*|datadir = $DATADIR|" -e "s|^resultdir = .*|resultdir = $RUN/results|" \
    "$CONFIG" > "$RUN/config.ini"

{
  echo "date: $(date -Is)"
  echo "ranks: $NP ($NODES nodes x $PPN)"
  echo "datadir: $DATADIR ($fstype)"
  findmnt -no SOURCE,FSTYPE,OPTIONS --target "$DATADIR"
  echo "io500: $(git -C "$PREFIX" describe --tags 2>/dev/null) $(git -C "$PREFIX" rev-parse --short HEAD)"
  mpirun --version | head -1
} > "$RUN/env.txt"

# drop the page cache on every node first, so earlier runs don't inflate reads
awk '!/^[[:space:]]*(#|$)/ {print $1}' "$HOSTFILE" | while read -r h; do
  ssh -n -o BatchMode=yes "$h" 'sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null' \
    || echo "WARN: could not drop caches on $h (needs passwordless sudo for that one command)" >&2
done

cd "$RUN"
mpirun -np "$NP" --hostfile "$HOSTFILE" --map-by node "$PREFIX/io500" "$RUN/config.ini" 2>&1 | tee "$RUN/output.txt"

echo
grep -E '^\[(SCORE|RESULT)' "$RUN/output.txt" | tail -20 || true
command -v backup-results >/dev/null && backup-results "${RUN#/mnt/shared/}" || true
echo "run saved in $RUN"
