# Failure drills: things that go wrong at competitions

Practise each of these once **before** December, on the real nodes, with a
short job running (HPL with a small N, or the WRF 12 km case). The goal is
a written recovery procedure and a time to recover, not the job result.
Fill in the last column.

| # | Drill | How to cause it | What should happen / what to check | Recovery time |
|---|---|---|---|---|
| 1 | Mesh cable pulled mid-run | unplug DAC A (node1-node2) | MPI job between node1 and node2 hangs or aborts: there is **no second path** in a 3-node triangle without routing. Note how long until mpirun gives up. Plug back in; check `ethtool`, `ping`. | |
| 2 | NFS server restart | `sudo systemctl restart nfs-server` on node3 during IO500 or WRF | with `hard` mounts (the Linux NFS default) clients **pause** instead of failing; the job should resume. Check `dmesg` on node1/node2 for `nfs: server not responding` / `OK`. | |
| 3 | node3 reboot | `sudo reboot` on node3 | node1/node2 lose NFS **and** internet (NAT). Confirm both come back without manual steps after node3 is up (`verify-cluster.sh`). | |
| 4 | Shared disk full | `fallocate -l <free space> /mnt/shared/fill` | which app fails first and how it reports it (WRF: rsl errors; SPECFEM3D: HDF5 errors). Delete the file, check the job folders are intact. | |
| 5 | Out of memory on one node | llama.cpp `stress` model on node1 plus a large HPL on the same node | kernel OOM killer picks a process (`dmesg -T | grep -i oom`). Learn the signs before it happens during a real case. | |
| 6 | Overheating / power cap | HPL soak for 30 min with `tools/power-monitor.sh` | watch for 75 C and falling clock (`turbostat`); try cTDP 200 W and compare GFLOPS | |
| 7 | Wrong clock (time drift) | `sudo date -s '-5 min'` on node2 (chrony will correct it) | MPI and Make complain about clock skew; `chronyc tracking` shows the fix | |
| 8 | Lost iLO password / node unreachable | pretend you can't SSH into node2 | get in through iLO Remote Console from the laptop, fix, document | |

After each drill: run `verify-cluster.sh` and expect 0 FAIL before moving on.
