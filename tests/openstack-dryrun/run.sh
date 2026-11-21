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

# Missing settings now fall back to the defaults in create_cluster.sh, so the
# short config gets as far as the SSH wait (which fails: no floating IP).
{ cat "$WORK/handoff.env"; echo 'ALLOWED_SSH_CIDR="203.0.113.10/32"'
  echo "SSH_PUBLIC_KEY_FILE=$WORK/testkey.pub"; echo 'BOOTSTRAP_TIMEOUT_MIN=0'; } > "$WORK/handoff+cidr.env"
run "2. same, plus ALLOWED_SSH_CIDR (other settings use defaults)" "$WORK/handoff+cidr.env"

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

# ---------------------------------------------------------------------------
# Console mode (REPORT_VIA=console): no floating IP, no inbound access.
# A minimal config: no ALLOWED_SSH_CIDR, no SSH key, script builds its own router.
cat > "$WORK/console.env" <<EOF2
PREFIX="3n3d-test"
IMAGE="Ubuntu 24.04"
FLAVOR_COMPUTE="C6.small"
FLAVOR_HEAD="C6.small"
EXTERNAL_NETWORK="Public Internet"
REPORT_VIA="console"
SSH_PUBLIC_KEY_FILE="$WORK/no-such-key.pub"
SHARED_DISKS=2 ; SHARED_DISK_GB=25
LOCAL_DISKS=2  ; LOCAL_DISK_GB=15
EOF2

console_log() {  # console_log <rc> <body line>
  printf '[   12.3] cloud-init: modules final\n3N3D-REPORT-BEGIN 2026-11-20T20:10:00+00:00\n'
  printf '3N3D| == Passwordless SSH ==\n[   99.1] random kernel message\n3N3D| %s\n' "$2"
  printf '3N3D-REPORT-END rc=%s\n' "$1"
}

run_console() {  # run_console <title> <console file>
  echo
  echo "=== $1"
  rm -rf "${WORK:?}/st/"* "$WORK/repo/state"
  local out rc fip ingress keyname router
  out="$(cd "$WORK/repo" && MOCK_ST="$WORK/st" MOCK_CONSOLE="$2" PATH="$WORK/bin:$PATH" \
      bash ./create_cluster.sh --config "$WORK/console.env" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -vE '^==> (Checking|Preflight|Keypairs|Mesh|Venue|Ports|Volumes|Cloud|Servers|Attaching)|maxTotal|^WARN: flavor|^$'
  echo "exit code: $rc"
  fip="$(grep -c 'FIP REQUESTED' "$WORK/st/calls.log")"
  ingress="$(grep -c 'security group rule create' "$WORK/st/calls.log")"
  keyname="$(grep -c -- '--key-name' "$WORK/st/calls.log")"
  router="$(grep -c 'router create' "$WORK/st/calls.log")"
  echo "floating IP requests: ${fip:-0}  inbound rules: ${ingress:-0}  --key-name: ${keyname:-0}  routers created: ${router:-0}"
}

console_log 0 "  PASS  node3 -> node1" > "$WORK/console-pass.txt"
run_console "4. console mode, node3 reports all checks passed" "$WORK/console-pass.txt"
console_log 1 "  FAIL  node3 -> node2 (timeout)" > "$WORK/console-fail.txt"
run_console "5. console mode, node3 reports a FAIL" "$WORK/console-fail.txt"
console_log bootstrap-failed "node3 first-boot setup FAILED (exit 1)" > "$WORK/console-boot.txt"
run_console "6. console mode, node3's own setup failed" "$WORK/console-boot.txt"

