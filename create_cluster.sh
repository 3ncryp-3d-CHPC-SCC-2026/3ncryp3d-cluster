#!/bin/bash
# create_cluster.sh - build the 3ncryp+3d competition cluster on OpenStack,
# wired the same way as the physical HPE DL325 Gen11 build:
#
#            venue uplink (floating IP)
#                    |
#                 [node3]  storage + gateway: RAID 0 /mnt/shared (NFS), NAT
#                 /     \
#      10.0.31.0/24     10.0.23.0/24
#               /         \
#          [node1]-------[node2]
#               10.0.12.0/24   compute <-> compute (MPI)
#
# Each "cable" is its own isolated Neutron network with no router and no
# DHCP, so a node can only reach a peer over the direct link, exactly like
# the switchless DAC mesh. node1/node2 have no uplink; they reach the
# internet only through node3's NAT.
#
# Usage:
#   source <your-openrc.sh>          (or export OS_CLOUD=...)
#   cp cluster.env.example cluster.env && edit it
#   ./create_cluster.sh [--no-verify] [--config FILE]
#
# Re-running is safe: existing resources with the same names are reused.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/cluster.env"
VERIFY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-verify) VERIFY=0 ;;
    --config) CONFIG="$2"; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$CONFIG" ]] || die "config $CONFIG not found (copy cluster.env.example to cluster.env)"
# shellcheck source=cluster.env.example
. "$CONFIG"

# Defaults for every setting, so a cluster.env that only lists what it
# changes still works (values match cluster.env.example).
: "${PREFIX:=3n3d}" "${IMAGE:=Ubuntu-24.04}"
: "${FLAVOR_COMPUTE:=m1.xlarge}" "${FLAVOR_HEAD:=m1.xlarge}"
: "${EXTERNAL_NETWORK:=public}" "${VENUE_CIDR:=192.168.30.0/24}" "${DNS_SERVERS:=8.8.8.8 1.1.1.1}"
: "${VENUE_NETWORK:=}" "${ALLOWED_SSH_CIDR:=}" "${REPORT_VIA:=ssh}"
: "${SSH_PUBLIC_KEY_FILE:=$HOME/.ssh/id_ed25519.pub}" "${SSH_PRIVATE_KEY_FILE:=$HOME/.ssh/id_ed25519}"
: "${LINK_12_CIDR:=10.0.12.0/24}" "${LINK_23_CIDR:=10.0.23.0/24}" "${LINK_31_CIDR:=10.0.31.0/24}"
: "${MESH_PORT_SECURITY:=auto}" "${TEAM_ACCOUNTS:=yes}"
: "${SHARED_DISKS:=2}" "${SHARED_DISK_GB:=480}" "${SHARED_VOLUME_TYPE:=}"
: "${LOCAL_DISKS:=2}" "${LOCAL_DISK_GB:=300}" "${LOCAL_VOLUME_TYPE:=}"
: "${MIN_LINK_GBPS:=9}" "${MIN_NFS_MBPS:=600}" "${BOOTSTRAP_TIMEOUT_MIN:=40}"

case "$REPORT_VIA" in
  ssh) need=(openstack ssh ssh-keygen base64 gzip awk) ;;
  console) need=(openstack ssh-keygen base64 gzip awk) ;;
  *) die "REPORT_VIA must be 'ssh' or 'console' (got '$REPORT_VIA')" ;;
esac
for cmd in "${need[@]}"; do
  command -v "$cmd" >/dev/null || die "'$cmd' not found (pip install python-openstackclient for openstack)"
done
if [[ "$REPORT_VIA" == ssh ]]; then
  [[ -n "$ALLOWED_SSH_CIDR" ]] || die "set ALLOWED_SSH_CIDR in $CONFIG (e.g. your.public.ip/32), or use REPORT_VIA=console when no floating IP is available"
  [[ "$ALLOWED_SSH_CIDR" != "0.0.0.0/0" ]] || warn "ALLOWED_SSH_CIDR is 0.0.0.0/0: node3 SSH open to the whole internet"
  [[ -r "$SSH_PUBLIC_KEY_FILE" ]] || die "SSH public key $SSH_PUBLIC_KEY_FILE not readable"
