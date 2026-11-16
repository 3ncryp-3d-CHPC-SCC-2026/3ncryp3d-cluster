# Competition plan: CHPC SCC 2026 National Round

Source of truth: [chpc-tech-eval/scc-nationals26](https://github.com/chpc-tech-eval/scc-nationals26)
(`main`, last change 2026-11-09 "Remove HPCC") and its
`CHPC_2026_SCC_National_Meeting_Timetable.pdf`. All seven branches were
read on 2026-11-16. The app branches (`wrf`, `ECsim_OPEM`, `ExaHyPe_2`,
`Llama.cpp`, `SPECFEM3D_Cartesian`) are older pieces of `main` with
nothing extra. **Re-check the repo before leaving**: case details,
parameters and weights are "to be released later".

Venue: Stellenbosch University. Inputs arrive and results leave on the
captain's competition USB stick; only the captain goes to the organisers' booth.

## Timetable

| Day | What runs | Deadline |
|---|---|---|
| **Sun 6 Dec** | 10:00 arrival; **19:00 hardware collection and cluster configuration** | none, but everything in `docs/day1-runbook.md` must be done tonight |
| **Mon 7 Dec** | 08:00 official start: **HPL, HPCG, IO500** | **17:50** submission |
| **Tue 8 Dec** | **SPECFEM3D, ECSim (OPEM)** | **17:50** submission |
| **Wed 9 Dec** | **WRF, Llama.cpp, MATLAB** | **17:50** submission |
| **Thu 10 Dec** | **ExaHyPE 2** | **12:00** ExaHyPE + **final submission for all benchmarks**; 14:00 tear-down |
| Fri 11 Dec | departures | |

The PDF still says "HPCC, HPCG and IO500" for Monday, but the README (newer)
removed HPCC and scores **HPL** on its own. **Ask the organisers on Sunday
which one they want.** Our HPCC build is kept as a fallback.

## Rules that change how we work

- **Valid = all deliverables present.** An incomplete submission scores nothing.
- **No starting the next day's set** until the current set is validly submitted *and* approved.
- **Late = minus 10% per day**, and only after that day's set is in.
- **Resubmission** only if that day's set is done *and* the original was valid and on time.
- **Any legally obtained software is allowed**; obscure software gets less support.
- Results must be **reproducible**: the organisers may ask for a rerun (IO500 says so explicitly).
- Rulings are final.

How we work as a result: every run goes in its own folder with its inputs,
exact command, environment and output (`benchmarks/run_bench.sh` already
does this). Submit a valid baseline early each day, then tune.

## Scoring (as published)

| Application | Weight |
|---|---|
| HPL | 7% |
| HPCG | 7% |
| IO500 | 6% |
| SPECFEM3D, ECSim, WRF, Llama.cpp, MATLAB, ExaHyPe | not published yet |

## Per application: what is fixed, what we prepare

| App | Fixed by organisers | Prepare before leaving |
|---|---|---|
| **HPL / HPCG** | none yet | `benchmarks/` (BLIS zen5, sizing, runs). Build Sunday night. |
| **IO500** | **ISC26 v2** (`io500-isc26_v2` -> commit `8863e64`, start from its `config-scc.ini`); persistent storage only (no tmpfs); a client on at least one other node; POSIX shared FS (NFS OK); bandwidth weighted above metadata; document the storage setup | `benchmarks/io500/`: build + config + runbook |
| **SPECFEM3D Cartesian** | **v4.1.1**, no source changes, **HDF5 I/O required (parallel HDF5)**, use their mesh/source/stations unchanged | build with MPI + parallel HDF5; run the default example once to learn run times |
| **ECSim = OPEM** | **OPEM v1.4** (Python), *not* the plasma code ECsim; runs write CSV/HTML/.opem reports (file output counts) | `pip` wheel cached offline; run the repo's test vectors |
| **WRF** | `wrf.exe` only (WPS not needed, inputs provided); version not stated (latest **v4.8.0**) | NetCDF-C/Fortran + MPI; build `dm+sm`; learn namelist patch (`nproc_x/nproc_y`) and tile (`numtiles`) tuning |
| **llama.cpp** | **v0.6.0**, **source may not be modified**; build options and flags are free | CPU build (AVX-512), small GGUF model cached; practise `llama-bench`, `llama-batched-bench`, `llama-perplexity` |
| **MATLAB** | **no README yet** | ask about licence and the task on Sunday; nothing to build in advance |
| **ExaHyPE 2** | **Peano repo on gitlab.lrz.de, exactly that repo**; CPU only; document compiler/version, configure line, flags, ranks/threads, env | the build "takes some patience": do one full build before December |

`tools/fetch_sources.sh` downloads every source and model listed here into
one folder for the USB stick, so the venue's internet isn't on the critical path.

## Hardware fit

- **HPL:** 48 Zen 5 cores, full AVX-512. Rpeak 5.6 TFLOPS at base clock (`benchmarks/README.md`).
- **HPCG, WRF, llama.cpp:** memory-bandwidth bound. Each node has **2 of 12 DDR5 channels** populated (102.4 GB/s per node peak), so this is our weak spot. Expect bandwidth, not cores, to limit these; tune ranks per node down if extra ranks add nothing.
- **IO500:** the shared store is node3's 2x SATA SSD RAID 0 over NFS. Physical ceiling: about 1 GB/s write (two SATA SSDs), and 10G links (~1.1 GB/s each) to each client. IO500 scores are "weighted by the limitations of your system", so the aim is to get close to that ceiling, not to beat NVMe teams. See `benchmarks/io500/README.md`.
- **SPECFEM3D, ExaHyPE 2:** compute + MPI. 48 ranks across the 10G TCP mesh.
- **ECSim/OPEM:** single-node Python; mostly about how fast reports reach disk.

## Notes on the extra topics we were given

- **Storage benchmarking** (fio, sequential vs 4K random, IOPS, queue depth): this is **IO500** (`ior` = bandwidth, `mdtest` = metadata ops). Use `fio` on node3 first to measure what the raw SSD RAID 0 and the HDD arrays can do, so IO500 numbers can be judged against hardware limits (`benchmarks/io500/README.md`, step 1).
- **Weather models** (NWP, grids, time steps, domain decomposition): this is **WRF** on Wednesday. Only the model run (`wrf.exe`) is benchmarked.
- **Quantum benchmarking** (RB, Quantum Volume, XEB, QED-C, SupermarQ): **not in the organisers' repo** as of 2026-11-16. If it shows up (for example as the unannounced MATLAB task or a surprise item), on our hardware it would mean **simulating** circuits on CPUs (e.g. Qiskit Aer state-vector simulation of Quantum Volume circuits): memory doubles with each qubit, so 64 GB per node caps a single-node state vector at about 31-32 qubits (complex double). Nothing to build now; keep watching the repo.

## Open questions for the organisers (Sunday)

1. HPL alone, or HPCC? (README vs timetable)
2. MATLAB: licence provided? What is the task?
3. WRF version (latest is v4.8.0)?
4. Exact deliverables per benchmark (files, logs, configs) so every submission is "valid".
5. Internet at the venue, and is downloading during the competition allowed?
