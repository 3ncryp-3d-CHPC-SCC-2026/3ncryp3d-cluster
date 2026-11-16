# llama.cpp practice cases: models too big for one node

llama.cpp **v0.6.0**, CPU only, source unmodified (organisers' rule). Build
with RPC on so one model can be spread over all three nodes:

```bash
cmake -S llama.cpp -B build -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=ON -DGGML_RPC=ON
cmake --build build -j 16
```

| Size | Model (GGUF, bartowski on Hugging Face) | Size on disk | What happens on our nodes |
|---|---|---|---|
| small | Llama-3.2-1B-Instruct Q4_K_M | 0.8 GB | sanity check; fast |
| medium | Meta-Llama-3.1-8B-Instruct Q4_K_M | 4.9 GB | realistic single-node baseline |
| stress | Meta-Llama-3.1-70B-Instruct Q4_K_M | 42.5 GB | fits in one node's 64 GB but leaves little for KV cache and the OS; token generation is limited by 2-channel memory bandwidth |
| beyond | Meta-Llama-3.1-70B-Instruct Q8_0 (2 files) | 75.0 GB | **cannot fit one node.** It must be split over nodes with `ggml-rpc-server`, and every token then crosses the 10G links |

Rough expectation for token generation: each new token reads every weight
once, so tokens/s is at most (memory bandwidth) / (model size). That is
about 102 GB/s / 42.5 GB, or **at most ~2.4 tokens/s** for 70B Q4 on one
node, before any overhead. Prompt processing is compute-bound and scales
with cores. Use this to sanity-check results: a number far above the
ceiling means the benchmark isn't measuring what you think.

```bash
cases/llamacpp/get_models.sh medium            # or small | stress | beyond
cases/llamacpp/run_cases.sh bench medium       # llama-bench: prompt + generation speed
cases/llamacpp/run_cases.sh threads stress     # sweep -t 4..16 (bandwidth saturates early)
cases/llamacpp/run_cases.sh batched medium     # llama-batched-bench: many users at once
cases/llamacpp/run_cases.sh ppl medium         # llama-perplexity on wikitext-2 (quality check)
cases/llamacpp/run_cases.sh rpc beyond         # 70B Q8 over node1 + node2 + node3
```

Things to learn here:
- `--mmap` (default) vs `--no-mmap`, and `--numa distribute`. With a model
  near RAM size, mmap and the page cache decide whether it runs at all.
- Thread count: generation usually peaks below 16 threads on a 2-channel node.
- RPC: start `ggml-rpc-server` **bound to the mesh address only** (never
  0.0.0.0; it has no authentication). Use `-c` so each server caches
  tensors locally and later loads don't resend 75 GB over the network.
- Perplexity is the quality check for quantisation: a lower number is
  better. Compare Q4_K_M vs Q8_0 on the same model.
