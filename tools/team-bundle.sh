#!/bin/bash
# team-bundle.sh - pack what ONE node needs for the team accounts.
#
#   tools/team-bundle.sh SECRETS_DIR NODE > team.tgz     (NODE = node1|node2|node3)
#
# Extracts to team/ (put it under /etc/cluster/). Each node gets every
# user's internal key and every node's PUBLIC host key, but only its OWN
# private host key, and only node3 (the head) gets the WireGuard key.
# Used by create_cluster.sh (cloud-init) and baremetal/install.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="${1:?usage: team-bundle.sh SECRETS_DIR node1|node2|node3}"
NODE="${2:?usage: team-bundle.sh SECRETS_DIR node1|node2|node3}"
[[ "$NODE" =~ ^node[123]$ ]] || { echo "bad node '$NODE'" >&2; exit 1; }
[[ -d "$SECRETS/users" ]] || { echo "$SECRETS has no users/: run tools/make-team-secrets.sh first" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
umask 077
t="$tmp/team"
mkdir -p "$t/keys/ssh" "$t/keys/wg" "$t/users" "$t/hostkeys" "$t/hostkey" "$t/wg" "$t/bin"

cp "$HERE/config/team.conf" "$t/team.conf"
install -m 755 "$HERE/node/team-setup.sh" "$HERE/node/team-key" "$HERE/node/perf-mode" "$t/bin/"
# Linux performance settings (perf-mode reads them on every boot)
cp "$HERE/config/tuning.conf" "$t/tuning.conf"
cp "$SECRETS"/users/* "$t/users/"
shopt -s nullglob
for f in "$HERE"/keys/ssh/*.pub; do cp "$f" "$t/keys/ssh/"; done
for f in "$HERE"/keys/wg/*.pub; do cp "$f" "$t/keys/wg/"; done
for n in node1 node2 node3; do
  cp "$SECRETS/hostkeys/$n/ssh_host_ed25519_key.pub" "$t/hostkeys/$n.pub"
done
cp "$SECRETS/hostkeys/$NODE/ssh_host_ed25519_key" "$SECRETS/hostkeys/$NODE/ssh_host_ed25519_key.pub" "$t/hostkey/"
if [[ "$NODE" == node3 && -f "$SECRETS/wg/head.key" ]]; then
  cp "$SECRETS/wg/head.key" "$SECRETS/wg/head.pub" "$t/wg/"
fi

tar -C "$tmp" --owner=0 --group=0 -czf - team