else
  log "REPORT_VIA=console: no floating IP, no inbound access; results come back through node3's console log"
fi

STATE="$HERE/state/$PREFIX"
mkdir -p "$STATE"
chmod 700 "$HERE/state" "$STATE"

os() { openstack "$@"; }
val() { openstack "$@" -f value; }
exists() { openstack "$@" >/dev/null 2>&1; }
b64() { base64 < "$1" | tr -d '\n'; }

# ---------------------------------------------------------------------------
log "Checking OpenStack credentials"
exists token issue || die "OpenStack auth failed: source your openrc (or set OS_CLOUD) first"

log "Preflight: image, flavors, networks, quotas"
exists image show "$IMAGE" || die "image '$IMAGE' not found (openstack image list)"
for f in "$FLAVOR_COMPUTE" "$FLAVOR_HEAD"; do
  exists flavor show "$f" || die "flavor '$f' not found (openstack flavor list)"
done
check_flavor() {
  local f="$1" vcpus ram
  vcpus="$(val flavor show "$f" -c vcpus)"
  ram="$(val flavor show "$f" -c ram)"
  if (( vcpus < 16 || ram < 64000 )); then
    warn "flavor $f = ${vcpus} vCPU / $((ram / 1024)) GB; real node = 16 cores / 64 GB. Topology and behaviour match, raw performance will not."
  fi
}
check_flavor "$FLAVOR_COMPUTE"
check_flavor "$FLAVOR_HEAD"
SLOTS="$(val flavor show "$FLAVOR_COMPUTE" -c vcpus)"
HEAD_SLOTS="$(val flavor show "$FLAVOR_HEAD" -c vcpus)"
(( HEAD_SLOTS < SLOTS )) && SLOTS="$HEAD_SLOTS"
if [[ -z "${VENUE_NETWORK:-}" ]]; then
  exists network show "$EXTERNAL_NETWORK" || die "external network '$EXTERNAL_NETWORK' not found"
fi
need_gb=$(( SHARED_DISKS * SHARED_DISK_GB + 3 * LOCAL_DISKS * LOCAL_DISK_GB ))
need_vols=$(( SHARED_DISKS + 3 * LOCAL_DISKS ))
log "This build needs 3 instances, $need_vols volumes, ${need_gb} GB block storage, 4 networks"
os limits show --absolute 2>/dev/null | grep -Ei 'Instances|Cores|RAM|Volume|Gigabytes' || true

# ---------------------------------------------------------------------------
log "Keypairs"
KEYPAIR="${PREFIX}-key"
KEY_ARGS=()
if [[ -r "$SSH_PUBLIC_KEY_FILE" ]]; then
  if ! exists keypair show "$KEYPAIR"; then
    os keypair create --public-key "$SSH_PUBLIC_KEY_FILE" "$KEYPAIR" >/dev/null
  fi
  KEY_ARGS=(--key-name "$KEYPAIR")
fi
# Internal key for passwordless SSH between the nodes (stays in state/).
if [[ ! -f "$STATE/cluster_ed25519" ]]; then
  ssh-keygen -q -t ed25519 -N "" -C "${PREFIX}-cluster" -f "$STATE/cluster_ed25519"
fi

# Team accounts (config/team.conf): users, laptop keys, hostnames, VPN.
# TEAM_ACCOUNTS=no builds the old way (ubuntu only, node1/2/3).
TEAM_HOSTNAMES=()
if [[ "$TEAM_ACCOUNTS" == yes && -f "$HERE/config/team.conf" ]]; then
  log "Team accounts from config/team.conf"
  "$HERE/tools/make-team-secrets.sh" "$STATE/team" >&2
  # shellcheck source=config/team.conf
  HP="$(. "$HERE/config/team.conf"; echo "${HOST_PREFIX:-}")"
  NA="$(. "$HERE/config/team.conf"; echo "${NODE_ALIASES:-}")"
  for n in node1 node2 node3; do
    a="$n"
    for pair in $NA; do [[ "${pair%%=*}" == "$n" ]] && a="${pair#*=}"; done
    TEAM_HOSTNAMES+=("${HP:+${HP}-}${a}")
    "$HERE/tools/team-bundle.sh" "$STATE/team" "$n" > "$STATE/team-$n.tgz"
  done
