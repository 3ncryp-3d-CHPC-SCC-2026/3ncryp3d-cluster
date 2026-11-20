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

**Not safe to run as written.** Two problems stop it. The design itself is fine:
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

## Not verified here (needs read-only OpenStack queries)

The plan's live Sebowa numbers: free quota, the `C6.small` flavor, the
network names, and the volume-count limit for 8 volumes. Check them with
`openstack quota show` and `openstack limits show` before building.
