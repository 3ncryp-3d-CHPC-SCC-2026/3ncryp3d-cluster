#!/bin/bash
# install.sh - run the same node setup on the PHYSICAL HPE DL325 Gen11 servers
# (no OpenStack, no cloud-init). Run once per server, as root, after Ubuntu
# 24.04 is installed and the HW RAID virtual drives exist (MR408i-o).
#
#   1. On any one machine (Linux/WSL, with the team's keys/ folder filled in):
#        tools/make-team-secrets.sh state/team
#      Copy the repo and state/team/ to all three servers (state/team holds
#      PRIVATE keys: keep it off the repo and off shared drives).
#   2. Edit nodeN.env here: fill in the real MACs (ip -br link) and the RAID
#      virtual drive device paths (lsblk / /dev/disk/by-id).
#   3. Install node3 first (it is the gateway), then node1 and node2:
#        sudo ./install.sh node3.env /path/to/state/team
#   4. On node3: verify-cluster.sh
#
# Old way (no team accounts, ubuntu only): pass a key file instead of the
# folder, made with: ssh-keygen -t ed25519 -N "" -f cluster_ed25519
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: sudo ./install.sh nodeN.env /path/to/state/team   (or /path/to/cluster_ed25519)"
ENV_FILE="${1:?$USAGE}"
SECRETS="${2:?$USAGE}"
TEAM_SECRETS=""
if [[ -d "$SECRETS" ]]; then
  TEAM_SECRETS="$SECRETS"
  KEY="$SECRETS/cluster_ed25519"
else
  KEY="$SECRETS"
fi

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -r "$ENV_FILE" ]] || { echo "$ENV_FILE not readable" >&2; exit 1; }
[[ -r "$KEY" && -r "$KEY.pub" ]] || { echo "need $KEY and $KEY.pub" >&2; exit 1; }
if grep -q "XX:XX" "$ENV_FILE"; then
  echo "$ENV_FILE still has placeholder MACs (XX:XX...). Fill them in from: ip -br link" >&2
  exit 1
fi

install -d -m 755 /etc/cluster /etc/cluster/ssh
install -m 644 "$ENV_FILE" /etc/cluster/node.env
install -m 600 "$KEY" /etc/cluster/ssh/id_ed25519
install -m 644 "$KEY.pub" /etc/cluster/ssh/id_ed25519.pub
install -m 755 "$HERE/../node/cluster-bootstrap.sh" /usr/local/sbin/cluster-bootstrap.sh
if [[ -n "$TEAM_SECRETS" ]]; then
  node="$(sed -n 's/^NODE_NAME=//p' "$ENV_FILE")"
  rm -rf /etc/cluster/team
  "$HERE/../tools/team-bundle.sh" "$TEAM_SECRETS" "$node" | tar -xz -C /etc/cluster
  chmod 700 /etc/cluster/team
fi
if grep -q '^ROLE=head' "$ENV_FILE"; then
  install -m 755 "$HERE/../node/verify-cluster.sh" /usr/local/bin/verify-cluster.sh
  printf 'MIN_LINK_GBPS=9\nMIN_NFS_MBPS=600\n' > /etc/cluster/targets.env
fi

exec /usr/local/sbin/cluster-bootstrap.sh