fi

# ---------------------------------------------------------------------------
log "Mesh links (one isolated network per DAC cable)"
MESH_PS_DISABLED=0
make_link() {
  local id="$1" cidr="$2" net="${PREFIX}-link-$1" sub="${PREFIX}-link-$1-subnet"
  if ! exists network show "$net"; then
    if [[ "$MESH_PORT_SECURITY" != "on" ]] && \
       os network create --disable-port-security "$net" >/dev/null 2>&1; then
      :
    else
      [[ "$MESH_PORT_SECURITY" == "off" ]] && die "cloud refused --disable-port-security on $net"
      os network create "$net" >/dev/null
    fi
  fi
  if ! exists subnet show "$sub"; then
    os subnet create "$sub" --network "$net" --subnet-range "$cidr" \
      --no-dhcp --gateway none >/dev/null
  fi
  if [[ "$(val network show "$net" -c port_security_enabled)" == "False" ]]; then
    MESH_PS_DISABLED=$((MESH_PS_DISABLED + 1))
  fi
}
make_link 12 "$LINK_12_CIDR"
make_link 23 "$LINK_23_CIDR"
make_link 31 "$LINK_31_CIDR"
MESH_MTU=9000
for id in 12 23 31; do
  m="$(val network show "${PREFIX}-link-$id" -c mtu)"
  (( m < MESH_MTU )) && MESH_MTU="$m"
done
log "mesh MTU ${MESH_MTU}; port security disabled on ${MESH_PS_DISABLED}/3 links"

MESH_SG="${PREFIX}-mesh"
if (( MESH_PS_DISABLED < 3 )); then
  # Fallback: port security stays on, so allow everything between mesh peers
  # and let node3 forward foreign source addresses (allowed-address-pairs).
  if ! exists security group show "$MESH_SG"; then
    os security group create "$MESH_SG" --description "3ncryp3d mesh: trusted links" >/dev/null
    # Traffic node1/node2 -> internet enters node3 with a 10.0.x source.
    # Replies coming back are allowed by the group's connection tracking.
    os security group rule create "$MESH_SG" --ingress --protocol any \
      --remote-ip 10.0.0.0/16 >/dev/null
  fi
fi

# ---------------------------------------------------------------------------
log "Venue uplink for node3"
UPLINK_SG="${PREFIX}-uplink"
if ! exists security group show "$UPLINK_SG"; then
  if [[ "$REPORT_VIA" == ssh ]]; then
    os security group create "$UPLINK_SG" --description "3ncryp3d node3 uplink: SSH only" >/dev/null
    os security group rule create "$UPLINK_SG" --ingress --protocol tcp --dst-port 22 \
      --remote-ip "$ALLOWED_SSH_CIDR" >/dev/null
    os security group rule create "$UPLINK_SG" --ingress --protocol icmp \
      --remote-ip "$ALLOWED_SSH_CIDR" >/dev/null
  else
    # console mode: outbound only (apt, NAT for node1/2), no inbound rules at all
    os security group create "$UPLINK_SG" --description "3ncryp3d node3 uplink: egress only" >/dev/null
  fi
fi

USE_FIP=0
if [[ -n "${VENUE_NETWORK:-}" ]]; then
  VENUE_NET="$VENUE_NETWORK"
  exists network show "$VENUE_NET" || die "VENUE_NETWORK '$VENUE_NET' not found"