# ---------------------------------------------------------------------------
# 7. node3's reporter (node/console-report.sh) in a sandbox: fake sudo/ssh/
#    verify-cluster, and a plain file standing in for the serial console.
echo
echo "=== 7. node/console-report.sh on a sandboxed node3"
SB="$WORK/sb"; mkdir -p "$SB/bin"
printf 'REPORT_VIA=console\nBOOTSTRAP_TIMEOUT_MIN=1\n' > "$SB/node.env"
: > "$SB/ttyS0"
printf '#!/bin/bash\n# drop "-u user -H"\nshift 3; exec "$@"\n' > "$SB/bin/sudo"
printf '#!/bin/bash\nexit 0\n' > "$SB/bin/ssh"
printf '#!/bin/bash\necho "== Passwordless SSH =="\necho "  PASS  node3 -> node1"\necho "  WARN  iperf3 N1-N2 2.1 Gbit/s"\nexit 0\n' > "$SB/verify"
chmod +x "$SB/bin/"* "$SB/verify"
sed -e "s|/etc/cluster/node.env|$SB/node.env|" -e "s|/dev/ttyS0 /dev/console|$SB/ttyS0|" \
    -e "s|/usr/local/bin/verify-cluster.sh|$SB/verify|" -e "s|/var/log/cluster-console-report.log|$SB/report.log|" \
    "$REPO/node/console-report.sh" > "$SB/console-report.sh"
PATH="$SB/bin:$PATH" bash "$SB/console-report.sh"
cat "$SB/ttyS0"

# ---------------------------------------------------------------------------
# 8. Team accounts (config/team.conf) in the cloud-init user-data: hostnames,
#    the per-node bundle, and that private keys only go where they belong.
teamcheck() {  # teamcheck <node> <yaml>
  local y="$1" b
  b="$(awk '/\/etc\/cluster\/team.tgz/{f=1} f&&/content:/{print $2; exit}' "$y")"
  if [[ -z "$b" ]]; then echo "  $(basename "$y"): no team bundle"; return; fi
  printf '  %s: hostname=%s  user-data=%s bytes  bundle: ' "$(basename "$y")" \
    "$(sed -n 's/^hostname: //p' "$y")" "$(wc -c < "$y")"
  base64 -d <<<"$b" | tar -tzf - | grep -cE 'users/[^/]+_ed25519$' | tr -d '\n'
  printf ' user keys, own host key=%s, VPN key=%s\n' \
    "$(base64 -d <<<"$b" | tar -tzf - | grep -c 'hostkey/ssh_host_ed25519_key$')" \
    "$(base64 -d <<<"$b" | tar -tzf - | grep -c 'wg/head.key')"
}
echo
echo "=== 8. team accounts: hostnames and per-node bundles (expect VPN key on node3 only)"
run_console "8a. console mode build with config/team.conf" "$WORK/console-pass.txt" >/dev/null
for n in node1 node2 node3; do teamcheck "$WORK/repo/state/3n3d-test/$n.yaml"; done
echo "  user-data limit is 65535 bytes (Nova)"
# the compressed bootstrap must unpack to exactly the repo's script
boot="$(awk '/cluster-bootstrap.sh/{f=1} f&&/content:/{print $2; exit}' "$WORK/repo/state/3n3d-test/node3.yaml")"
if base64 -d <<<"$boot" | gunzip | cmp -s - "$REPO/node/cluster-bootstrap.sh"; then
  echo "  gz+b64 bootstrap in node3.yaml unpacks to node/cluster-bootstrap.sh: OK"
else
  echo "  gz+b64 bootstrap in node3.yaml does NOT match node/cluster-bootstrap.sh"
fi

echo
echo "=== 9. TEAM_ACCOUNTS=no keeps the old build"
echo 'TEAM_ACCOUNTS="no"' >> "$WORK/console.env"
run_console "9a. console mode build without team accounts" "$WORK/console-pass.txt" >/dev/null
for n in node1 node3; do teamcheck "$WORK/repo/state/3n3d-test/$n.yaml"; done
grep -h '^hostname:' "$WORK/repo/state/3n3d-test/node3.yaml" | sed 's/^/  node3.yaml /'
