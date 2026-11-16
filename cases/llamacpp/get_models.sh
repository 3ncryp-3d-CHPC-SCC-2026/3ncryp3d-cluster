#!/bin/bash
# get_models.sh - download practice GGUF models + wikitext-2 to the shared disk.
# Usage: cases/llamacpp/get_models.sh small|medium|stress|beyond|all
# Env:   MODELS (default /mnt/shared/cases/llamacpp/models)
set -euo pipefail

MODELS="${MODELS:-/mnt/shared/cases/llamacpp/models}"
HF=https://huggingface.co
mkdir -p "$MODELS"

get() {  # get <url> <file>
  local f="$MODELS/$2"
  [[ -s "$f" ]] && { echo "have $2"; return; }
  mkdir -p "$(dirname "$f")"
  curl -fSL --retry 3 -C - -o "$f.part" "$1" && mv "$f.part" "$f"
}

want="${1:?usage: get_models.sh small|medium|stress|beyond|all}"
free=$(df -BG --output=avail "$MODELS" | tail -1 | tr -dc 0-9)
echo "free in $MODELS: ${free} GB (all models together need ~125 GB)"

get "$HF/datasets/ggml-org/ci/resolve/main/wikitext-2-raw-v1.zip" wikitext-2-raw-v1.zip
[[ -f "$MODELS/wikitext-2-raw/wiki.test.raw" ]] || (cd "$MODELS" && python3 -m zipfile -e wikitext-2-raw-v1.zip .)

case "$want" in small|all)
  get "$HF/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf" small.gguf ;; esac
case "$want" in medium|all)
  get "$HF/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf" medium.gguf ;; esac
case "$want" in stress|all)
  get "$HF/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf" stress.gguf ;; esac
case "$want" in beyond|all)
  # split GGUF: llama.cpp loads part 2 automatically when given part 1
  b="$HF/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-70B-Instruct-Q8_0"
  get "$b/Meta-Llama-3.1-70B-Instruct-Q8_0-00001-of-00002.gguf" beyond/Meta-Llama-3.1-70B-Instruct-Q8_0-00001-of-00002.gguf
  get "$b/Meta-Llama-3.1-70B-Instruct-Q8_0-00002-of-00002.gguf" beyond/Meta-Llama-3.1-70B-Instruct-Q8_0-00002-of-00002.gguf ;; esac
ls -la "$MODELS"
