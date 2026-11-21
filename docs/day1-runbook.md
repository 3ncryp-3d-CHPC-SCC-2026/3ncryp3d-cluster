# Day 1 runbook: from boxes to a working cluster

For the three HPE ProLiant DL325 Gen11 servers in the final BOM.

**When:** hardware collection is **Sunday 6 Dec, 19:00**, and HPL, HPCG and
IO500 are due **Monday 17:50**. Steps 1-8 and the benchmark builds have to be
done on Sunday night. Bring the offline bundle from `tools/fetch_sources.sh`. Work top to
bottom; tick each box. Times are estimates. Anything marked **(verify)** is a
menu name or default that can differ by firmware version: check on the day.

Roles: **N1** = node1 (compute), **N2** = node2 (compute), **N3** = node3
(storage + gateway). Do N3 first wherever there is a choice.

## 0. Before you leave for the venue

- [ ] Ubuntu Server 24.04 LTS ISO on a laptop (for iLO virtual media) and on a USB stick (fallback).
- [ ] Clone of this repo on the laptop, plus an offline copy: `git clone`, then `benchmarks/build_stack.sh` has already downloaded its sources if you ran it once (`benchmarks/build/src/`). Copy that folder too, in case venue internet is slow.
- [ ] Laptop has `ipmitool`, an SSH key, and a cable/adapter for an RJ45 port.
- [ ] A printed copy of this page and of the port map below.

## 1. Unbox and rack (30 min)

- [ ] Check each box against the BOM. Node 3 is the one with **2x 480GB SSD**, the **4-port SFP28** card (P26269-B21) and the OCP1 upgrade cable kit. N1/N2 have the **2-port SFP+** card (P26256-B21).
- [ ] Label the servers N1, N2, N3 on the front bezel and the back.
- [ ] Rails: the quote has 2 rail kits for 3 servers. Rack N1 and N2 on rails and put N3 on a shelf or on top, or ask the organisers for a third kit.
- [ ] One 800W PSU and one power cord per server. Don't power on yet.

## 2. Cabling (15 min)

Each cable is one J9281D 1m 10G SFP+ DAC. "Port 1" is the port the OS lists
first. Confirm it in step 6, and if the order is reversed only the `.env`
files change, not the cables.

| Cable | From | To | Subnet |
|---|---|---|---|
| A | N1 Port 2 | N2 Port 1 | 10.0.12.0/24 |
| B | N2 Port 2 | N3 Port 1 | 10.0.23.0/24 |
| C | N3 Port 2 | N1 Port 1 | 10.0.31.0/24 |
| Venue | N3 Port 3 (R9F87A 1G RJ45 transceiver) | venue RJ45 | assigned on site |
| iLO | dedicated iLO port on each server | laptop or venue mgmt switch | your choice |

- [ ] Port 4 on N3 stays empty (spare).
- [ ] The iLO ports are management only. Don't connect them to the internet.

## 3. iLO first login (10 min per node)

- [ ] Power on. The default iLO user and password are on the **pull-out tag** on the front of each server.
- [ ] Find the iLO IP: it's shown on the POST screen, or set it with **F9 System Utilities > System Configuration > iLO 6 Configuration Utility > Network Options (verify)**.
- [ ] Log into iLO in a browser. **Change the Administrator password straight away.**
- [ ] Create a read-only user `monitor` for `tools/power-monitor.sh` (no config or admin privileges).
- [ ] Enable **IPMI/DCMI over LAN** (Security > Access Settings **(verify)**), needed by the power monitor.
- [ ] The iLO Advanced licence (BD505A) is in the BOM. Confirm it's applied (Administration > Licensing), because Remote Console and Virtual Media need it.

## 4. BIOS settings (10 min per node)

