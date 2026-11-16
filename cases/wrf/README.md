# WRF practice cases: NCAR's official v4.4 CONUS benchmarks

These are the cases NCAR itself uses to time WRF (the organisers' README says
their method is "close to" NCAR's). Inputs are ready-made, so no WPS needed,
the same as at the competition.

| Size | Case | Download | Why it hurts us |
|---|---|---|---|
| small | `v4.4_bench_conus12km` | 3.2 GB | should run fine: learn the workflow, decomposition and timing |
| stress | `v4.4_bench_conus2.5km` | 36 GB | a much finer grid (many times more points) and a smaller time step. Memory and halo traffic across the 10G mesh dominate. History output lands on NFS. |
| beyond | 2.5 km with history output every step (`history_interval` set very small) | none | shows the I/O wall: compute stalls while ranks write to node3 |

```bash
cases/wrf/get_case.sh conus12km          # downloads + unpacks to /mnt/shared/cases/wrf
cases/wrf/run_wrf.sh conus12km 48 1      # 48 MPI ranks x 1 OpenMP thread
cases/wrf/run_wrf.sh conus12km 24 2      # dm+sm: 24 ranks x 2 threads
cases/wrf/run_wrf.sh conus2.5km 48 1     # the stress case
```

`run_wrf.sh` links the case into a run folder next to `wrf.exe` and runs it.
It then reports NCAR's metric: the **mean seconds per model time step**
from the `Timing for main` lines in `rsl.error.0000`, skipping the first
step (start-up). Output writes are timed separately by WRF (`Timing for Writing`).

## What to try (one change per run)

1. **Ranks x threads:** 48x1, 24x2, 16x3, 12x4. Bandwidth-bound codes often
   do better with fewer ranks and some threads on our 2-channel nodes.
2. **Patch shape:** set `nproc_x` / `nproc_y` in `&domains` (e.g. 6x8 vs
   8x6 vs 4x12). Squarer patches mean less halo per cell.
3. **Tiles:** `numtiles` in `&domains` with OpenMP (try 2, 4, 8) to keep
   the working set in cache.
4. **I/O:** `io_form_history = 2` (serial NetCDF through rank 0) vs `11`
   (parallel NetCDF, needs a PnetCDF build). Or, for timing only,
   `history_interval` big enough that nothing is written. **Check the
   organisers' rules first**: they may require the output.
5. **Process placement:** `mpirun --map-by core --bind-to core` vs
   `--map-by numa`.

## Checking a run is valid

- `rsl.error.0000` ends with `SUCCESS COMPLETE WRF`.
- No `NaN` and no CFL errors (`grep -i cfl rsl.error.*`). A CFL error means
  the time step is too big for the case. Never change `time_step` to go faster.
- Compare a field from the `wrfout_d01_*` file against the reference output
  if NCAR ships one with the case (`ncdump -v T2`), or against our own
  48x1 run.
