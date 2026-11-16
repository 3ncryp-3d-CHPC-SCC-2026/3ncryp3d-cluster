# IO500 (ISC26 v2): Monday, 6% of the score

Organisers' rules (scc-nationals26 `IO500/README.md`):

- Version **`io500-isc26_v2`** (annotated tag `8cf7aa6` -> commit `8863e64`). Runs start from the tag's own **`config-scc.ini`** (the Student Cluster Competition config: `scc = TRUE`, `stonewall-time = 30`).
- Target filesystem on **persistent** storage in our nodes; **no tmpfs/ramdisk**; data must survive a reboot.
- **At least one client on another node** than the storage (our NFS setup fits).
- **POSIX shared filesystem**: NFS, Lustre, BeeGFS, CephFS are all fine.
- Sized to defeat RAM caching; **bandwidth weighted above metadata**.
- Document the setup: partitioning, RAID, on-disk filesystem, shared filesystem.
- Scores must be **reproducible** (they may ask for a rerun).

## Our setup (what to document)

| Layer | Setting |
|---|---|
| Disks | node3: 2x HPE 480GB SATA 6G Mixed Use SSD (P40502-B21) |
| RAID | MR408i-o hardware RAID 0, 2 drives, write-back cache with battery |
| On-disk FS | XFS on the whole virtual drive, mounted `/mnt/shared` with `noatime` (`cluster-bootstrap.sh`) |
| Shared FS | NFS v3 from node3, export `rw,sync,no_subtree_check`; clients mount over their direct 10G link with `rsize=wsize=1M,async,noatime` |
| Clients | node1 and node2 (and node3 locally) |

Physical ceiling to judge results against: two SATA SSDs in RAID 0 = about
1 GB/s sequential; each 10G link about 1.1 GB/s. Measure the raw array first
(step 1) so the IO500 bandwidth can be reported as a fraction of what the
hardware can do. That's the "weighted by system limitations" part.

## Steps

```bash
# 1. raw baseline on node3 (local array, no NFS): 3 runs each, record results
sudo apt install -y fio
fio --name=seqw --directory=/mnt/shared/fio --rw=write --bs=1M --size=16G --numjobs=4 --direct=1 --group_reporting
fio --name=seqr --directory=/mnt/shared/fio --rw=read  --bs=1M --size=16G --numjobs=4 --direct=1 --group_reporting
fio --name=randw --directory=/mnt/shared/fio --rw=randwrite --bs=4k --size=4G --numjobs=8 --iodepth=32 --ioengine=libaio --direct=1 --group_reporting
rm -rf /mnt/shared/fio

# 2. build (once, on node1; needs MPI + git; sources can come from the USB stick)
benchmarks/io500/build_io500.sh

# 3. run from node3 across all three nodes
benchmarks/io500/run_io500.sh
```

`run_io500.sh` copies the tag's `config-scc.ini`, points `datadir` and
`resultdir` at `/mnt/shared`, runs `io500` with the cluster hostfile, and keeps
the whole result folder (the official `result_summary.txt` and `result.txt`)
under `/mnt/shared/runs/io500-<date>/`. Submit that folder plus the table above.

## Tuning ideas (one at a time, keep every run)

1. **Ranks per node:** IO500 bandwidth phases saturate a SATA array with few
   writers; metadata phases like more ranks. Try 8, 16 and 32 per client.
2. **NFS server threads:** `RPCNFSDCOUNT` / `/etc/nfs.conf [nfsd] threads=` 32-64 on node3.
3. **NFS export `async`** would look faster but breaks "data must reach
   persistent storage". **Don't** use it.
4. **XFS on node3:** `logbsize=256k` mount option, and `noatime` (already set).
5. **Clients on both links:** node1 and node2 each use their own 10G cable to node3, so run clients on both.
6. **MTU 9000** on the mesh is already set; check with `ip link`.
7. **Bigger idea (decide before December, not at the venue):** a parallel
   filesystem (BeeGFS) striping over node3's SSD array *and* spare capacity
   on node1/node2's HDD arrays raises the bandwidth ceiling. It costs a day of
   setup and risk; NFS is the safe default.
