# Practice cases: real workloads that hurt a small cluster

The organisers release the real cases only on the day. These are our own
cases, built from **real published inputs** (NCAR's WRF benchmarks,
SPECFEM3D's Los Angeles model, real LLMs, Durham's ExaHyPE 2 benchmark),
sized so they hit the limits of **our** hardware:

| Our limit | Value | Which cases hit it |
|---|---|---|
| RAM per node | 64 GB (192 GB total) | llama.cpp 70B, SPECFEM3D k=9, WRF 2.5 km |
| Memory bandwidth | 2 of 12 DDR5 channels, 102.4 GB/s per node | WRF, llama.cpp token generation, HPCG |
| Interconnect | 10G TCP, one cable per node pair | SPECFEM3D/WRF halo exchange, llama.cpp RPC, ExaHyPE MPI |
| Shared storage | 2x SATA SSD RAID 0 over NFS on node3 | IO500, WRF history output, OPEM reports, SPECFEM3D HDF5 |
| Power/thermals | 200-240 W CPU, 75 C warning line | long runs: HPL soak, WRF 2.5 km |

Each case has a **small** size (to check it works), a **stress** size
(where we expect trouble) and a **beyond** size (meant to fail or crawl, so
we learn what the failure looks like and what to say in the report).

| Case | App (comp. day) | What goes wrong on a small server |
|---|---|---|
| [`wrf/`](wrf/) | WRF (Wed) | 2.5 km CONUS: 36 GB input, big halo traffic over 10G, history files flood NFS |
| [`specfem3d/`](specfem3d/) | SPECFEM3D (Tue) | mesh refinement k scales memory ~k^3 and run time ~k^4; HDF5 output on NFS |
| [`llamacpp/`](llamacpp/) | llama.cpp (Wed) | 70B Q4 fills one node's RAM; 70B Q8 (75 GB) can't fit one node, needs RPC over 10G |
| [`opem/`](opem/) | ECSim/OPEM (Tue) | parameter sweep writes thousands of report files: metadata on NFS |
| [`exahype2/`](exahype2/) | ExaHyPE 2 (Thu) | long build; the MPI-distribution series shows where 10G stops scaling |
| [`io500-variants.md`](io500-variants.md) | IO500 (Mon) | data bigger than RAM, millions of small files |
| [`drills.md`](drills.md) | all | pull a cable, kill NFS, fill the disk, overheat, mid-run |

Rules for every practice run (same as the competition):

- Keep inputs, exact command, environment and output in its own run folder under `/mnt/shared/runs/`.
- Run `tools/power-monitor.sh -- <command>` around anything longer than 10 minutes.
- Write down what broke and what fixed it in `results/lessons.md`. That file is worth more than the numbers.

**Status:** written from the upstream sources and docs, **not run yet**
(by decision: no testing before we have the hardware or the organisers'
benchmarks). Expect to fix small things on the first run.
