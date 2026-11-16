#!/bin/bash
# run_cases.sh - llama.cpp practice runs.
# Usage: cases/llamacpp/run_cases.sh bench|threads|batched|ppl|rpc <small|medium|stress|beyond>
# Env:   LLAMA_BIN (default /mnt/shared/opt/apps/llama.cpp/build/bin)
#        MODELS    (default /mnt/shared/cases/llamacpp/models)   RUNS (default /mnt/shared/runs)
#        RPC_PEERS for "rpc": node:mesh-ip pairs whose servers this host uses
#                  (default "node1:10.0.31.1 node2:10.0.23.2", the cables to node3)
set -euo pipefail

what="${1:?usage: run_cases.sh bench|threads|batched|ppl|rpc <size>}"
size="${2:?size}"
BIN="${LLAMA_BIN:-/mnt/shared/opt/apps/llama.cpp/build/bin}"
MODELS="${MODELS:-/mnt/shared/cases/llamacpp/models}"
RUNS="${RUNS:-/mnt/shared/runs}"
PORT=50052

if [[ "$size" == beyond ]]; then
  parts=("$MODELS"/beyond/*-00001-of-*.gguf)
  M="${parts[0]}"
else
  M="$MODELS/$size.gguf"
fi
[[ -n "$M" && -s "$M" ]] || { echo "model for '$size' missing: run get_models.sh $size" >&2; exit 1; }
[[ -x "$BIN/llama-bench" ]] || { echo "no llama.cpp build in $BIN" >&2; exit 1; }

RUN="$RUNS/llama-$what-$size-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN"
{ echo "date: $(date -Is)"; echo "host: $(hostname)"; echo "model: $M"
  echo "llama.cpp: $("$BIN/llama-bench" --version 2>&1 | head -2 | tr '\n' ' ')"
  free -g | head -2; } > "$RUN/env.txt"
cd "$RUN"

case "$what" in
  bench)
    "$BIN/llama-bench" -m "$M" -t 16 -p 512 -n 128 -r 3 -o md | tee result.md ;;
  threads)
    "$BIN/llama-bench" -m "$M" -t 4,8,12,16 -p 512 -n 128 -r 3 -o md | tee result.md ;;
  batched)
    # 8 parallel sequences, prompt 512, generate 128; then up to 32 users
    "$BIN/llama-batched-bench" -m "$M" -t 16 -c 32768 -b 2048 -ub 512 \
      -npp 512 -ntg 128 -npl 1,2,4,8,16,32 | tee result.txt ;;
  ppl)
    "$BIN/llama-perplexity" -m "$M" -t 16 -f "$MODELS/wikitext-2-raw/wiki.test.raw" | tee result.txt
    grep -E 'Final estimate' result.txt || true ;;
  rpc)
    peers="${RPC_PEERS:-node1:10.0.31.1 node2:10.0.23.2}"
    rpc=""
    for p in $peers; do
      h="${p%%:*}"; ip="${p#*:}"
      echo "starting ggml-rpc-server on $h, bound to $ip:$PORT (mesh only)"
      ssh -n -o BatchMode=yes "$h" "nohup $BIN/ggml-rpc-server -H $ip -p $PORT -t 16 -c > /tmp/rpc-server.log 2>&1 &"
      rpc="${rpc:+$rpc,}$ip:$PORT"
    done
    sleep 5
    trap 'for p in $peers; do ssh -n -o BatchMode=yes "${p%%:*}" "pkill -f ggml-rpc-server" || true; done' EXIT
    echo "rpc servers: $rpc" | tee -a env.txt
    "$BIN/llama-bench" -m "$M" -t 16 -p 512 -n 64 -r 2 --rpc "$rpc" -o md | tee result.md ;;
  *) echo "unknown case $what" >&2; exit 1 ;;
esac

command -v backup-results >/dev/null && backup-results "${RUN#/mnt/shared/}" || true
echo "run saved in $RUN"
