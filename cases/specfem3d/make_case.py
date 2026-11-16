#!/usr/bin/env python3
"""Make a refined copy of SPECFEM3D v4.1.1's simple_model (Los Angeles) example.

Refinement factor k scales the mesh in all three directions, scales the time
step down by k (so the CFL condition still holds), and keeps the simulated
time the same. The mesh is split over NPROC_XI x NPROC_ETA ranks and HDF5
I/O is turned on.

Usage:
  make_case.py --specfem /mnt/shared/opt/apps/specfem3d --k 3
               [--nproc 6 8] [--out /mnt/shared/cases/specfem3d] [--io-nodes 0]
"""
import argparse
import re
import shutil
import sys
from pathlib import Path

EXAMPLE = "EXAMPLES/applications/meshfem3D_examples/simple_model"


def set_key(text, key, value):
    pat = re.compile(rf"^({re.escape(key)}\s*=\s*)(\S+)(.*)$", re.M)
    if not pat.search(text):
        sys.exit(f"key {key} not found: is this SPECFEM3D v4.1.1?")
    return pat.sub(lambda m: f"{m.group(1)}{value}{m.group(3)}", text, count=1)


def get_key(text, key):
    m = re.search(rf"^{re.escape(key)}\s*=\s*(\S+)", text, re.M)
    if not m:
        sys.exit(f"key {key} not found")
    return m.group(1)


def fortran_float(s):
    return float(s.lower().replace("d", "e"))


