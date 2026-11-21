# Performance profile: BIOS and Linux

Out of the box the DL325s trade speed for electricity and noise. This takes
that out in two layers, both config-driven and both recorded so every run
can be reproduced.

| Layer | Settings | Tool | When |
|---|---|---|---|
| BIOS | [`config/bios-profile.conf`](../config/bios-profile.conf) | [`laptop/bios-profile.ps1`](../laptop/bios-profile.ps1), from a Windows laptop through iLO | Sunday, before Ubuntu goes on |
| Linux | [`config/tuning.conf`](../config/tuning.conf) | `perf-mode` on every node ([`node/perf-mode`](../node/perf-mode)) | automatically at install and on every boot |

## Expect 5-15%, not 2x

- **HPL and compute-heavy apps** gain most from steady clocks, no sleep
  states, 240 W and Power Determinism. That's an estimate: the Sunday
  baselines in each mode give the real number.
- **HPCG, WRF and llama.cpp are limited by memory bandwidth** (2 of 12 DDR5
  channels per node). The fabric and memory settings help a little; the bigger
  lever there is fewer ranks per node.
- **More power means more heat.** If a chip overheats it slows itself down
  and the gain is gone, hence fans on Increased Cooling and
  `tools/power-monitor.sh` warning at 75 C.
- **Ask the organisers about a power limit** before using 240 W
  (`PackagePowerLimitValue`). With a cap, the target is "fastest under the cap".

## BIOS (Sunday night, after the iLO passwords are changed)

`tools/ilo.env` holds the three iLO addresses (copy it from
`tools/ilo.env.example`). Then, in PowerShell from the repo folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\laptop\bios-profile.ps1 -Discover                  # what each server offers -> results\bios\
.\laptop\bios-profile.ps1 -Plan -Pass 1              # shows the change, sends nothing
.\laptop\bios-profile.ps1 -Apply -Pass 1 -Reboot     # HPC workload profile
#   ...about 5 minutes while they reboot...
.\laptop\bios-profile.ps1 -Verify -Pass 1
.\laptop\bios-profile.ps1 -Apply -Pass 2 -Reboot     # Custom + our overrides
.\laptop\bios-profile.ps1 -Verify -Pass 2            # exit 1 if anything isn't in place
```

**Why two passes:** a Workload Profile sets about 20 dependent options and
locks them. HPE only lets you change Power Regulator and the C-state setting
when the profile is Custom. Pass 1 applies "High Performance Compute"; pass 2
switches to Custom (keeping the HPC values) and adds our overrides.

**Nothing unknown is sent.** Every name and value is checked against the
server's own BIOS registry first, and anything that server doesn't offer is
skipped with the reason shown. Names follow HPE's iLO 6 Redfish BIOS
reference (v1.62). The real server has the final word, so read the
`-Discover` output once before the first `-Apply`.

`-Reboot` restarts the server immediately. Use it before Ubuntu is
installed, or when nothing is running.

What the profile sets, and why, is commented line by line in
`config/bios-profile.conf`. In short: Static High Performance, no C-states,
boost on, Power Determinism, 240 W, fabric and memory power saving off,
NPS1, Increased Cooling, SR-IOV and IOMMU off, SMT on (test off on Sunday).

## Linux (`perf-mode`)

Installed by the node bootstrap. The first thing it does is **save this
machine's own Ubuntu values** to `/etc/cluster/perf-defaults`, so `default`
really is the factory state, not a guess. It then applies
`PERF_MODE_DEFAULT` (performance), and re-applies the saved mode on every boot.

```bash
perf-mode status                  # every item: WANTED / NOW / OK|DIFF|PENDING
perf-mode status --check          # exit 1 if anything isn't OK (for scripts)
sudo perf-mode performance        # or: default
sudo perf-mode --all performance  # all three nodes
sudo perf-mode dropcaches         # before IO500
```

Performance mode sets:

- **CPU:** performance governor and EPP, boost on, no idle state deeper than
  C1, NMI watchdog off
- **Kernel command line:** `mitigations=off`. This takes effect after a
  reboot, and status shows PENDING until then. Set `MITIGATIONS=on` to keep
  the CPU side-channel defences.
- **Memory:** THP always (defrag madvise), automatic NUMA balancing off, swappiness 10
- **Background jobs stopped and disabled:** unattended-upgrades, apt and
  update timers, snapd, fstrim, man-db and others (`QUIET_UNITS`). An apt
  upgrade or a weekly fstrim halfway through a benchmark ruins the run.
  `default` turns back on whatever was on at install.
- **Network (mesh links only):** NIC rings at hardware maximum, 256 MB socket
  buffer ceilings, a bigger backlog. irqbalance stays on unless `IRQBALANCE=off`.
- **Storage:** `none` scheduler for SSDs, `mq-deadline` for HDDs, 4 MB
  read-ahead on `/mnt/shared`, 32 NFS server threads on the head
- **Limits for every login:** memlock and stack unlimited, nofile 1048576

**Reproducibility:** save `perf-mode status` into every run folder, next to
the BIOS files in `results/bios/`. (Phase 4 adds this to `run-day` automatically.)

## Kernel version: check it on Sunday

The EPYC 9135 is a Zen 5 chip. Ubuntu 24.04's original 6.8 kernel may not
have full Zen 5 support, which can mean an older CPU frequency driver. The
HWE kernel (`linux-generic-hwe-24.04`) is newer. `perf-mode status` shows the
kernel and driver in use (e.g. `cpu governor (amd-pstate-epp)`). Compare an
HPL baseline on both if there's time.

## Tested (2026-11-21)

- **bios-profile.ps1** under PowerShell 7 against
  [`tests/redfish-mock/mock_ilo.py`](../tests/redfish-mock/mock_ilo.py), a fake
  iLO 6 that follows HPE's rules (login required, registry per firmware
  version, locked options ignored unless the profile is Custom). These all
  worked: Discover, Plan, Apply pass 1 + reboot, Verify, Apply pass 2,
  Verify failing before the reboot and passing after, a setting the server
  doesn't offer being skipped, a safe re-run, and a wrong password failing cleanly.
- **perf-mode** on Ubuntu 24.04: install, status, performance, default, boot
  and dropcaches. The CPU part was tested on a fake copy of the CPU settings
  tree (governor, EPP and idle states set and put back, `--check` catching a
  core changed by hand). It found and fixed two bugs along the way.
- The OpenStack dry-run passes. Node scripts now travel gzip-compressed, so
  node3's cloud-init dropped from 58 KB to 37 KB (limit 64 KB).

**Not yet tested:** a real iLO (the names are HPE's documented ones, and the
registry check guards the rest), Windows PowerShell 5.1 (the script has a
5.1 code path for iLO's certificate), real Zen 5 frequency control, and the
speed gain itself. All of these need the hardware: Sunday night.
