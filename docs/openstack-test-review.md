# Review: OpenStack test-cluster plan (Sebowa), 2026-11-20

This reviews the plan to build a small, same-shape copy of our cluster as
OpenStack VMs on the Sebowa project, using `create_cluster.sh`. The plan was
written as a handoff note (shrunk flavors, no floating IP, a pre-created
egress network, console-only access).

**Method:** `create_cluster.sh` was dry-run against a fake `openstack` command
that behaves like Sebowa as the plan describes it (image `Ubuntu 24.04`,
flavor `C6.small` = 6 vCPU / 12 GB, network MTU 8950, no free floating IPs).
**Nothing was created in OpenStack.** Re-run it any time:

```bash
tests/openstack-dryrun/run.sh
```

## Verdict

**Not safe to run as written.** Two problems stop it (both now handled: see "Update" below). The design itself is fine:
topology, MTU, sizing and the no-floating-IP path all check out.

## Blocking problems

### 1. The plan's `cluster.env` is incomplete

The plan calls its config block "ready to use" and says SSH settings are not
needed. The script requires them:

| Run | Result |
|---|---|
| plan's block as written | `ERROR: set ALLOWED_SSH_CIDR ...` (`create_cluster.sh:52`) |
| plus `ALLOWED_SSH_CIDR` | `SSH_PUBLIC_KEY_FILE: unbound variable` (`create_cluster.sh:54`) |

**Fix:** always start from `cluster.env.example` (`cp cluster.env.example cluster.env`)
and change only the values the plan lists, plus `ALLOWED_SSH_CIDR` and the SSH key paths.

### 2. With no floating IP the script cannot finish, and no one can log in

- node3 only gets a private venue address (`192.168.30.x`). The script then
  waits for every node over SSH **from the machine running it**, which can't
  reach that address. After `BOOTSTRAP_TIMEOUT_MIN` (40 min) it exits with
  an error and `verify-cluster.sh` never runs. `--no-verify` doesn't skip
  this wait.
- The plan's fallback, logging in through the Horizon console, doesn't work.
  Ubuntu cloud images have no password for `ubuntu`, and our cloud-init sets
  none (0 password settings in the generated user-data). The console shows
  a login prompt nobody can pass.

## Claims in the plan that are wrong but harmless

- **"Default MTU 9000 would black-hole frames":** not so. The script ignores
  `MESH_MTU` from the config and uses the smallest real network MTU it finds
  (`create_cluster.sh:131-135`). The dry run picked 8950 by itself, so
  setting it in the config does nothing.
- **"NFS async":** only the client mounts are `async`. The server exports
  `sync` (`node/cluster-bootstrap.sh:296`), so writes really reach the disk.
  That is the right setting; it's just described wrongly.

## What checked out

- No floating IP is requested when `VENUE_NETWORK` is set (this fixes the plan's crash point A).
- Three mesh networks are created with port security disabled, and every port gets its designed fixed address.
- node3's cloud-init gets `MESH_MTU=8950`, `SLOTS=6`, the uplink MAC and the shared volumes.
- Needs 3 instances, 8 volumes and 140 GB of block storage, which fits the free quota the plan reports.

## Recommended path

**Ask the admin for one floating IP**, then use the script's default
(Option A). Leave `VENUE_NETWORK` empty and skip the plan's pre-created
router: the script builds its own router and floating IP, fully separate
from other work in the project. It needs no repo changes, and the run ends
with the automatic `verify-cluster.sh`.

`cluster.env` = `cluster.env.example` with:

```bash
PREFIX="3n3d-test"
IMAGE="Ubuntu 24.04"
FLAVOR_COMPUTE="C6.small"
FLAVOR_HEAD="C6.small"
EXTERNAL_NETWORK="Public Internet"
VENUE_NETWORK=""
ALLOWED_SSH_CIDR="<your public IP>/32"
SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub"
SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_ed25519"
SHARED_DISKS=2 ; SHARED_DISK_GB=25
LOCAL_DISKS=2  ; LOCAL_DISK_GB=15
```

**If a floating IP is impossible**, the no-floating-IP path needs a small repo
change first. Either:
- add a jump-host setting so the script reaches node3 through a machine
  that already has access, or
- set a console password through cloud-init so the Horizon console works.

The second option weakens security. Decide before changing anything.

## Update: the no-floating-IP route is now built (`REPORT_VIA=console`)

No extra floating IP is available (the admin is away), so `create_cluster.sh`
now has a console mode. Both blockers above are dealt with:

- **Blocker 1 fixed for every mode:** `create_cluster.sh` gives every
  setting a default (the same values as `cluster.env.example`), so a short
  `cluster.env` that lists only what it changes no longer crashes.
- **Blocker 2 avoided with `REPORT_VIA="console"`:**
  - The script needs no floating IP, no `ALLOWED_SSH_CIDR` and no SSH key, and
    node3's uplink security group has **no inbound rules at all**.
  - With `VENUE_NETWORK` empty it still builds its own router, which gives
    outbound internet only (apt, NAT for node1/node2). The plan's manual
    router commands (its section 6) are no longer needed.
  - When node3 finishes setting itself up, `node/console-report.sh` waits for
    node1 and node2, runs `verify-cluster.sh` as `ubuntu`, and prints the
    result to node3's **serial console** between `3N3D-REPORT-BEGIN` and
    `3N3D-REPORT-END rc=N` markers. Each line is prefixed `3N3D| `, so kernel
    messages in between are dropped.
  - `create_cluster.sh` reads that with `openstack console log show`, which is
    an API call and needs no network path to the VM. It prints the checks, saves
    the full console log in `state/<prefix>/node3-console.log`, and exits 0 only
    if there were no FAILs.
  - If node3's own setup fails, it reports `rc=bootstrap-failed` with the last
    30 lines of its log, so the script doesn't sit waiting.
  - The console log is visible to project members, so only check results and
    log lines are printed, never keys.
- **Trade-off:** there is no interactive shell. This mode tests that the build
  and the software stack come up and pass the checks. It is not for running
  benchmarks by hand.

`cluster.env` for Sebowa (anything not listed uses the default):

```bash
PREFIX="3n3d-test"
IMAGE="Ubuntu 24.04"
FLAVOR_COMPUTE="C6.small"
FLAVOR_HEAD="C6.small"
EXTERNAL_NETWORK="Public Internet"
REPORT_VIA="console"
SHARED_DISKS=2 ; SHARED_DISK_GB=25
LOCAL_DISKS=2  ; LOCAL_DISK_GB=15
```

Dry-run results (`tests/openstack-dryrun/run.sh`, scenarios 4-7; about 2 minutes on Windows Git Bash):

| Scenario | Result |
|---|---|
| node3 reports all checks passed | prints the checks, exit 0; no floating IP, 0 inbound rules, no keypair, 1 router (egress) |
| node3 reports a FAIL | prints the FAIL, exit 1 |
| node3's own setup failed | prints the failure note, exit 1 |
| `console-report.sh` on a sandboxed node3 | writes BEGIN, the prefixed check lines and `END rc=0` to the console |

Still to confirm on Sebowa with one read-only call before building: that the
project may read console logs (`openstack console log show <any server we own>`).
Nova allows this for project members by default.

## Not verified here (needs read-only OpenStack queries)

The plan's live Sebowa numbers: free quota, the `C6.small` flavor, the
network names, and the volume-count limit for 8 volumes. Check them with
`openstack quota show` and `openstack limits show` before building.
