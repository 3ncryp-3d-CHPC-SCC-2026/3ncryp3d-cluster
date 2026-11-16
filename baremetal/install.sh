#!/bin/bash
# install.sh - run the same node setup on the PHYSICAL HPE DL325 Gen11 servers
# (no OpenStack, no cloud-init). Run once per server, as root, after Ubuntu
# 24.04 is installed and the HW RAID virtual drives exist (MR408i-o).
#
#   1. On any one machine:   ssh-keygen -t ed25519 -N "" -f cluster_ed25519
#      Copy cluster_ed25519 + cluster_ed25519.pub to all three servers.
#   2. Edit nodeN.env here: fill in the real MACs (ip -br link) and the RAID
#      virtual drive device paths (lsblk / /dev/disk/by-id).
#   3. Install node3 first (it is the gateway), then node1 and node2:
#        sudo ./install.sh node3.env /path/to/cluster_ed25519
#   4. On node3: verify-cluster.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:?usage: sudo ./install.sh nodeN.env /path/to/cluster_ed25519}"
KEY="${2:?usage: sudo ./install.sh nodeN.env /path/to/cluster_ed25519}"

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
if grep -q '^ROLE=head' "$ENV_FILE"; then
  install -m 755 "$HERE/../node/verify-cluster.sh" /usr/local/bin/verify-cluster.sh
  printf 'MIN_LINK_GBPS=9\nMIN_NFS_MBPS=600\n' > /etc/cluster/targets.env
fi

exec /usr/local/sbin/cluster-bootstrap.sh