else
  # Our own venue network + router (the router's external gateway gives
  # outbound SNAT). A floating IP is only needed for inbound SSH.
  [[ "$REPORT_VIA" == ssh ]] && USE_FIP=1
  VENUE_NET="${PREFIX}-venue"
  exists network show "$VENUE_NET" || os network create "$VENUE_NET" >/dev/null
  if ! exists subnet show "${VENUE_NET}-subnet"; then
    dns_args=()
    for d in $DNS_SERVERS; do dns_args+=(--dns-nameserver "$d"); done
    os subnet create "${VENUE_NET}-subnet" --network "$VENUE_NET" \
      --subnet-range "$VENUE_CIDR" "${dns_args[@]}" >/dev/null
  fi
  ROUTER="${PREFIX}-router"
  if ! exists router show "$ROUTER"; then
    os router create "$ROUTER" >/dev/null
    os router set "$ROUTER" --external-gateway "$EXTERNAL_NETWORK"
    os router add subnet "$ROUTER" "${VENUE_NET}-subnet"
  fi
fi

# ---------------------------------------------------------------------------
log "Ports with the designed fixed addresses"
# port <name> <network> <ip-or-empty> [secgroup]
make_port() {
  local name="$1" net="$2" ip="$3" sg="${4:-}" args=()
  if ! exists port show "$name"; then
    if [[ -n "$ip" ]]; then
      args+=(--fixed-ip "subnet=${net}-subnet,ip-address=${ip}")
    fi
    if [[ -n "$sg" ]]; then
      args+=(--security-group "$sg")
    fi
    os port create --network "$net" "${args[@]}" "$name" >/dev/null
  fi
  val port show "$name" -c id
}
mesh_port() {
  local name="$1" link="$2" ip="$3" forwards="${4:-no}" id
  if (( MESH_PS_DISABLED == 3 )); then
    id="$(make_port "$name" "${PREFIX}-link-$link" "$ip")"
  else
    id="$(make_port "$name" "${PREFIX}-link-$link" "$ip" "$MESH_SG")"
    if [[ "$forwards" == yes ]]; then
      os port set "$id" --allowed-address ip-address=0.0.0.0/0 >/dev/null
    fi
  fi
  echo "$id"
}
# node1: Port1 -> N3 (10.0.31.1), Port2 -> N2 (10.0.12.1)
P_N1_31="$(mesh_port "${PREFIX}-node1-p1-n3" 31 10.0.31.1)"
P_N1_12="$(mesh_port "${PREFIX}-node1-p2-n2" 12 10.0.12.1)"
# node2: Port1 -> N1 (10.0.12.2), Port2 -> N3 (10.0.23.2)
P_N2_12="$(mesh_port "${PREFIX}-node2-p1-n1" 12 10.0.12.2)"
P_N2_23="$(mesh_port "${PREFIX}-node2-p2-n3" 23 10.0.23.2)"
# node3: Port1 -> N2 (10.0.23.3), Port2 -> N1 (10.0.31.3), Port3 venue uplink
P_N3_23="$(mesh_port "${PREFIX}-node3-p1-n2" 23 10.0.23.3 yes)"
P_N3_31="$(mesh_port "${PREFIX}-node3-p2-n1" 31 10.0.31.3 yes)"
P_N3_UP="$(make_port "${PREFIX}-node3-p3-uplink" "$VENUE_NET" "" "$UPLINK_SG")"
mac() { val port show "$1" -c mac_address; }

# ---------------------------------------------------------------------------
log "Volumes (node3 SSD RAID 0 shared array, per-node local RAID 0 arrays)"
make_vol() {
  local name="$1" size="$2" type="$3" args=()
  [[ -n "$type" ]] && args+=(--type "$type")
  if ! exists volume show "$name"; then
    os volume create --size "$size" "${args[@]}" "$name" >/dev/null
  fi
  val volume show "$name" -c id
}
declare -A LOCAL_VOLS
for n in node1 node2 node3; do
  LOCAL_VOLS[$n]=""
  for i in $(seq 1 "$LOCAL_DISKS"); do
    LOCAL_VOLS[$n]+="$(make_vol "${PREFIX}-${n}-hdd${i}" "$LOCAL_DISK_GB" "$LOCAL_VOLUME_TYPE") "
  done
done
SHARED_VOLS=""
for i in $(seq 1 "$SHARED_DISKS"); do
  SHARED_VOLS+="$(make_vol "${PREFIX}-node3-ssd${i}" "$SHARED_DISK_GB" "$SHARED_VOLUME_TYPE") "
