# SPECFEM3D practice case: the Los Angeles basin model, refined until it hurts

Base: `EXAMPLES/applications/meshfem3D_examples/simple_model` from
SPECFEM3D **v4.1.1**. It's a real region (33.1-34.1 N, 117.9-118.9 W,
30 km deep, 4 materials including a soft basin) with an earthquake source
and three stations. The reference run is tiny: 33,792 elements, 4 ranks,
1 s.

`make_case.py` makes a refined copy with factor **k**. It multiplies
`NEX_XI/NEX_ETA`, the vertical element counts, the doubling layer and every
region boundary by k. It divides `DT` by k and multiplies `NSTEP` by k
(same simulated time, still stable), splits the mesh over our 6x8 = 48
ranks, and switches on **HDF5 I/O** (required by the organisers).

| Size | k | Elements (before doubling) | Memory ~k^3, time ~k^4 |
|---|---|---|---|
| small | 3 | ~1.7 M | should fit easily |
| stress | 6 | ~13 M | expect a big share of 192 GB; long run |
| beyond | 9 | ~45 M | expect out-of-memory or hours. Find the edge between 6 and 9. |

(Element counts are 64k x 64k x 15k; the doubling layer reduces the real
number. The mesher prints the true count and the solver prints memory use.
Record both.)

```bash
# SPECFEM3D built with MPI + HDF5 in /mnt/shared/opt/apps/specfem3d
python3 cases/specfem3d/make_case.py --specfem /mnt/shared/opt/apps/specfem3d --k 3
cd /mnt/shared/cases/specfem3d/la-k3 && ./run.sh      # mesher, databases, solver
```

What it teaches:
- where memory runs out (`free -g` on each node during `xgenerate_databases`),
- how time per step changes from 1 node to 3 nodes (halo exchange over 10G),
- how much HDF5 output costs when every rank writes to NFS on node3
  (try `HDF5_IO_NODES = 1` or `2`: dedicated I/O ranks).

Valid run: `OUTPUT_FILES/output_solver.txt` ends with `End of the simulation`,
seismograms exist for all three stations, and for k=1 they match the
`REF_SEIS/` files in the example.
