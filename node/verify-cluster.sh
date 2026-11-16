#!/bin/bash
# shellcheck disable=SC2015  # ok() always returns 0, so "test && ok || bad" is a safe if/else
# verify-cluster.sh - checks the cluster against the design report.
# Run on node3 as user ubuntu:  verify-cluster.sh
# Same checks the team planned for the physical hardware:
#   mesh links up + direct, iperf3 per link, NAT for node1/2, NFS read/write
#   + throughput, passwordless SSH, MPI hostfile launch, RAID 0, time sync.
# Exit code 0 = no FAIL (WARN means "works, but below the real-hardware target").
set -uo pipefail

MIN_LINK_GBPS="${MIN_LINK_GBPS:-9}"
MIN_NFS_MBPS="${MIN_NFS_MBPS:-600}"
# shellcheck source=/dev/null
[[ -r /etc/cluster/targets.env ]] && . /etc/cluster/targets.env

pass=0 warn=0 fail=0
ok()   { echo "  PASS  $*"; pass=$((pass + 1)); }
wrn()  { echo "  WARN  $*"; warn=$((warn + 1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail + 1)); }
hdr()  { echo; echo "== $* =="; }
on()   { local h="$1"; shift; if [[ "$h" == node3 ]]; then bash -c "$*"; else ssh -o BatchMode=yes -o ConnectTimeout=5 "$h" "$*"; fi; }

# link: name  from-node  to-ip  to-node
LINKS=(
  "N1-N2 node1 10.0.12.2 node2"
  "N2-N3 node2 10.0.23.3 node3"
  "N3-N1 node3 10.0.31.1 node1"
)

hdr "Passwordless SSH"
for h in node1 node2; do
  if out="$(on "$h" hostname 2>&1)" && [[ "$out" == "$h" ]]; then
    ok "node3 -> $h"
  else
    bad "node3 -> $h ($out)"
  fi
done
if on node1 "ssh -o BatchMode=yes -o ConnectTimeout=5 node2 hostname" >/dev/null 2>&1; then
  ok "node1 -> node2"
else
  bad "node1 -> node2"
fi

hdr "Mesh links (direct, no hop)"
for l in "${LINKS[@]}"; do
  read -r name from ip _ <<< "$l"
  if on "$from" "ping -c 3 -W 2 $ip" >/dev/null 2>&1; then
    route="$(on "$from" "ip route get $ip" 2>/dev/null | head -1)"
    if [[ "$route" == *" via "* ]]; then
      bad "$name: $ip reachable but ROUTED, not direct: $route"
    else
      ok "$name: $from -> $ip direct"
    fi
  else
    bad "$name: $from cannot reach $ip"
  fi
done

hdr "Link throughput (iperf3, target ${MIN_LINK_GBPS} Gbps)"
for l in "${LINKS[@]}"; do
  read -r name from ip to <<< "$l"
  on "$to" "pkill -x iperf3; iperf3 -s -D -1 -B $ip" >/dev/null 2>&1
  sleep 1
  bps="$(on "$from" "iperf3 -c $ip -t 5 -P 4 -J" 2>/dev/null | jq -r '.end.sum_received.bits_per_second // empty')"
  if [[ -z "$bps" ]]; then
    bad "$name: iperf3 failed"
    continue
  fi
  gbps="$(awk -v b="$bps" 'BEGIN{printf "%.2f", b/1e9}')"
  if awk -v g="$gbps" -v m="$MIN_LINK_GBPS" 'BEGIN{exit !(g>=m)}'; then
    ok "$name: ${gbps} Gbps"
  else
    wrn "$name: ${gbps} Gbps (design target ${MIN_LINK_GBPS}; virtual NIC, not 10G DAC)"
  fi
done

hdr "Internet via node3 NAT"
for h in node1 node2 node3; do
  if on "$h" "curl -s -o /dev/null -m 10 -w '%{http_code}' http://archive.ubuntu.com/ubuntu/" 2>/dev/null | grep -q '^[23]'; then
    ok "$h reaches the internet"
  else
    bad "$h has no internet"
  fi
done
gw1="$(on node1 "ip route show default" 2>/dev/null)"
gw2="$(on node2 "ip route show default" 2>/dev/null)"
[[ "$gw1" == *"via 10.0.31.3"* ]] && ok "node1 default route via node3 (10.0.31.3)" || bad "node1 default route: $gw1"
[[ "$gw2" == *"via 10.0.23.3"* ]] && ok "node2 default route via node3 (10.0.23.3)" || bad "node2 default route: $gw2"

hdr "Storage"
if grep -q "md.*raid0" /proc/mdstat 2>/dev/null; then
  ok "node3 RAID 0: $(grep -c '^md' /proc/mdstat) array(s) active"
else
  wrn "node3: no md RAID 0 (single volume or root-disk mode)"