done
for v in ${SHARED_VOLS} ${LOCAL_VOLS[node1]} ${LOCAL_VOLS[node2]} ${LOCAL_VOLS[node3]}; do
  for _ in $(seq 1 60); do
    st="$(val volume show "$v" -c status)"
    [[ "$st" == available || "$st" == in-use ]] && break
    [[ "$st" == error ]] && die "volume $v went to error state (quota/backend?)"
    sleep 5
  done
done

# ---------------------------------------------------------------------------
log "Cloud-init user-data per node"
# Scripts travel gzip-compressed (cloud-init unpacks "gz+b64"): Nova caps
# user-data at 64 KB and node3's grows with every phase.
gzb64() { gzip -9nc < "$1" | base64 | tr -d '\n'; }
BOOT_B64="$(gzb64 "$HERE/node/cluster-bootstrap.sh")"
VERIFY_B64="$(gzb64 "$HERE/node/verify-cluster.sh")"
REPORT_B64="$(gzb64 "$HERE/node/console-report.sh")"
KEY_B64="$(b64 "$STATE/cluster_ed25519")"
PUB_B64="$(b64 "$STATE/cluster_ed25519.pub")"

# userdata <node> <node.env contents> <outfile> [extra write_files yaml]
userdata() {
  local node="$1" env="$2" out="$3" extra="${4:-}" env_b64 hn="$1" team=""
  env_b64="$(printf '%s\n' "$env" | base64 | tr -d '\n')"
  # team bundle: hostname 3ncryp3d-head/-c1/-c2 and the accounts tarball
  if [[ -f "$STATE/team-${node}.tgz" ]]; then
    hn="${TEAM_HOSTNAMES[${node#node} - 1]}"
    team="  - path: /etc/cluster/team.tgz
    permissions: '0600'
    encoding: b64
    content: $(b64 "$STATE/team-${node}.tgz")"
  fi
  cat > "$out" <<EOF
#cloud-config
hostname: ${hn}
fqdn: ${hn}.cluster
preserve_hostname: false
write_files:
  - path: /etc/cluster/node.env
    permissions: '0644'
    encoding: b64
    content: ${env_b64}
  - path: /etc/cluster/ssh/id_ed25519
    permissions: '0600'
    encoding: b64
    content: ${KEY_B64}
  - path: /etc/cluster/ssh/id_ed25519.pub
    permissions: '0644'
    encoding: b64
    content: ${PUB_B64}
  - path: /usr/local/sbin/cluster-bootstrap.sh
    permissions: '0755'
    encoding: gz+b64
    content: ${BOOT_B64}
${team}
${extra}
runcmd:
  - [ /usr/local/sbin/cluster-bootstrap.sh ]
EOF
}

common_env="MESH_MTU=${MESH_MTU}
SLOTS=${SLOTS}
DNS_SERVERS=\"${DNS_SERVERS}\""

userdata node1 "NODE_NAME=node1
ROLE=compute
${common_env}
DEFAULT_GW=10.0.31.3
NFS_SERVER=10.0.31.3
LINKS=\"$(mac "$P_N1_31")|10.0.31.1/24|node3|10.0.31.3 $(mac "$P_N1_12")|10.0.12.1/24|node2|10.0.12.2\"
HOSTS=\"10.0.31.1|node1 10.0.12.2|node2 10.0.31.3|node3\"
LOCAL_VOLUMES=\"${LOCAL_VOLS[node1]}\"" "$STATE/node1.yaml"

userdata node2 "NODE_NAME=node2
ROLE=compute
${common_env}
DEFAULT_GW=10.0.23.3
NFS_SERVER=10.0.23.3
LINKS=\"$(mac "$P_N2_12")|10.0.12.2/24|node1|10.0.12.1 $(mac "$P_N2_23")|10.0.23.2/24|node3|10.0.23.3\"
HOSTS=\"10.0.12.1|node1 10.0.23.2|node2 10.0.23.3|node3\"
LOCAL_VOLUMES=\"${LOCAL_VOLS[node2]}\"" "$STATE/node2.yaml"