def scale_range(b, e, k):
    """element range b..e (1-based, inclusive) -> the same span in a k-times finer mesh"""
    return (b - 1) * k + 1, e * k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--specfem", required=True, type=Path)
    ap.add_argument("--k", required=True, type=int)
    ap.add_argument("--nproc", nargs=2, type=int, default=[6, 8], metavar=("XI", "ETA"))
    ap.add_argument("--out", type=Path, default=Path("/mnt/shared/cases/specfem3d"))
    ap.add_argument("--io-nodes", type=int, default=0, help="HDF5_IO_NODES (dedicated I/O ranks)")
    a = ap.parse_args()
    k, (pxi, peta) = a.k, a.nproc

    src = a.specfem / EXAMPLE
    if not (src / "DATA" / "Par_file").exists():
        sys.exit(f"example not found at {src}")
    dst = a.out / f"la-k{k}"
    if dst.exists():
        sys.exit(f"{dst} exists; remove it first")
    shutil.copytree(src / "DATA", dst / "DATA")

    # --- Mesh_Par_file -----------------------------------------------------
    mp = dst / "DATA" / "meshfem3D_files" / "Mesh_Par_file"
    t = mp.read_text()
    nex = int(get_key(t, "NEX_XI")) * k
    for n, p, lbl in ((nex, pxi, "XI"), (nex, peta, "ETA")):
        # each slice must hold whole elements and, with one doubling, an even count
        if n % p or (n // p) % 2:
            sys.exit(f"NEX_{lbl}={n} is not an even multiple of NPROC_{lbl}={p}: pick another k or --nproc")
    t = set_key(t, "NEX_XI", nex)
    t = set_key(t, "NEX_ETA", int(get_key(t, "NEX_ETA")) * k)
    t = set_key(t, "NPROC_XI", pxi)
    t = set_key(t, "NPROC_ETA", peta)
    t = set_key(t, "NZ_DOUBLING_1", int(get_key(t, "NZ_DOUBLING_1")) * k)
    t = set_key(t, "LOCAL_PATH", "./OUTPUT_FILES/DATABASES_MPI")

    # region table: 7 integers per line after "NREGIONS = n"
    lines = t.split("\n")
    nreg_i = next(i for i, l in enumerate(lines) if re.match(r"^NREGIONS\s*=", l))
    nreg = int(get_key(t, "NREGIONS"))
    done = 0
    for i in range(nreg_i + 1, len(lines)):
        f = lines[i].split()
        if len(f) == 7 and all(x.lstrip("-").isdigit() for x in f) and not lines[i].lstrip().startswith("#"):
            v = list(map(int, f))
            xb, xe = scale_range(v[0], v[1], k)
            yb, ye = scale_range(v[2], v[3], k)
            zb, ze = scale_range(v[4], v[5], k)
            lines[i] = f"{xb:<15}{xe:<14}{yb:<16}{ye:<15}{zb:<10}{ze:<9}{v[6]}"
            done += 1
            if done == nreg:
                break
    if done != nreg:
        sys.exit(f"found {done} region lines, expected {nreg}")
    mp.write_text("\n".join(lines))

    # --- interfaces.dat: last nlayers lines are element counts per layer ------
    itf = dst / "DATA" / "meshfem3D_files" / "interfaces.dat"
    il = itf.read_text().split("\n")
    data = [i for i, l in enumerate(il) if l.strip() and not l.lstrip().startswith("#")]
    nint = int(il[data[0]].split()[0])
    layer_idx = data[-nint:]
    for i in layer_idx:
        il[i] = re.sub(r"\d+", lambda m: str(int(m.group()) * k), il[i], count=1)
    itf.write_text("\n".join(il))

    # --- Par_file ---------------------------------------------------------------
    pf = dst / "DATA" / "Par_file"
    t = pf.read_text()
    dt = fortran_float(get_key(t, "DT")) / k
    t = set_key(t, "DT", f"{dt:.6g}")
    t = set_key(t, "NSTEP", int(get_key(t, "NSTEP")) * k)
    t = set_key(t, "NPROC", pxi * peta)
    t = set_key(t, "LOCAL_PATH", "./OUTPUT_FILES/DATABASES_MPI")
    t = set_key(t, "HDF5_ENABLED", ".true.")
    t = set_key(t, "HDF5_FORMAT", ".true.")
    t = set_key(t, "HDF5_IO_NODES", a.io_nodes)
    pf.write_text(t)

    # --- run script --------------------------------------------------------------
    np_total = pxi * peta + a.io_nodes
    bindir = (a.specfem / "bin").resolve()
    run = dst / "run.sh"
    run.write_text(f"""#!/bin/bash
# generated by cases/specfem3d/make_case.py (k={k}, {pxi}x{peta} ranks, {a.io_nodes} HDF5 I/O ranks)
set -euo pipefail
cd "$(dirname "$0")"
HOSTFILE="${{HOSTFILE:-/mnt/shared/hostfile}}"
mkdir -p OUTPUT_FILES/DATABASES_MPI
cp DATA/Par_file DATA/CMTSOLUTION DATA/STATIONS DATA/meshfem3D_files/Mesh_Par_file OUTPUT_FILES/
MPI="mpirun -np {pxi * peta} --hostfile $HOSTFILE --map-by core --bind-to core"
date -Is > OUTPUT_FILES/timings.txt
/usr/bin/time -f 'mesher %e s, max RSS rank0 %M KB' $MPI {bindir}/xmeshfem3D 2>> OUTPUT_FILES/timings.txt
/usr/bin/time -f 'databases %e s, max RSS rank0 %M KB' $MPI {bindir}/xgenerate_databases 2>> OUTPUT_FILES/timings.txt
/usr/bin/time -f 'solver %e s, max RSS rank0 %M KB' \\
  mpirun -np {np_total} --hostfile "$HOSTFILE" --map-by core --bind-to core {bindir}/xspecfem3D 2>> OUTPUT_FILES/timings.txt
cat OUTPUT_FILES/timings.txt
grep -E 'total number of elements in entire mesh|End of the simulation' OUTPUT_FILES/output_*.txt || true
""")
    run.chmod(0o755)
    print(f"case written to {dst}")
    print(f"  NEX={nex}x{nex}, NSTEP x{k}, DT={dt:.6g}, ranks={pxi}x{peta} (+{a.io_nodes} HDF5 I/O)")
    print(f"  elements before doubling ~ {nex * nex * 15 * k:,}")


if __name__ == "__main__":
    main()
