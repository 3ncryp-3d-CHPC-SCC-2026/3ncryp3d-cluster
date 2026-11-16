# IO500 practice variants: the ugly cases

The official run (`benchmarks/io500/run_io500.sh`) uses the tag's
`config-scc.ini` (30 s stonewall). These variants push the parts where a
single NFS server on two SATA SSDs suffers. Make a copy of the config, change
one thing, and pass it with `CONFIG=...`.

| Variant | Change in the copied config | What it shows |
|---|---|---|
| bigger than RAM | `[debug] stonewall-time = 300` | 300 s of writing is far more than 192 GB of page cache can hide; you see the real disk speed |
| metadata storm | 32 ranks per node (`run_io500.sh 32`) | mdtest creates and deletes millions of small files on one NFS server. It's the metadata limit, not bandwidth. |
| hard I/O | `[ior-easy] run = FALSE` and `[mdtest-easy] run = FALSE` (with their `-write`/`-read` sections) | only the 47,008-byte interleaved writes of `ior-hard`: worst case for RAID 0 strips |
| one client only | hostfile with node1 only | proves the rule "client on at least one other node"; one 10G cable is the ceiling |
| fill the disk | run "bigger than RAM" with `stonewall-time = 900` | how IO500 fails when `/mnt/shared` fills up. Watch `df -h`; clean `io500-data/` after. |

**Not allowed in the real run** (don't make them habits): tmpfs/ramdisk
targets, NFS export `async`, and skipping the cache drop to inflate reads.
A changed stonewall time may not count as a valid SCC score: use these
variants for practice only.

Record for each: score lines (`[RESULT]`), `free -g` on node3, `iostat -x 5`
on node3 during the run, and `nfsstat -s` before/after.