targets_b64="$(printf 'MIN_LINK_GBPS=%s\nMIN_NFS_MBPS=%s\n' "$MIN_LINK_GBPS" "$MIN_NFS_MBPS" | base64 | tr -d '\n')"
userdata node3 "NODE_NAME=node3
ROLE=head
${common_env}
UPLINK_MAC=$(mac "$P_N3_UP")
LINKS=\"$(mac "$P_N3_23")|10.0.23.3/24|node2|10.0.23.2 $(mac "$P_N3_31")|10.0.31.3/24|node1|10.0.31.1\"
HOSTS=\"10.0.31.1|node1 10.0.23.2|node2 10.0.31.3|node3\"
NFS_CLIENTS=\"10.0.31.1 10.0.23.2\"
LOCAL_VOLUMES=\"${LOCAL_VOLS[node3]}\"
SHARED_VOLUMES=\"${SHARED_VOLS}\"
REPORT_VIA=${REPORT_VIA}
BOOTSTRAP_TIMEOUT_MIN=${BOOTSTRAP_TIMEOUT_MIN}" "$STATE/node3.yaml" \
"  - path: /usr/local/bin/verify-cluster.sh
    permissions: '0755'
    encoding: gz+b64
    content: ${VERIFY_B64}
  - path: /usr/local/sbin/console-report.sh
    permissions: '0755'
    encoding: gz+b64
    content: ${REPORT_B64}
  - path: /etc/cluster/targets.env
    permissions: '0644'
    encoding: b64
    content: ${targets_b64}"

# ---------------------------------------------------------------------------
log "Servers (node3 first: it is the gateway the others boot through)"
make_server() {
  local name="$1" flavor="$2" ud="$3"
  shift 3
  local ports=() p
  for p in "$@"; do ports+=(--port "$p"); done
  if ! exists server show "${PREFIX}-${name}"; then
    os server create "${PREFIX}-${name}" --image "$IMAGE" --flavor "$flavor" \
      "${KEY_ARGS[@]}" --config-drive True --user-data "$ud" \
      "${ports[@]}" --wait >/dev/null
  fi
  [[ "$(val server show "${PREFIX}-${name}" -c status)" == ACTIVE ]] \
    || die "server ${PREFIX}-${name} is not ACTIVE"
}
make_server node3 "$FLAVOR_HEAD"    "$STATE/node3.yaml" "$P_N3_UP" "$P_N3_23" "$P_N3_31"
make_server node1 "$FLAVOR_COMPUTE" "$STATE/node1.yaml" "$P_N1_31" "$P_N1_12"
make_server node2 "$FLAVOR_COMPUTE" "$STATE/node2.yaml" "$P_N2_12" "$P_N2_23"

log "Attaching volumes"
attach() {
  local server="${PREFIX}-$1" v
  shift
  for v in "$@"; do
    if [[ "$(val volume show "$v" -c status)" == available ]]; then
      os server add volume "$server" "$v" >/dev/null
    fi
  done
}
# shellcheck disable=SC2086
attach node3 $SHARED_VOLS ${LOCAL_VOLS[node3]}
# shellcheck disable=SC2086
attach node1 ${LOCAL_VOLS[node1]}
# shellcheck disable=SC2086
attach node2 ${LOCAL_VOLS[node2]}

# ---------------------------------------------------------------------------
if (( USE_FIP )); then
  log "Floating IP for node3"
  FIP="$(val floating ip list --port "$P_N3_UP" -c "Floating IP Address" | head -1)"
  if [[ -z "$FIP" ]]; then
    FIP="$(val floating ip create "$EXTERNAL_NETWORK" -c floating_ip_address)"
    os floating ip set --port "$P_N3_UP" "$FIP"
  fi
  NODE3_ADDR="$FIP"
else
  NODE3_ADDR="$(val port show "$P_N3_UP" -c fixed_ips | grep -oE '[0-9]+(\.[0-9]+){3}' | head -1)"
fi

