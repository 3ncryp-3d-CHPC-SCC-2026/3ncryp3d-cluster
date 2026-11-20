# 3ncryp+3d cluster — OpenStack test replica: feasibility, safe build, bottlenecks

**Purpose:** stand up an *identical-in-shape* copy of our 3-node switchless DL325 design
as OpenStack VMs on the **Sebowa** cloud (project we already use), to **test the build
and software stack** — separate from, and not disturbing, our other work on that project.
Everything below is **verified live against Sebowa** (quota, flavors, image, external
net, fabric MTU) on 2026-11-20. Nothing has been provisioned. Repo:
`3ncryp-3d-CHPC-SCC-2026/3ncryp3d-cluster` (the repo already ships an OpenStack path:
`create_cluster.sh` + `cluster.env`). **No repo changes needed** — this is all `cluster.env`
config + two `openstack` pre-commands.

---

## 1. CPU (confirmed: repo + AMD datasheet)
1× **AMD EPYC 9135** per node — **16 cores / 32 threads, Zen 5 "Turin" (SP5)**,
3.65 GHz base / **4.3 GHz** boost, 64 MB L3, 200 W, 12-channel **DDR5-6400**,
2×32 GB = 64 GB/node. Three nodes.

## 2. Quota verdict
- **Exact identical sizing does NOT fit** the project: identical needs **48 vCPU / 192 GB RAM /
  2 760 GB disk**, but the project caps are **50 vCPU / 100 GB RAM / 900 GB disk** — RAM and
  storage can't fit even if everything else were deleted. (So "identical hardware-for-hardware"
  is impossible here without an admin quota increase.)
- **A shrunk, same-topology TEST cluster fits easily.** Free headroom: **20 vCPU, 40 GB RAM,
  834 GB disk, 0 floating IPs**. The test build below uses ~18 vCPU / 36 GB / ~140 GB.

## 3. What stays IDENTICAL vs what shrinks
**Identical (and free):** 3-node switchless mesh (3 isolated nets 10.0.12/23/31, fixed port
IPs), node3 = NAT gateway + NFS server + NTP source, NFS `async,rsize/wsize=1M,vers=3,noatime`,
OpenMPI pinned to the mesh subnets, passwordless SSH, **mdadm RAID0 + XFS** on both the shared
array and per-node /scratch, Ubuntu 24.04 + GCC 13, chrony from node3. **Near-identical:**
mesh MTU **8950** (Sebowa fabric max) vs the real 9000 DAC — still jumbo frames. **Shrinks:**
per-node size (6C/12 GB vs 16C/64 GB) and disk GB.

## 4. Ready-to-use `cluster.env` (values verified on Sebowa)
```bash
PREFIX="3n3d-test"
IMAGE="Ubuntu 24.04"                 # exact Sebowa name (space, not hyphen)

FLAVOR_COMPUTE="C6.small"            # 6 vCPU / 12 GB  (most cores/node in budget)
FLAVOR_HEAD="C6.small"              # 3× = 18 vCPU / 36 GB  (leaves 2 vCPU / 4 GB)
#   Conservative alternative: C4.small ×3 = 12 vCPU / 24 GB (leaves 8 vCPU / 16 GB)

# Keep the FULL disk topology (we have 834 GB free) — exercises RAID0+XFS+NFS+/scratch:
SHARED_DISKS=2 ; SHARED_DISK_GB=25   # node3 NFS /mnt/shared RAID0 (50 GB)
LOCAL_DISKS=2  ; LOCAL_DISK_GB=15    # per-node /scratch RAID0 (30 GB × 3)

MESH_PORT_SECURITY="auto"
MESH_MTU=8950                        # Sebowa fabric max — NOT 9000 (would black-hole)

# No-floating-IP, fully-separate egress (see §5):
VENUE_NETWORK="3n3d-test-venue"      # -> script sets USE_FIP=0 (no FIP consumed)

MIN_LINK_GBPS=9 ; MIN_NFS_MBPS=600   # design targets; WARN-only (show the HW gaps honestly)
BOOTSTRAP_TIMEOUT_MIN=40

# ALLOWED_SSH_CIDR / SSH keys: not needed for console-only access (we reach node3 via Horizon)
```

