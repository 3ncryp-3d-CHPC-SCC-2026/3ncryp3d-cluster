# 3ncryp+3d cluster

CHPC Student Cluster Competition, National Round: Team 3ncryp+3d, University of Mpumalanga.
The design report (Rev. 3, matched to the final HPE BOM) is in [`report/`](report/).

## Cluster on OpenStack

Builds the National Round design (3x HPE DL325 Gen11, switchless mesh) as
three OpenStack VMs, wired and configured the way the bought hardware will be.

| Real hardware | OpenStack version |
|---|---|
| 1m DAC cable N1-N2, N2-N3, N3-N1 | one isolated network per cable (10.0.12/23/31.0/24), no router, no DHCP, port security off |
| Fixed port IPs from the report | same IPs, pinned on Neutron ports |
| Node 3 Port 3, J8177E venue uplink | node3-only port on a "venue" network + floating IP, SSH-only security group |
| Node 3 routing + NAT | nftables masquerade on node3; node1/node2 have **no** uplink and use node3 as default gateway |
| 2x 480 GB SSD RAID 0, NFS `/mnt/shared` | 2 Cinder volumes, mdadm RAID 0, XFS, exported to 10.0.31.1 and 10.0.23.2 only |
| 2x 300 GB HDD RAID 0 per node | 2 Cinder volumes per node, RAID 0 at `/scratch` (results backup target) |
| NFS mount `async,rsize/wsize=1M,vers=3,noatime` | same options, each client mounts over its own direct link |
| Passwordless SSH, OpenMPI, hostfile | same; MPI limited to the mesh subnets; `/mnt/shared/hostfile` |
| Ubuntu 24.04, GCC 13 | same image |
| 1x EPYC 9135 16-core, 2x 32 GB DDR5-6400 (64 GB) per node | flavor check warns below 16 vCPU / 64 GB |

Hardware per the HPE quote `CSIR_3ncrypt_3d.xlsx`: node3 has the BCM57504
4-port SFP28 (P26269-B21), 2x 300 GB HDD + 2x 480 GB SSD; node1/node2 have the
BCM57412 2-port SFP+ (P26256-B21) and 2x 300 GB HDD. All three have the MR408i-o
RAID controller and one 800W PSU. Cabling: 3x J9281D 1m DAC, 1x R9F87A 1G RJ45
transceiver.

What cannot match: CPU model and speed (EPYC 9135 Zen 5), real 10G DAC
throughput, local SSD speed, IPMI/thermals. `verify-cluster.sh` reports those
as WARN against the design targets instead of failing.

## Use

```bash
pip install python-openstackclient
source ~/your-project-openrc.sh          # or: export OS_CLOUD=...
cp cluster.env.example cluster.env       # set ALLOWED_SSH_CIDR, IMAGE, flavors
./create_cluster.sh                      # builds, waits, runs the checks
ssh -F state/3n3d/ssh_config node3
```

On node3: `verify-cluster.sh` re-runs every check, `backup-results <dir>`
copies a finished run from `/mnt/shared` to `/scratch/backup`.
First-boot log on each node: `/var/log/cluster-bootstrap.log`.

Small quota? Set `LOCAL_DISKS=0`, lower `SHARED_DISK_GB` and pick a smaller
flavor. The topology stays identical.

`./destroy_cluster.sh` deletes only resources named `<PREFIX>-...`, after you
type the prefix to confirm.

## On the real servers (no OpenStack)

`baremetal/` runs the same `node/` scripts on the physical DL325s:
fill the real MACs and the SSD RAID 0 drive path into `baremetal/node{1,2,3}.env`,
then `sudo baremetal/install.sh nodeN.env cluster_ed25519` on node3 first,
then node1 and node2. Mesh links use MTU 9000 there. Steps are at the top of
`install.sh`.

## More

- [`docs/competition-plan.md`](docs/competition-plan.md): timetable, rules, scoring and per-app prep for the National Round (from chpc-tech-eval/scc-nationals26)
- [`benchmarks/io500/`](benchmarks/io500/): IO500 ISC26 v2 build, run and storage notes
- [`tools/fetch_sources.sh`](tools/fetch_sources.sh): download every source and model for offline use
- [`docs/day1-runbook.md`](docs/day1-runbook.md): unboxing, cabling, iLO, BIOS, RAID, Ubuntu, bring-up, checklists
- [`benchmarks/`](benchmarks/): HPL / HPCG / HPCC build (AMD BLIS zen5), sizing, runs, tuning order
- [`tools/power-monitor.sh`](tools/power-monitor.sh): per-node watts and temperatures from iLO during runs, 75 C warning

## Files

- `create_cluster.sh`: networks, ports, volumes, servers, floating IP, then waits and verifies
- `node/cluster-bootstrap.sh`: first-boot setup on each node (network, NAT, RAID, NFS, NTP, SSH, MPI)
- `node/verify-cluster.sh`: the pre-competition validation checks from the report
- `destroy_cluster.sh`: teardown
- `state/<PREFIX>/`: generated user-data, internal cluster SSH key, ssh_config (git-ignored)
