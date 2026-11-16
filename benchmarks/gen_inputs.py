#!/usr/bin/env python3
"""gen_inputs.py - size HPL.dat / hpccinf.txt / hpcg.dat for the cluster.

Defaults are the bought hardware: 3 nodes x 16 cores (EPYC 9135), 64 GB each.

  python3 gen_inputs.py --out runs/x                       # real cluster
  python3 gen_inputs.py --nodes 1 --cores 8 --mem-gb 15    # practice box
  python3 gen_inputs.py --mem-frac 0.85 --nb 256 384       # sweep NB

Problem size rule: N*N*8 bytes ~= mem_frac of total RAM, rounded down to a
multiple of NB. Process grid: P x Q = ranks, P <= Q, as square as possible.
Rpeak = cores * GHz * 32 DP FLOP/cycle (Zen 5: two 512-bit FMA pipes).
"""
import argparse
import math
import os

p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
p.add_argument("--nodes", type=int, default=3)
p.add_argument("--cores", type=int, default=16, help="MPI ranks per node (1 per core)")
p.add_argument("--mem-gb", type=float, default=64, help="RAM per node, GB")
p.add_argument("--mem-frac", type=float, default=0.80, help="fraction of RAM for the HPL matrix")
p.add_argument("--nb", type=int, nargs="+", default=[384], help="block size(s) to test")
p.add_argument("--ghz", type=float, default=3.65, help="clock for Rpeak (base 3.65, all-core boost 4.25)")
p.add_argument("--flops-per-cycle", type=int, default=32)
p.add_argument("--hpcg-nx", type=int, default=104, help="HPCG local grid (nx=ny=nz)")
p.add_argument("--hpcg-seconds", type=int, default=1800, help="1800 s = official-length run")
p.add_argument("--out", default=".")
a = p.parse_args()

ranks = a.nodes * a.cores
total_bytes = a.nodes * a.mem_gb * 1e9
nb0 = max(a.nb)
n = int(math.sqrt(a.mem_frac * total_bytes / 8) // nb0 * nb0)
P = max(d for d in range(1, int(math.isqrt(ranks)) + 1) if ranks % d == 0)
Q = ranks // P
rpeak = ranks * a.ghz * a.flops_per_cycle

def hpl_body(ns, nbs):
    return f"""HPLinpack benchmark input file
3ncryp+3d: {a.nodes} node(s) x {a.cores} ranks, {a.mem_gb:g} GB/node, {a.mem_frac:.0%} of RAM
HPL.out      output file name (if any)
6            device out (6=stdout,7=stderr,file)
{len(ns)}            # of problems sizes (N)
{' '.join(map(str, ns))}  Ns
{len(nbs)}            # of NBs
{' '.join(map(str, nbs))}  NBs
0            PMAP process mapping (0=Row-,1=Column-major)
1            # of process grids (P x Q)
{P}            Ps
{Q}            Qs
16.0         threshold
1            # of panel fact
2            PFACTs (0=left, 1=Crout, 2=Right)
1            # of recursive stopping criterium
4            NBMINs (>= 1)
1            # of panels in recursion
2            NDIVs
1            # of recursive panel fact.
1            RFACTs (0=left, 1=Crout, 2=Right)
1            # of broadcast
1            BCASTs (0=1rg,1=1rM,2=2rg,3=2rM,4=Lng,5=LnM)
1            # of lookahead depth
1            DEPTHs (>=0)
2            SWAP (0=bin-exch,1=long,2=mix)
64           swapping threshold
0            L1 in (0=transposed,1=no-transposed) form
0            U  in (0=transposed,1=no-transposed) form
1            Equilibration (0=no,1=yes)
8            memory alignment in double (> 0)
"""

os.makedirs(a.out, exist_ok=True)
with open(os.path.join(a.out, "HPL.dat"), "w") as f:
    f.write(hpl_body([n], a.nb))

# HPCC: same HPL section, then its own extra lines (PTRANS etc.). HPCC runs
# several tests in the same memory, so use a smaller matrix (~half of HPL's).
n_hpcc = int(math.sqrt(0.5 * a.mem_frac * total_bytes / 8) // nb0 * nb0)
hpcc = hpl_body([n_hpcc], a.nb).replace("HPL.out      output file name", "hpccoutf.txt output file name")
hpcc += f"""##### This line (no. 32) is ignored (it serves as a separator). ######
0                               Number of additional problem sizes for PTRANS
1200 10000 30000                values of N
0                               number of additional blocking sizes for PTRANS
40 9 8 13 13 20 16 32 64        values of NB
"""
with open(os.path.join(a.out, "hpccinf.txt"), "w") as f:
    f.write(hpcc)

with open(os.path.join(a.out, "hpcg.dat"), "w") as f:
    f.write(f"HPCG benchmark input file\n3ncryp+3d\n{a.hpcg_nx} {a.hpcg_nx} {a.hpcg_nx}\n{a.hpcg_seconds}\n")

mem_used = n * n * 8 / 1e9
print(f"ranks      {ranks} ({a.nodes} x {a.cores}), grid P x Q = {P} x {Q}")
print(f"HPL        N = {n}  NB = {' '.join(map(str, a.nb))}  matrix {mem_used:.1f} GB of {a.nodes * a.mem_gb:g} GB")
print(f"HPCC       N = {n_hpcc}")
print(f"HPCG       local grid {a.hpcg_nx}^3, {a.hpcg_seconds} s")
print(f"Rpeak      {rpeak:,.0f} GFLOPS at {a.ghz} GHz x {a.flops_per_cycle} FLOP/cycle")
print(f"wrote      {os.path.join(a.out, 'HPL.dat')}, hpccinf.txt, hpcg.dat")
