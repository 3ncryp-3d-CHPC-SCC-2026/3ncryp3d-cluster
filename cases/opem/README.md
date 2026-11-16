# OPEM practice case: a big fuel-cell design sweep

OPEM v1.4 is light on CPU per run. The organisers note that "each run writes
report files to disk, so file output is part of the workload". A realistic
engineering study sweeps many operating conditions, and that turns into
**thousands of small CSV/HTML/.opem files**, which is exactly where NFS on
one SATA array struggles (metadata, not bandwidth).

`sweep.py` runs the Amphlett static model (the README's own test vector as
the starting point) over a grid of temperature x H2 pressure x O2 pressure x
membrane thickness, one process per core, every run writing its full report.

| Size | Grid | Runs | Report files (3 per run) |
|---|---|---|---|
| small | 3 x 2 x 2 x 2 | 24 | 72 |
| stress | 10 x 5 x 5 x 4 | 1,000 | 3,000 |
| beyond | 20 x 10 x 10 x 5, i-step 0.01 | 10,000 | 30,000 (large files) |

```bash
python3 -m venv ~/opem && ~/opem/bin/pip install opem==1.4   # or from the offline wheel folder
~/opem/bin/python cases/opem/sweep.py --size small
~/opem/bin/python cases/opem/sweep.py --size stress --out /mnt/shared/runs   # on NFS
~/opem/bin/python cases/opem/sweep.py --size stress --out /scratch/opem      # local disk: compare
```

Compare wall time with reports on NFS vs on local `/scratch`, and with
`--workers 4/8/16`. If NFS is far slower, that's the lesson for the real
case: write locally, then copy once.

The first thing to run is the repo's own test vectors (the `test/` folder
in the OPEM source, or `opem` with the README's Amphlett vector). They prove the
install before any timing.