SSHCFG="$STATE/ssh_config"
cat > "$SSHCFG" <<EOF
# ssh -F $SSHCFG node1   (node1/node2 are reached through node3, like at the venue)
Host node3
  HostName ${NODE3_ADDR}
  User ubuntu
  IdentityFile ${SSH_PRIVATE_KEY_FILE}
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${STATE}/known_hosts
Host node1
  HostName 10.0.31.1
  User ubuntu
  ProxyJump node3
  IdentityFile ${SSH_PRIVATE_KEY_FILE}
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${STATE}/known_hosts
Host node2
  HostName 10.0.23.2
  User ubuntu
  ProxyJump node3
  IdentityFile ${SSH_PRIVATE_KEY_FILE}
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ${STATE}/known_hosts
EOF
log "node3 is at ${NODE3_ADDR}; ssh config written to $SSHCFG"

# ---------------------------------------------------------------------------
if [[ "$REPORT_VIA" == console ]]; then
  # node3 waits for node1/node2, runs verify-cluster.sh and prints the result
  # to its serial console between markers (node/console-report.sh). Reading
  # the console log is an API call, so no network path to node3 is needed.
  # node3 waits up to BOOTSTRAP_TIMEOUT_MIN for the others, so allow 15 min
  # more for its own setup.
  log "Waiting for node3's report on its console log (up to $((BOOTSTRAP_TIMEOUT_MIN + 15)) min)"
  deadline=$(( $(date +%s) + (BOOTSTRAP_TIMEOUT_MIN + 15) * 60 ))
  while :; do
    clog="$(openstack console log show "${PREFIX}-node3" 2>/dev/null || true)"
    if grep -q '3N3D-REPORT-END' <<<"$clog"; then break; fi
    if (( $(date +%s) > deadline )); then
      warn "no report from node3 in time. Look at: openstack console log show ${PREFIX}-node3"
      exit 1
    fi
    sleep 30
  done
  printf '%s\n' "$clog" > "$STATE/node3-console.log"
  echo
  # report lines are prefixed "3N3D| " so kernel messages in between are dropped
  sed -n '/3N3D-REPORT-BEGIN/,/3N3D-REPORT-END/p' <<<"$clog" | grep '^3N3D| ' | cut -c7-
  rc="$(grep -o '3N3D-REPORT-END rc=[0-9a-z-]*' <<<"$clog" | tail -1 | cut -d= -f2)"
  log "full console log saved to $STATE/node3-console.log"
  if [[ "$rc" != 0 ]]; then
    warn "node3 reported rc=${rc} (FAILs or a failed bootstrap; see above)"
    exit 1
  fi
  cat <<EOF

Cluster is up and verify-cluster.sh passed (reported through node3's console).
There is no inbound access in console mode: the cluster tests the build, not
interactive work. Tear down: ./destroy_cluster.sh
EOF
  exit 0
fi

log "Waiting for first-boot setup on all nodes (up to ${BOOTSTRAP_TIMEOUT_MIN} min)"
deadline=$(( $(date +%s) + BOOTSTRAP_TIMEOUT_MIN * 60 ))
for n in node3 node1 node2; do
  until ssh -F "$SSHCFG" -o BatchMode=yes -o ConnectTimeout=10 "$n" \
        "test -f /var/lib/cluster-bootstrap.done" 2>/dev/null; do
    if (( $(date +%s) > deadline )); then
      warn "$n did not finish in time. Look at: ssh -F $SSHCFG $n sudo tail -50 /var/log/cluster-bootstrap.log"
      exit 1
    fi
    sleep 20
  done
  log "$n ready"
done

if (( VERIFY )); then
  log "Running verify-cluster.sh on node3"
  ssh -F "$SSHCFG" -o BatchMode=yes node3 "verify-cluster.sh" || {
    warn "verification reported FAILs (see above)"
    exit 1
  }
fi

cat <<EOF

Cluster is up.
  ssh -F $SSHCFG node3        # head node (storage + gateway)
  ssh -F $SSHCFG node1        # via node3, over the 10.0.31.0/24 link
  mpirun --hostfile /mnt/shared/hostfile -np \$((3*${SLOTS})) ./your_app
  backup-results <dir>        # copy finished results SSD -> local array
  verify-cluster.sh           # re-run all checks (on node3)
Tear down: ./destroy_cluster.sh
EOF