fi
for h in node1 node2 node3; do
  if on "$h" "mountpoint -q /scratch || test -d /scratch"; then
    ok "$h /scratch: $(on "$h" "df -h --output=size /scratch | tail -1" | tr -d ' ')"
  else
    bad "$h /scratch missing"
  fi
done

hdr "NFS /mnt/shared (from node3 over the direct link)"
token="verify-$$-$(date +%s)"
if on node1 "ls /mnt/shared >/dev/null && echo $token > /mnt/shared/.verify_node1"; then
  if on node2 "cat /mnt/shared/.verify_node1" 2>/dev/null | grep -q "$token"; then
    ok "node1 writes, node2 reads the same file"
  else
    bad "node2 cannot read node1's file"
  fi
else
  bad "node1 cannot write /mnt/shared"
fi
rm -f /mnt/shared/.verify_node1
for h in node1 node2; do
  src="$(on "$h" "findmnt -no SOURCE /mnt/shared" 2>/dev/null | tail -1)"
  want=$([[ $h == node1 ]] && echo 10.0.31.3 || echo 10.0.23.3)
  [[ "$src" == "$want:"* ]] && ok "$h mounts from $src" || bad "$h NFS source is '$src' (expected $want:/mnt/shared)"
done
mbps="$(on node1 "dd if=/dev/zero of=/mnt/shared/.ddtest bs=1M count=1024 conv=fdatasync 2>&1; rm -f /mnt/shared/.ddtest" \
  | awk '/copied/ {for(i=1;i<=NF;i++) if($i ~ /^[MG]B\/s$/){v=$(i-1); if($i=="GB/s") v*=1000; print v}}')"
if [[ -z "$mbps" ]]; then
  bad "NFS write test failed"
elif awk -v v="$mbps" -v m="$MIN_NFS_MBPS" 'BEGIN{exit !(v>=m)}'; then
  ok "NFS write from node1: ${mbps} MB/s"
else
  wrn "NFS write from node1: ${mbps} MB/s (design target ${MIN_NFS_MBPS}; Cinder volume, not local SSD)"
fi

hdr "MPI across all three nodes"
if [[ -f /mnt/shared/hostfile ]]; then
  hosts="$(mpirun --hostfile /mnt/shared/hostfile -np 3 --map-by node hostname 2>&1 | sort -u | tr '\n' ' ')"
  [[ "$hosts" == "node1 node2 node3 " ]] && ok "mpirun -np 3 --map-by node: $hosts" || bad "mpirun hostnames: $hosts"
  mkdir -p /mnt/shared/verify
  cat > /mnt/shared/verify/ring.c <<'EOF'
#include <mpi.h>
#include <stdio.h>
int main(int c, char **v) {
  int r, n, tok = 0; char h[64]; int l;
  MPI_Init(&c, &v); MPI_Comm_rank(MPI_COMM_WORLD, &r); MPI_Comm_size(MPI_COMM_WORLD, &n);
  MPI_Get_processor_name(h, &l);
  if (r == 0) { tok = 1; MPI_Send(&tok,1,MPI_INT,1%n,0,MPI_COMM_WORLD); MPI_Recv(&tok,1,MPI_INT,n-1,0,MPI_COMM_WORLD,MPI_STATUS_IGNORE); printf("ring ok: %d ranks, token=%d\n", n, tok); }
  else { MPI_Recv(&tok,1,MPI_INT,r-1,0,MPI_COMM_WORLD,MPI_STATUS_IGNORE); tok++; MPI_Send(&tok,1,MPI_INT,(r+1)%n,0,MPI_COMM_WORLD); }
  MPI_Finalize(); return 0; }
EOF
  if mpicc -O2 -o /mnt/shared/verify/ring /mnt/shared/verify/ring.c 2>/dev/null; then
    np="$(awk -F'slots=' '{s+=$2} END{print s}' /mnt/shared/hostfile)"
    out="$(mpirun --hostfile /mnt/shared/hostfile -np "$np" /mnt/shared/verify/ring 2>&1)"
    [[ "$out" == *"ring ok: $np ranks, token=$np"* ]] && ok "MPI ring over $np ranks" || bad "MPI ring: $out"
  else
    bad "mpicc failed"
  fi
else
  bad "/mnt/shared/hostfile missing"
fi

hdr "Time sync (node3 is the mesh NTP source)"
for h in node1 node2; do
  if on "$h" "chronyc -n sources" 2>/dev/null | grep -Eq '^\^\*.*10\.0\.(31|23)\.3'; then
    ok "$h synced to node3"
  else
    wrn "$h not (yet) synced to node3"
  fi
done

echo
echo "RESULT: ${pass} pass, ${warn} warn, ${fail} fail"
[[ $fail -eq 0 ]]
