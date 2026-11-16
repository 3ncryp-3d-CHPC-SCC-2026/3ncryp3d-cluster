#!/bin/bash
# destroy_cluster.sh - delete ONLY the resources create_cluster.sh made
# (everything named "<PREFIX>-..."). Shows the list and asks you to type the
# prefix before deleting anything. Volume data is lost.
#
# Usage: ./destroy_cluster.sh [--yes] [--config FILE]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/cluster.env"
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --config) CONFIG="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -f "$CONFIG" ]] || { echo "config $CONFIG not found" >&2; exit 1; }
# shellcheck source=cluster.env.example
. "$CONFIG"
[[ -n "${PREFIX:-}" ]] || { echo "PREFIX is empty, refusing" >&2; exit 1; }

val() { openstack "$@" -f value; }
mine() { grep -E "^${PREFIX}-" || true; }

servers="$(val server list -c Name | mine)"
ports="$(val port list -c Name | mine)"
volumes="$(val volume list -c Name | mine)"
routers="$(val router list -c Name | mine)"
networks="$(val network list -c Name | mine)"
sgs="$(val security group list -c Name | mine)"
keypair="$(val keypair list -c Name | mine)"

echo "Resources with prefix '${PREFIX}-':"
for kind in servers ports volumes routers networks sgs keypair; do
  printf '  %-9s %s\n' "$kind:" "$(echo "${!kind}" | tr '\n' ' ')"
done

if (( ! ASSUME_YES )); then
  read -r -p "Type the prefix '${PREFIX}' to delete all of the above: " ans
  [[ "$ans" == "$PREFIX" ]] || { echo "aborted"; exit 1; }
fi

for p in $ports; do
  for fip in $(val floating ip list --port "$p" -c ID); do
    echo "deleting floating ip $fip"
    openstack floating ip delete "$fip"
  done
done
for s in $servers; do
  echo "deleting server $s"
  openstack server delete --wait "$s"
done
for p in $ports; do
  openstack port delete "$p" 2>/dev/null && echo "deleted port $p" || true
done
for v in $volumes; do
  for _ in $(seq 1 30); do
    [[ "$(val volume show "$v" -c status)" == available ]] && break
    sleep 5
  done
  echo "deleting volume $v"
  openstack volume delete "$v"
done
for r in $routers; do
  for sub in $(val subnet list -c Name | mine); do
    openstack router remove subnet "$r" "$sub" 2>/dev/null || true
  done
  openstack router unset --external-gateway "$r" 2>/dev/null || true
  echo "deleting router $r"
  openstack router delete "$r"
done
for n in $networks; do
  echo "deleting network $n"
  openstack network delete "$n"
done
for g in $sgs; do
  echo "deleting security group $g"
  openstack security group delete "$g"
done
for k in $keypair; do
  echo "deleting keypair $k"
  openstack keypair delete "$k"
done
echo "done. Local state (cluster SSH key, user-data) is still in $HERE/state/${PREFIX}"
