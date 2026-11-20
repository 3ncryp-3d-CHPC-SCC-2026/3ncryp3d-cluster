#!/bin/bash
# run.sh - dry-run create_cluster.sh against fake-openstack (no cloud calls).
# Reproduces the three scenarios in docs/openstack-test-review.md.
# Usage: tests/openstack-dryrun/run.sh      (needs bash 4+, ssh-keygen, base64)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# a throwaway copy of the repo, so state/ never lands in the real checkout
cp -r "$REPO" "$WORK/repo"
rm -rf "$WORK/repo/state" "$WORK/repo/.git"
mkdir -p "$WORK/bin" "$WORK/st"
cp "$HERE/fake-openstack" "$WORK/bin/openstack"
cp "$HERE/fake-ssh" "$WORK/bin/ssh"
chmod +x "$WORK/bin/"*
ssh-keygen -q -t ed25519 -N "" -f "$WORK/testkey"

# the handoff's section 4 cluster.env, exactly as written
cat > "$WORK/handoff.env" <<'EOF'
PREFIX="3n3d-test"
IMAGE="Ubuntu 24.04"
FLAVOR_COMPUTE="C6.small"
FLAVOR_HEAD="C6.small"
SHARED_DISKS=2 ; SHARED_DISK_GB=25
LOCAL_DISKS=2  ; LOCAL_DISK_GB=15
MESH_PORT_SECURITY="auto"
MESH_MTU=8950
VENUE_NETWORK="3n3d-test-venue"
MIN_LINK_GBPS=9 ; MIN_NFS_MBPS=600
BOOTSTRAP_TIMEOUT_MIN=40
EOF

run() {  # run <title> <config>
  echo
  echo "=== $1"
  rm -rf "${WORK:?}/st/"* "$WORK/repo/state"
  ( cd "$WORK/repo" && MOCK_ST="$WORK/st" PATH="$WORK/bin:$PATH" \
      bash ./create_cluster.sh --config "$2" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | tail -4 )
  local n
  n="$(grep -c 'FIP REQUESTED' "$WORK/st/calls.log" 2>/dev/null)"
  echo "floating IP requests: ${n:-0}"
}

run "1. handoff section 4 config as written" "$WORK/handoff.env"

{ cat "$WORK/handoff.env"; echo 'ALLOWED_SSH_CIDR="203.0.113.10/32"'; } > "$WORK/handoff+cidr.env"
run "2. same, plus ALLOWED_SSH_CIDR" "$WORK/handoff+cidr.env"

{ cat "$REPO/cluster.env.example"; grep -v '^BOOTSTRAP' "$WORK/handoff.env"
  echo 'ALLOWED_SSH_CIDR="203.0.113.10/32"'
  echo "SSH_PUBLIC_KEY_FILE=$WORK/testkey.pub"
  echo "SSH_PRIVATE_KEY_FILE=$WORK/testkey"
  echo 'BOOTSTRAP_TIMEOUT_MIN=0'   # fail the SSH wait at once instead of after 40 min
} > "$WORK/layered.env"
run "3. template + handoff values (no floating IP)" "$WORK/layered.env"
node3_env="$(awk '/\/etc\/cluster\/node.env/{f=1} f&&/content:/{print $2; exit}' "$WORK/repo/state/3n3d-test/node3.yaml")"
echo "node3 settings sent by cloud-init:"
base64 -d <<<"$node3_env" | grep -E '^(MESH_MTU|SLOTS|UPLINK_MAC)='
echo "password settings in node3 user-data: $(grep -ciE 'chpasswd|password|ssh_pwauth|lock_passwd' "$WORK/repo/state/3n3d-test/node3.yaml")"
