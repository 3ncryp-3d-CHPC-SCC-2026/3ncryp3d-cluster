# ExaHyPE 2 practice case: Durham's spherical-accretion benchmark

Source: Peano (`https://gitlab.lrz.de/hpcsoftware/Peano`, branch `p4`), the
exact repo the organisers require. CPU only.

Peano ships a real benchmark, used on Durham's Hamilton cluster:
`benchmarks/exahype2/euler/spherical-accretion-upscaling/`. It contains:

- `create-benchmark-executable.py` (and `create-dg-benchmark-executable-with-limiter.py`), which generate and build the solver,
- three numerical schemes: finite volumes (`SelfSimilarInfallFV`), DG (`SelfSimilarInfallDG`) and 4th-order finite differences (`SelfSimilarInfallFD4`),
- Slurm scripts for a **rank-scaling series**: `Hamilton-single-node-mpi-distribution-{1,2,4,8,16,32,64}.sbatch`,
- `example-output/` to compare against.

There's also the plain Euler application at `applications/exahype2/euler/`
(`euler.py`), which is a simpler first build.

## Plan

1. **Build once, early** (the organisers warn it "takes some patience"):
   configure Peano with MPI + OpenMP, then run
   `python3 create-benchmark-executable.py --help` to see the options for
   scheme, mesh size and parallelism. Record the configure line, compiler
   version and flags: they're required deliverables.
2. **Copy the Hamilton series to our cluster:** read each `.sbatch`, take its
   `mpirun`/`srun` line and rank/thread counts, and run the same series on
   1 node (1, 2, 4, 8, 16 ranks) and then 3 nodes (16, 32, 48 ranks).
3. **Where it hurts:** adaptive mesh refinement moves work between ranks as
   the shock moves. Over 10G TCP, the 3-node points show how much load
   balancing and communication cost. Plot time vs ranks; where the curve
   flattens is the answer for the report.
4. **Stress:** raise the mesh resolution (the script's max mesh size /
   depth option) until a single node runs out of memory, then check that the
   same size runs on 3 nodes.

Compare our numbers with `example-output/` only for correctness (same final
time, sensible values), not for speed: Hamilton is a different machine.
