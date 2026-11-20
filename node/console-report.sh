#!/bin/bash
# console-report.sh - node3 only, when REPORT_VIA=console (no floating IP).
# Waits for node1/node2 to finish first-boot setup, runs verify-cluster.sh as
# the cluster user, and prints the result to the serial console between
# markers. create_cluster.sh reads it back with `openstack console log show`,
# so no network path into the cluster is needed. Prints only check results
# (no keys or secrets): the console log is visible to project members.
set -uo pipefail

# shellcheck source=/dev/null
. /etc/cluster/node.env
CU="${CLUSTER_USER:-ubuntu}"
TIMEOUT_MIN="${BOOTSTRAP_TIMEOUT_MIN:-40}"
LOG=/var/log/cluster-console-report.log

# the serial console is what the cloud's console log records
con() {
  local t
  for t in /dev/ttyS0 /dev/console; do
    if [[ -w "$t" ]]; then printf '%s\n' "$@" >> "$t"; return 0; fi
  done
  return 0
}

notes=()
deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
for n in node1 node2; do
  until sudo -u "$CU" -H ssh -o BatchMode=yes -o ConnectTimeout=5 "$n" \
        test -f /var/lib/cluster-bootstrap.done 2>/dev/null; do
    if (( $(date +%s) > deadline )); then
      notes+=("$n did not finish first-boot setup within ${TIMEOUT_MIN} min")
      break
    fi
    sleep 15
  done
done

out="$(sudo -u "$CU" -H /usr/local/bin/verify-cluster.sh 2>&1)"
rc=$?
printf '%s\n' "$out" > "$LOG"

con "3N3D-REPORT-BEGIN $(date -Is)"
for line in "${notes[@]}"; do con "3N3D| NOTE: $line"; done
while IFS= read -r line; do con "3N3D| $line"; done <<<"$out"
con "3N3D-REPORT-END rc=$rc"