**Faster: script it from the laptop for all three at once:** `laptop\bios-profile.ps1` (two passes, checked against each server's own settings list; see [`performance.md`](performance.md)). The manual steps below are the fallback.

Use F9 System Utilities > System Configuration > BIOS/Platform Configuration (RBSU).

- [ ] **Workload Profile:** start with **High Performance Compute (HPC)** **(verify name)**. It sets power regulator, C-states and determinism for throughput.
- [ ] **Power Regulator:** Static High Performance.
- [ ] **Determinism:** try **Power Determinism** (each CPU runs as fast as its own silicon allows) and compare with Performance Determinism.
- [ ] **NUMA nodes per socket:** NPS1. With only 2 DIMMs there's nothing to gain from splitting.
- [ ] **SMT:** leave on for the build day; test HPL with SMT off later (`benchmarks/README.md`, step 2).
- [ ] **cTDP:** the EPYC 9135 is configurable 200-240 W. If RBSU exposes it, note the setting. The 800W PSU has room either way (report: ~233 W per node at 200 W TDP).
- [ ] Write down every changed setting in `results/bios-settings.md`. This has to be reproducible.

## 5. RAID (MR408i-o) (10 min per node)

F9 System Utilities > System Configuration > **HPE MR408i-o** > Main Menu > Configuration Management > **Create Virtual Drive (verify)**.

- [ ] **All nodes:** virtual drive 1 = the **2x 300GB SAS HDD**, **RAID 0**, default strip size, write cache **Write Back** (the 96W Smart Storage battery is in the BOM). Name it `os`. This is the OS + scratch drive (~600GB).
- [ ] **N3 only:** virtual drive 2 = the **2x 480GB SSD**, **RAID 0**, name `shared`. **Don't install the OS on it.**
- [ ] Set `os` as the boot drive.

## 6. Install Ubuntu 24.04 (20 min per node, in parallel)

iLO > Remote Console > Virtual Media > mount the ISO, then reboot to it.

- [ ] Language and keyboard defaults. Network: skip, or let the venue port use DHCP on N3 only. Mesh ports get configured later by our script.
- [ ] Storage: install to the **~600GB `os` drive only**. On N3, leave the ~960GB `shared` drive untouched (no partitions).
- [ ] User **`ubuntu`** (matches `CLUSTER_USER` in `baremetal/*.env`). Hostname `node1` / `node2` / `node3`.
- [ ] Tick **Install OpenSSH server**. No snaps needed.
- [ ] After reboot: `sudo apt update && sudo apt -y full-upgrade` (N3 now; N1/N2 get internet through N3 after step 8).

## 7. Map ports to MACs (10 min)

On each node:

```bash
ip -br link                       # names + state: cabled ports show UP / LOWER_UP
for i in $(ls /sys/class/net | grep -v lo); do
  printf '%-12s %s  %s\n' "$i" "$(cat /sys/class/net/$i/address)" "$(ethtool -i $i 2>/dev/null | awk '/driver/ {print $2}')"
done
sudo ethtool -p <iface> 10        # blinks that port's LED for 10 s: confirms which physical port it is
```

- [ ] Fill in the real MACs in `baremetal/node1.env`, `node2.env`, `node3.env`, matching the cable table in step 2 (`LINKS` is `MAC|my-ip/24|peer|peer-ip`). Broadcom ports use the `bnxt_en` driver.
- [ ] N3: `lsblk -o NAME,SIZE,MODEL,SERIAL`, then pick the ~894G drive (the SSD RAID 0) and put its `/dev/disk/by-id/...` path in `SHARED_VOLUMES` in `node3.env`. **Double-check that it isn't the OS drive.**

## 8. Bring the cluster up (20 min)

N1 and N2 have no venue link, so everything reaches them through N3.

```bash
# 1. laptop -> N3 (N3 has the venue port)
ssh-keygen -t ed25519 -N "" -f cluster_ed25519
scp -r cluster_ed25519 cluster_ed25519.pub 3ncryp3d-cluster ubuntu@<N3 venue IP>:~

# 2. on N3
sudo ~/3ncryp3d-cluster/baremetal/install.sh ~/3ncryp3d-cluster/baremetal/node3.env ~/cluster_ed25519

# 3. on N1, via iLO Remote Console: temporary address on the port cabled to N3
sudo ip addr add 10.0.31.1/24 dev <N1 Port 1 iface>
#    and on N2:
sudo ip addr add 10.0.23.2/24 dev <N2 Port 2 iface>

# 4. from N3, copy the repo and key over the direct cables (password login)
scp -r ~/3ncryp3d-cluster ~/cluster_ed25519 ~/cluster_ed25519.pub ubuntu@10.0.31.1:~
scp -r ~/3ncryp3d-cluster ~/cluster_ed25519 ~/cluster_ed25519.pub ubuntu@10.0.23.2:~

# 5. on N1 and N2 (install.sh replaces the temporary address with the real config)
sudo ~/3ncryp3d-cluster/baremetal/install.sh ~/3ncryp3d-cluster/baremetal/node1.env ~/cluster_ed25519   # N1
sudo ~/3ncryp3d-cluster/baremetal/install.sh ~/3ncryp3d-cluster/baremetal/node2.env ~/cluster_ed25519   # N2

# 6. every node, and the laptop: the key now lives in /etc/cluster/ssh and ~/.ssh
shred -u ~/cluster_ed25519
```

- [ ] Log: `/var/log/cluster-bootstrap.log` on each node.
- [ ] On N3: `verify-cluster.sh`. **Target: 0 FAIL.** On real hardware the throughput lines must PASS too: iperf3 at or above 9 Gbps per link, NFS at or above 600 MB/s.

## 9. Baseline before tuning (1-2 h)

- [ ] `cp tools/ilo.env.example tools/ilo.env`, fill in the iLO IPs, and put the `monitor` password in the file named by `ILO_PASS_FILE` (chmod 600).
- [ ] Idle baseline: `tools/power-monitor.sh -i 5 -- sleep 600`.
- [ ] On N1: `BLIS_CONFIG=zen5 benchmarks/build_stack.sh` (~10-15 min).
- [ ] First runs: `benchmarks/run_bench.sh hpl --nodes 1`, then `benchmarks/run_bench.sh hpl`.
- [ ] Then follow the tuning order in `benchmarks/README.md`.

## If something goes wrong

| Symptom | Check |
|---|---|
| Mesh port stays DOWN | Reseat the DAC; `ethtool <if>` should show 10000Mb/s; try the cable in another port pair |
| Link up but no ping | Wrong MAC in the `.env`, so the IP is on the other port: `ip -br addr`; fix the `.env` and rerun `install.sh` |
| Ping works, big transfers hang | MTU mismatch: both ends must be 9000 (`ip link show`) |
| N1/N2 no internet | On N3: `sudo nft list ruleset`, `sysctl net.ipv4.ip_forward`; N3's venue port must have an address |
| NFS mount missing on N1/N2 | `ls /mnt/shared` triggers the automount; on N3: `sudo exportfs -v` |
| mpirun hangs | `ssh node2 hostname` from every node without a prompt; `/etc/openmpi/openmpi-mca-params.conf` limits MPI to the mesh |
| Over 75 C in power-monitor | Check fans in iLO, airflow front to back, ambient temperature; consider cTDP 200 W |
