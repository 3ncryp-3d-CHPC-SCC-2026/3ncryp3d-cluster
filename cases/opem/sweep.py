#!/usr/bin/env python3
"""OPEM v1.4 parameter sweep: Amphlett static model over a grid of conditions.

Every run writes its full report (CSV, HTML, .opem) so the file-output part
of the workload is real. Starting point is the Amphlett test vector from the
OPEM README.

Usage: sweep.py --size small|stress|beyond [--workers N] [--out DIR]
"""
import argparse
import itertools
import os
import time
from concurrent.futures import ProcessPoolExecutor, as_completed

BASE = {"T": 343.15, "PH2": 1, "PO2": 1, "i-start": 0, "i-stop": 75, "i-step": 0.1,
        "A": 50.6, "l": 0.0178, "lambda": 23, "N": 1, "R": 0, "JMax": 1.5}


def linspace(a, b, n):
    return [a + (b - a) * i / (n - 1) for i in range(n)] if n > 1 else [a]


GRIDS = {  # (n_T, n_PH2, n_PO2, n_l, i-step)
    "small": (3, 2, 2, 2, 0.1),
    "stress": (10, 5, 5, 4, 0.1),
    "beyond": (20, 10, 10, 5, 0.01),
}


def one_run(args):
    idx, vec, folder = args
    from opem.Static.Amphlett import Static_Analysis
    t0 = time.perf_counter()
    res = Static_Analysis(InputMethod=vec, TestMode=True, PrintMode=False,
                          ReportMode=True, Folder=folder)
    ok = bool(res.get("Status")) if isinstance(res, dict) else False
    pmax = max(res["P"]) if ok and res.get("P") else None
    return idx, ok, pmax, time.perf_counter() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--size", choices=GRIDS, default="small")
    ap.add_argument("--workers", type=int, default=os.cpu_count())
    ap.add_argument("--out", default="/mnt/shared/runs")
    a = ap.parse_args()

    nT, nH, nO, nl, step = GRIDS[a.size]
    grid = itertools.product(linspace(323.15, 353.15, nT), linspace(1, 3, nH),
                             linspace(1, 3, nO), linspace(0.0125, 0.0254, nl))
    run_dir = os.path.join(a.out, f"opem-{a.size}-{time.strftime('%Y%m%d-%H%M%S')}-w{a.workers}")
    os.makedirs(run_dir)
    jobs = []
    for i, (T, ph2, po2, l) in enumerate(grid):
        v = dict(BASE, T=round(T, 2), PH2=round(ph2, 3), PO2=round(po2, 3), l=round(l, 5),
                 **{"i-step": step}, Name=f"run{i:05d}")
        jobs.append((i, v, run_dir))

    print(f"{len(jobs)} runs, {a.workers} workers, reports in {run_dir}")
    t0 = time.perf_counter()
    best, fails = (None, -1.0), 0
    with ProcessPoolExecutor(max_workers=a.workers) as ex:
        for f in as_completed(ex.submit(one_run, j) for j in jobs):
            idx, ok, pmax, _ = f.result()
            if not ok:
                fails += 1
            elif pmax is not None and pmax > best[1]:
                best = (idx, pmax)
    wall = time.perf_counter() - t0
    nfiles = sum(len(fs) for _, _, fs in os.walk(run_dir))
    summary = (f"size={a.size} runs={len(jobs)} failed={fails} workers={a.workers}\n"
               f"wall={wall:.1f}s  files={nfiles}  files/s={nfiles / wall:.1f}\n"
               f"best Pmax={best[1]:.3f} W at run{best[0]:05d}\n")
    print(summary, end="")
    with open(os.path.join(run_dir, "summary.txt"), "w") as fh:
        fh.write(summary)


if __name__ == "__main__":
    main()
