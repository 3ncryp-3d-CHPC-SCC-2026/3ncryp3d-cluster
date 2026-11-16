# Benchmarks: HPL, HPCG (and IO500) on 3x EPYC 9135

Monday 7 Dec, due 17:50. Scoring (scc-nationals26, 2026-11-09): **HPL 7%,
HPCG 7%, IO500 6%**. HPCC was **removed** from scoring on 2026-11-09, but the
PDF timetable still lists it, so confirm with the organisers. HPCC stays here as a
fallback only. IO500 lives in [`io500/`](io500/). Full schedule:
[`docs/competition-plan.md`](../docs/competition-plan.md).

Build once on a compute node, install to the NFS share, run from node3.

```bash
# on node1 (as the cluster user), after the cluster is up:
BLIS_CONFIG=zen5 benchmarks/build_stack.sh            # BLIS, HPL, HPCG, HPCC -> /mnt/shared/opt/bench
benchmarks/run_bench.sh hpl                           # full cluster, sized automatically
benchmarks/run_bench.sh hpl --nb 256 384 --mem-frac 0.85
benchmarks/run_bench.sh hpcg
benchmarks/run_bench.sh hpcc
```

Each run gets its own folder in `/mnt/shared/runs/` with the generated inputs
(`HPL.dat`, `hpccinf.txt`, `hpcg.dat`), `sizing.txt`, `env.txt` (CPU, MPI,
exact command), the full output, and `power.csv` if `tools/ilo.env` exists.
The folder is then copied to `/scratch/backup` (the post-run backup policy).

## Sizing (the bought hardware)

`python3 benchmarks/gen_inputs.py` with no arguments:

| | Value | Why |
|---|---|---|
| Ranks | 48 (3 nodes x 16) | 1 MPI rank per physical core, single-threaded BLIS |
| Grid | P x Q = 6 x 8 | as square as possible, P <= Q |
| HPL N | 138,240 | matrix uses 80% of 192 GB (153 GB), multiple of NB |
| NB | 384 (sweep 224-384) | Zen 4/5 BLIS kernels like large NB; measure |
| Rpeak | 5,606 GFLOPS | 48 x 3.65 GHz x 32 DP FLOP/cycle |
| HPCC N | 97,920 | ~half HPL's footprint: HPCC runs several tests |
| HPCG | 104^3 local grid, 1800 s | 1800 s is the official-length run |

Rpeak is computed at **base** clock. Zen 5 runs full-width AVX-512 (two
512-bit FMA pipes, 32 DP FLOP/cycle). All-core clock under AVX-512 load can
sit anywhere between base and the 4.25 GHz all-core boost depending on
power/thermal limits, so measured efficiency is quoted against base. Record
the real clock during runs (`env.txt`, `turbostat` if installed).

What to expect, as targets to beat rather than promises: well-tuned HPL on
EPYC with a fast interconnect lands around 75-85% of Rpeak per node. Across
our 10G TCP mesh, multi-node HPL efficiency will be lower. Run 1-node and
3-node and report both.

## Tuning order (one change at a time, keep every run folder)

1. **Single node first:** `run_bench.sh hpl --nodes 1`. Sweep NB (224, 256,
   384), then `--mem-frac` 0.80 -> 0.88. Best single-node GFLOPS is the
   ceiling for everything else.
2. **BIOS** (see `docs/day1-runbook.md`): workload profile / determinism,
   SMT on vs off, cTDP 200 vs 240 W if exposed. Re-run the best HPL.dat.
3. **Three nodes:** best NB, then try P x Q = 6x8 vs 4x12 vs 3x16, BCAST
   (1rM vs 2rM), DEPTH 0 vs 1. TCP over 10G punishes communication, so
   larger N (more compute per byte) helps.
4. **HPCG:** memory-bandwidth bound (2 channels per node, 102.4 GB/s
   theoretical). Keep 1 rank per core; try nx = 96/104/112 and check
   the reported GFLOP/s rating. Expect a low single-digit % of Rpeak: that
   is normal for HPCG on any machine.
5. **HPCC:** reuse the best HPL NB and P x Q. Check `StarSTREAM_Triad`
   against the 2-channel bandwidth and `PTRANS`/`MPIRandomAccess` for the
   mesh links.

Watch `tools/power-monitor.sh` output during long runs: anything at or over
75 C is the report's throttling line.

## Versions (pinned, SHA-256 checked by build_stack.sh)

| Package | Version | Notes |
|---|---|---|
| AMD BLIS | 5.3.2 | AMD's fork has `zen5` kernels; upstream BLIS 2.1 stops at zen3 |
| HPL | 2.3 | netlib |
| HPCG | 3.1 | |
| HPCC | 1.5.0 | builds its own HPL copy with the same arch file |
| MPI | system OpenMPI | from Ubuntu 24.04, installed by cluster-bootstrap.sh, mesh-only |
| Compiler | system GCC 13 | `-O3 -march=native`; GCC 13 has no `znver5`, so `native` maps to its znver4 tuning. AOCC can be tried later via `CC`/`CXX`. |

## Tested so far

- `gen_inputs.py`: sizing above, generated HPL.dat (31 lines) and
  hpccinf.txt (36 lines, HPCC format) checked by hand.
- `build_stack.sh blis`: built AMD BLIS 5.3.2 in WSL Ubuntu (`auto` picked
  `zen2` on the test laptop; it picks `zen5` on the EPYC 9135). A CBLAS
  DGEMM check (n=2000) matched a naive reference exactly.
- `build_stack.sh hpl` / `hpcc`: makefiles and include paths resolve; the test
  machine had no MPI, so compilation stopped at `mpi.h` as expected.
- **Not yet run end to end:** full HPL/HPCG/HPCC builds and runs need a
  machine with OpenMPI (the cluster nodes, or the practice cluster).

## Applications (not scripted yet)

The National Round apps are SPECFEM3D Cartesian v4.1.1 and ECSim/OPEM v1.4
(Tue), WRF, llama.cpp v0.6.0 and MATLAB (Wed), and ExaHyPE 2 (Thu). Pinned
versions, rules and prep for each are in
[`docs/competition-plan.md`](../docs/competition-plan.md). Build them into
`/mnt/shared/opt/apps` and run from `/mnt/shared` so all ranks see the inputs.
`tools/fetch_sources.sh` caches every source offline.