## 5. The three crash-points I found in the scripts — all fixed above
The build **would** crash at these three spots if run with defaults; each is fixed by config only:

| # | Where it crashes | Fix |
|---|---|---|
| **A — Floating IP** | `create_cluster.sh` runs `set -euo pipefail`; default (Option A) hard-sets `USE_FIP=1` → `floating ip create` → **we have 0 free FIPs** → script aborts. | Use **Option B**: set `VENUE_NETWORK` → `USE_FIP=0`. (Alternative: admin grants +1 FIP, then default runs with its **own** separate FIP.) |
| **B — No egress for first-boot `apt`** | node3 installs packages and **NATs for node1/2**; no outbound internet → `apt-get kept failing` → `die`. | node3's venue net **must have a router with an external gateway (SNAT)** — egress only, **no FIP**. Pre-created in §6. |
| **C — Jumbo MTU** | Default `MESH_MTU=9000` > Sebowa fabric **8950** → frames black-hole → MPI/NFS hang. | `MESH_MTU=8950`. |

Two more that just `die` early if unset (fixed above): `IMAGE="Ubuntu 24.04"`, and real flavors
(the repo's `m1.xlarge` **does not exist** on Sebowa).

## 6. Pre-create the dedicated egress network (no FIP, fully separate) — run BEFORE the script
These give the test cluster its **own** router + SNAT egress (so `apt` works) without a floating
IP and without touching our other networks. External net name verified: **"Public Internet"**.
```bash
export OS_CLOUD=sebowa
openstack network create 3n3d-test-venue
openstack subnet create 3n3d-test-venue-subnet \
  --network 3n3d-test-venue --subnet-range 192.168.30.0/24 \
  --dns-nameserver 8.8.8.8 --dns-nameserver 1.1.1.1
openstack router create 3n3d-test-router
openstack router set 3n3d-test-router --external-gateway "Public Internet"
openstack router add subnet 3n3d-test-router 3n3d-test-venue-subnet
```
Then `./create_cluster.sh` with the `cluster.env` above. Reach node3 via the **Horizon VNC
console** (no inbound FIP needed). After boot, sanity-check node3 has a default route out the
venue (egress), then run `verify-cluster.sh`.

## 7. Bottlenecks (what the test can't prove, and what the design itself limits)
**Hardware gaps a VM can't reproduce — `verify-cluster.sh` reports these as `WARN`, not fail:**
- **CPU (biggest):** 16 dedicated Zen-5 cores @ 4.3 GHz, 64 MB L3, DDR5-6400 vs oversubscribed
  hypervisor vCPUs, no NUMA pinning, no clock guarantee → HPL/HPCG/MPI numbers are a fraction and
  **non-deterministic**. Never benchmark performance here — functional test only.
- **Interconnect:** 10G DAC @ MTU 9000 vs shared virtual NIC @ 8950 over the tenant fabric.
- **Storage:** local SSD/HDD RAID0 (≥600 MB/s NFS target) vs network-attached Cinder.

**Inherent design bottlenecks (also true on the real hardware):**
- **node3 is a quadruple single point:** NAT gateway + NFS server + NTP source + only uplink.
  node3 saturated or down ⇒ node1/2 stall or the cluster stops.
- **Switchless 3-node mesh:** each cable carries **both** NFS and MPI for its pair ⇒ IO/compute
  contend on the same link; and it **does not scale past 3 nodes** (no switch).
- **RAID0 everywhere = no redundancy** — one disk/volume loss = data loss (speed over safety).
- **1G venue uplink** — slow external data staging; node1/2 depend wholly on node3.

## 8. Status / decisions still open
- **Safe to test? Yes** — with §4 config + §6 pre-steps, all three crash-points are resolved and
  quota margins hold. Fully isolated from our other work; reach it via the Horizon console.
- **One choice to make:** no-FIP console-only (§6, recommended, zero quota ask) **vs** ask the
  admin for **+1 floating IP** and run the repo default (own separate FIP, direct SSH). Both keep
  the two clusters fully separate — do **not** reuse our existing router/network for egress.
- **Not yet done:** actually provisioning + a `verify-cluster.sh` run (needs the go-ahead).
```
