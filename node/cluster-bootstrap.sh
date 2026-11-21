#!/bin/bash
# cluster-bootstrap.sh - first-boot setup for one node of the 3ncryp+3d cluster.
# Delivered by cloud-init to /usr/local/sbin and run once as root.
# Reads its per-node settings from /etc/cluster/node.env (written by
# create_cluster.sh). Safe to re-run: every step checks before it changes.
set -euo pipefail

LOG=/var/log/cluster-bootstrap.log
exec > >(tee -a "$LOG") 2>&1

# shellcheck source=/dev/null
. /etc/cluster/node.env

DONE=/var/lib/cluster-bootstrap.done

# Team accounts bundle (tools/team-bundle.sh): cloud-init delivers it as a
# tarball, baremetal/install.sh unpacks it already. Optional: without it the
# node is set up exactly as before (ubuntu only, node1/2/3 hostnames).
TEAM_DIR=/etc/cluster/team
if [[ -f /etc/cluster/team.tgz && ! -d "$TEAM_DIR" ]]; then
  tar -xzf /etc/cluster/team.tgz -C /etc/cluster
  chmod 700 "$TEAM_DIR"
  rm -f /etc/cluster/team.tgz
fi
if [[ -f "$TEAM_DIR/team.conf" ]]; then
  # shellcheck source=../config/team.conf
  . "$TEAM_DIR/team.conf"
fi
HOST_PREFIX="${HOST_PREFIX:-}"
NODE_ALIASES="${NODE_ALIASES:-}"
# short name for a node (node3 -> head); the node name itself if none
alias_of() {
  local pair
  for pair in $NODE_ALIASES; do
    [[ "${pair%%=*}" == "$1" ]] && { echo "${pair#*=}"; return; }
  done
  echo "$1"
}

CU="${CLUSTER_USER:-ubuntu}"
id "$CU" >/dev/null 2>&1 || { echo "user $CU does not exist"; exit 1; }
MESH_SUBNETS="10.0.12.0/24,10.0.23.0/24,10.0.31.0/24"

log() { echo "[$(date -Is)] $*"; }
die() { log "ERROR: $*"; exit 1; }

if [[ -f "$DONE" ]]; then
  log "already bootstrapped ($DONE exists)"
  exit 0
fi

# Console mode (no floating IP): if node3's own setup fails, say so on the
# serial console, where create_cluster.sh is watching for the report.
console_fail() {
  [[ "${REPORT_VIA:-ssh}" == console && "$ROLE" == head ]] || return 0
  local t
  for t in /dev/ttyS0 /dev/console; do
    [[ -w "$t" ]] || continue
    {
      echo "3N3D-REPORT-BEGIN $(date -Is)"
      echo "3N3D| node3 first-boot setup FAILED (exit $1). Last lines of $LOG:"
      tail -n 30 "$LOG" | sed 's/^/3N3D| /'
      echo "3N3D-REPORT-END rc=bootstrap-failed"
    } >> "$t"
    return 0
  done
}
on_exit() {
  local rc=$?
  (( rc == 0 )) || console_fail "$rc"
}
trap on_exit EXIT

log "bootstrapping ${NODE_NAME} (role=${ROLE})"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
iface_for_mac() {
  local mac="${1,,}" d
  for d in /sys/class/net/*; do
    [[ -f "$d/address" ]] || continue
    if [[ "$(cat "$d/address")" == "$mac" ]]; then
      basename "$d"
      return 0
    fi
  done
  return 1
}

wait_iface() {
  local mac="$1" i
  for i in $(seq 1 60); do
    if iface_for_mac "$mac" >/dev/null; then
      iface_for_mac "$mac"
      return 0
    fi
    sleep 2
  done
  die "no interface with MAC $mac after 120s (i=$i)"
}

# Find a block device by Cinder volume id (virtio serial = first 20 chars).
dev_for_volume() {
  local vol="$1" serial="${1:0:20}" name ser
  if [[ -e "/dev/disk/by-id/virtio-${serial}" ]]; then
    readlink -f "/dev/disk/by-id/virtio-${serial}"
    return 0
  fi
  while read -r name ser; do
    if [[ -n "${ser:-}" && ( "$ser" == "$serial"* || "$ser" == "$vol" ) ]]; then
      echo "/dev/$name"
      return 0
    fi
  done < <(lsblk -dno NAME,SERIAL 2>/dev/null)
  return 1
}

wait_volume() {
  local vol="$1" i
  for i in $(seq 1 120); do
    if dev_for_volume "$vol" >/dev/null; then
      dev_for_volume "$vol"
      return 0
    fi
    sleep 5
  done
  die "volume $vol not attached after 600s (i=$i)"
}

apt_retry() {
  local i
  for i in $(seq 1 60); do
    if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"; then
      return 0
    fi
    log "apt-get $* failed (try $i), retrying in 30s"
    sleep 30
  done
  die "apt-get $* kept failing"
}

# Build an array from 0, 1 or N volumes and mount it.
# $1 = mountpoint, $2 = md name, rest = volume ids
make_array() {
  local mnt="$1" mdname="$2"
  shift 2
  local vols=("$@") devs=() v dev target
  mkdir -p "$mnt"
  if mountpoint -q "$mnt"; then
    log "$mnt already mounted"
    return 0
  fi
  if [[ ${#vols[@]} -eq 0 ]]; then
    log "$mnt: no volumes configured, using root disk"
    return 0
  fi
  for v in "${vols[@]}"; do
    # /dev/... = a real disk or HW RAID virtual drive (bare metal);
    # anything else = a Cinder volume id (OpenStack)
    if [[ "$v" == /dev/* ]]; then
      [[ -b "$v" ]] || die "$v is not a block device"
      dev="$(readlink -f "$v")"
    else
      dev="$(wait_volume "$v")"
    fi
    devs+=("$dev")
    log "$mnt: volume $v is $dev"
  done
  if [[ ${#devs[@]} -eq 1 ]]; then
    target="${devs[0]}"
  else
    target="/dev/md/${mdname}"
    if [[ ! -e "$target" ]]; then
      if ! mdadm --assemble "$target" "${devs[@]}" 2>/dev/null; then
        log "$mnt: creating RAID 0 over ${devs[*]}"
        mdadm --create "$target" --run --level=0 --raid-devices="${#devs[@]}" \
          --name="$mdname" "${devs[@]}"
      fi
    fi
    local md_uuid
    md_uuid="$(mdadm --detail --export "$target" | sed -n 's/^MD_UUID=//p')"
    if ! grep -qF "$md_uuid" /etc/mdadm/mdadm.conf 2>/dev/null; then
      mdadm --detail --brief "$target" >> /etc/mdadm/mdadm.conf
      update-initramfs -u || log "update-initramfs failed (non-fatal)"
    fi
  fi
  if ! blkid "$target" >/dev/null 2>&1; then
    log "$mnt: formatting $target as XFS"
    mkfs.xfs -f -L "$mdname" "$target"
  fi
  local uuid
  uuid="$(blkid -s UUID -o value "$target")"
  if ! grep -q "$uuid" /etc/fstab; then
    echo "UUID=$uuid $mnt xfs defaults,noatime,nofail 0 2" >> /etc/fstab
  fi
  systemctl daemon-reload
  mount "$mnt"
  log "$mnt mounted from $target"
}

# ---------------------------------------------------------------------------
# 1. Network: static mesh addresses, exactly as the cabled design
# ---------------------------------------------------------------------------
NETPLAN=/etc/netplan/60-cluster.yaml
{
  echo "network:"
  echo "  version: 2"
  echo "  ethernets:"
  if [[ "$ROLE" == "head" ]]; then
    up_if="$(wait_iface "$UPLINK_MAC")"
    echo "    ${up_if}:"
    echo "      match: {macaddress: \"${UPLINK_MAC}\"}"
    echo "      dhcp4: true"
  fi
  # LINKS = "mac|addr/prefix|peer-name|peer-ip ..."
  for link in $LINKS; do
    IFS='|' read -r mac addr peer peer_ip <<< "$link"
    ifn="$(wait_iface "$mac")"
    echo "    ${ifn}:   # link to ${peer} (${peer_ip})"
    echo "      match: {macaddress: \"${mac}\"}"
    echo "      dhcp4: false"
    echo "      dhcp6: false"
    echo "      link-local: []"
    echo "      mtu: ${MESH_MTU}"
    echo "      addresses: [\"${addr}\"]"
    if [[ "$ROLE" == "compute" && "$peer_ip" == "$DEFAULT_GW" ]]; then
      echo "      routes: [{to: default, via: \"${DEFAULT_GW}\"}]"
      echo "      nameservers: {addresses: [${DNS_SERVERS// /, }]}"
    fi
  done
} > "${NETPLAN}.new"
chmod 600 "${NETPLAN}.new"
mv "${NETPLAN}.new" "$NETPLAN"

# Our netplan is now the only source of truth; stop cloud-init re-rendering.
rm -f /etc/netplan/50-cloud-init.yaml
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-cluster-network.cfg
fi
netplan generate
netplan apply
log "network applied:"
ip -br addr

# Hosts: each node resolves its peers over the DIRECT cable to that peer.
sed -i '/# BEGIN 3ncryp3d/,/# END 3ncryp3d/d' /etc/hosts
{
  echo "# BEGIN 3ncryp3d"
  for h in $HOSTS; do
    IFS='|' read -r ip name <<< "$h"
    extra=""
    a="$(alias_of "$name")"
    [[ "$a" != "$name" ]] && extra=" $a"
    [[ -n "$HOST_PREFIX" ]] && extra+=" ${HOST_PREFIX}-${a}"
    echo "$ip $name ${name}.cluster${extra}"
  done
  echo "# END 3ncryp3d"
} >> /etc/hosts
# Hostname: 3ncryp3d-head / -c1 / -c2 with a team bundle, else node1/2/3.
if [[ -n "$HOST_PREFIX" ]]; then
  NEW_HOSTNAME="${HOST_PREFIX}-$(alias_of "$NODE_NAME")"
else
  NEW_HOSTNAME="$NODE_NAME"
fi
hostnamectl set-hostname "$NEW_HOSTNAME"
# keep it: cloud-init would otherwise reset the hostname on every boot
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-cluster-hostname.cfg
fi

# ---------------------------------------------------------------------------
# 2. Gateway (node3 only): forwarding + NAT + uplink firewall
# ---------------------------------------------------------------------------
if [[ "$ROLE" == "head" ]]; then
  up_if="$(iface_for_mac "$UPLINK_MAC")"
  cat > /etc/sysctl.d/60-cluster-gateway.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null
  apt_retry update
  apt_retry install -y nftables
  # What the venue uplink accepts (team.conf; defaults = the old behaviour)
  uplink_rules="    iifname \$UPLINK tcp dport 22 accept"
  [[ "${SSH_ON_UPLINK:-yes}" == yes ]] || uplink_rules="    # SSH on the uplink is off (SSH_ON_UPLINK=no): VPN only"
  if [[ "${WG_ENABLE:-no}" == yes ]]; then
    uplink_rules+=$'\n'"    iifname \$UPLINK udp dport ${WG_PORT:-51820} accept"
  fi
  if [[ "${MDNS:-no}" == yes ]]; then
    uplink_rules+=$'\n'"    iifname \$UPLINK udp dport 5353 accept"
  fi
  cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# 3ncryp+3d gateway: only SSH (and the VPN, if enabled) reach node3 from the
# venue uplink. Mesh links are a trusted zone, like the real DAC cables.
# Only OUR tables are reset on reload (no "flush ruleset"), so fail2ban's
# own table and its bans survive.
table inet cluster_filter
delete table inet cluster_filter
table ip cluster_nat
delete table ip cluster_nat
define UPLINK = "${up_if}"
table inet cluster_filter {
  chain input {
    type filter hook input priority 0; policy accept;
    iifname \$UPLINK ct state established,related accept
${uplink_rules}
    iifname \$UPLINK icmp type echo-request accept
    iifname \$UPLINK meta l4proto ipv6-icmp accept
    iifname \$UPLINK udp dport 68 accept
    iifname \$UPLINK drop
    # VPN laptops reach SSH and ping on node3 and nothing else
    iifname "wg0" ct state established,related accept
    iifname "wg0" tcp dport 22 accept
    iifname "wg0" icmp type echo-request accept
    iifname "wg0" drop
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    # node1/node2 must never reach the cloud metadata service through
    # node3's NAT: node3's user-data holds the internal cluster SSH key
    ip daddr 169.254.169.254 drop
    # VPN laptops reach node1/node2 only through SSH on node3 (ProxyJump)
    iifname "wg0" drop
    oifname "wg0" drop
    iifname != \$UPLINK oifname \$UPLINK accept
    iifname \$UPLINK ct state established,related accept
    # mesh <-> mesh: lets node1<->node2 traffic fail over through node3
    iifname != \$UPLINK oifname != \$UPLINK accept
  }
  chain output {
    type filter hook output priority 0; policy accept;
    # user-data holds the internal cluster SSH key: only root may read
    # the metadata service
    ip daddr 169.254.169.254 meta skuid != 0 drop
    ip6 daddr fe80::a9fe:a9fe meta skuid != 0 drop
  }
}
table ip cluster_nat {
  chain postrouting {
    type nat hook postrouting priority 100;
    oifname \$UPLINK masquerade
  }
}
EOF
  nft -f /etc/nftables.conf
  systemctl enable nftables
  log "gateway NAT up on ${up_if}"
fi

# ---------------------------------------------------------------------------
# 3. Packages (compute nodes reach the internet through node3's NAT, so they
#    wait here until node3 is up - same as the real cluster)
# ---------------------------------------------------------------------------
apt_retry update
PKGS=(nfs-common openmpi-bin libopenmpi-dev build-essential gfortran
      iperf3 chrony mdadm xfsprogs fio jq rsync)
if [[ "$ROLE" == "head" ]]; then
  PKGS+=(nfs-kernel-server)
fi
apt_retry install -y "${PKGS[@]}"

# ---------------------------------------------------------------------------
# 4. Storage
# ---------------------------------------------------------------------------
# shellcheck disable=SC2086
make_array /scratch scratch $LOCAL_VOLUMES
mkdir -p /scratch/backup
chmod 1777 /scratch

if [[ "$ROLE" == "head" ]]; then
  # shellcheck disable=SC2086
  make_array /mnt/shared shared $SHARED_VOLUMES
  chown "$CU:$CU" /mnt/shared
  sed -i '/# BEGIN 3ncryp3d/,/# END 3ncryp3d/d' /etc/exports
  {
    echo "# BEGIN 3ncryp3d"
    for c in $NFS_CLIENTS; do
      echo "/mnt/shared ${c}(rw,sync,no_subtree_check)"
    done
    echo "# END 3ncryp3d"
  } >> /etc/exports
  # Serve NFS only on the mesh, never on the uplink (nftables also drops it).
  systemctl enable --now nfs-server
  exportfs -ra
  log "NFS exports:"
  exportfs -v
else
  mkdir -p /mnt/shared
  opts="rsize=1048576,wsize=1048576,async,vers=3,noatime,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=60"
  if ! grep -q " /mnt/shared nfs " /etc/fstab; then
    echo "${NFS_SERVER}:/mnt/shared /mnt/shared nfs ${opts} 0 0" >> /etc/fstab
  fi
  systemctl daemon-reload
  systemctl restart remote-fs.target || true
fi

# Post-run backup helper: SSD (shared) -> local array, as in the design report.
cat > /usr/local/bin/backup-results <<'EOF'
#!/bin/bash
# Copy a finished benchmark's results from the shared SSD array to this
# node's local array. Usage: backup-results <dir under /mnt/shared>
set -euo pipefail
src="/mnt/shared/${1:?usage: backup-results <dir under /mnt/shared>}"
dst="/scratch/backup/$(date +%Y%m%d-%H%M%S)-$(basename "$src")"
rsync -a "$src/" "$dst/"
echo "backed up $src -> $dst"
EOF
chmod 755 /usr/local/bin/backup-results

# ---------------------------------------------------------------------------
# 5. Time sync: node3 is the NTP source for the mesh
# ---------------------------------------------------------------------------
if [[ "$ROLE" == "head" ]]; then
  if ! grep -q "^allow 10.0.0.0/16" /etc/chrony/chrony.conf; then
    printf 'allow 10.0.0.0/16\nlocal stratum 10\n' >> /etc/chrony/chrony.conf
  fi
else
  sed -i 's/^\(pool .*\)$/# \1/' /etc/chrony/chrony.conf
  if ! grep -q "^server ${DEFAULT_GW}" /etc/chrony/chrony.conf; then
    echo "server ${DEFAULT_GW} iburst" >> /etc/chrony/chrony.conf
  fi
fi
systemctl restart chrony

# ---------------------------------------------------------------------------
# 6. Passwordless SSH between nodes (user $CLUSTER_USER, default ubuntu)
# ---------------------------------------------------------------------------
UH="$(getent passwd "$CU" | cut -d: -f6)"
install -d -m 700 -o "$CU" -g "$CU" "$UH/.ssh"
install -m 600 -o "$CU" -g "$CU" /etc/cluster/ssh/id_ed25519 "$UH/.ssh/id_ed25519"
install -m 644 -o "$CU" -g "$CU" /etc/cluster/ssh/id_ed25519.pub "$UH/.ssh/id_ed25519.pub"
touch "$UH/.ssh/authorized_keys"
# With a team bundle, team-setup.sh authorises this key in /etc/ssh/team_keys
# with a from="cables only" limit, so it must not also sit here unlimited.
if [[ ! -f "$TEAM_DIR/team.conf" ]] && \
   ! grep -qF "$(cat /etc/cluster/ssh/id_ed25519.pub)" "$UH/.ssh/authorized_keys"; then
  cat /etc/cluster/ssh/id_ed25519.pub >> "$UH/.ssh/authorized_keys"
fi
cat > "$UH/.ssh/config" <<'EOF'
Host node1 node2 node3
  StrictHostKeyChecking accept-new
  UserKnownHostsFile ~/.ssh/known_hosts
EOF
chown "$CU:$CU" "$UH/.ssh/authorized_keys" "$UH/.ssh/config"
chmod 600 "$UH/.ssh/authorized_keys" "$UH/.ssh/config"

# ---------------------------------------------------------------------------
# 7. OpenMPI: run MPI only over the mesh links, never the uplink
# ---------------------------------------------------------------------------
MCA=/etc/openmpi/openmpi-mca-params.conf
if [[ -f "$MCA" ]] && ! grep -q "3ncryp3d" "$MCA"; then
  cat >> "$MCA" <<EOF
# 3ncryp3d: mesh only
btl = self,vader,tcp
btl_tcp_if_include = ${MESH_SUBNETS}
oob_tcp_if_include = ${MESH_SUBNETS}
EOF
fi

if [[ "$ROLE" == "head" ]]; then
  {
    echo "node1 slots=${SLOTS}"
    echo "node2 slots=${SLOTS}"
    echo "node3 slots=${SLOTS}"
  } > /mnt/shared/hostfile
  chown "$CU:$CU" /mnt/shared/hostfile
fi

# ---------------------------------------------------------------------------
# 8. Team accounts and access (only with a team bundle): users, keys, sshd
#    lock-down, banner; on node3 also WireGuard, fail2ban and mDNS
# ---------------------------------------------------------------------------
if [[ -x "$TEAM_DIR/bin/team-setup.sh" ]]; then
  "$TEAM_DIR/bin/team-setup.sh"
fi

# ---------------------------------------------------------------------------
# 9. Performance mode (config/tuning.conf via the bundle): saves Ubuntu's own
#    values first, then applies PERF_MODE_DEFAULT and re-applies it every boot.
#    Kernel options (mitigations=off) take effect after the next reboot.
# ---------------------------------------------------------------------------
if [[ -x "$TEAM_DIR/bin/perf-mode" && -f "$TEAM_DIR/tuning.conf" ]]; then
  install -m 644 "$TEAM_DIR/tuning.conf" /etc/cluster/tuning.conf
  install -m 755 "$TEAM_DIR/bin/perf-mode" /usr/local/sbin/perf-mode
  /usr/local/sbin/perf-mode install
  mode="$(sed -n 's/^PERF_MODE_DEFAULT=//p' /etc/cluster/tuning.conf)"
  /usr/local/sbin/perf-mode "${mode:-performance}" || log "WARN: perf-mode ${mode:-performance} failed (see above)"
fi

date -Is > "$DONE"
log "bootstrap of ${NODE_NAME} complete"

# Console mode: node3 waits for the others, runs the checks and reports them on
# its console. Run in the background so cloud-init can finish.
if [[ "$ROLE" == "head" && "${REPORT_VIA:-ssh}" == console ]]; then
  if ! systemd-run --unit=cluster-console-report --no-block /usr/local/sbin/console-report.sh; then
    nohup /usr/local/sbin/console-report.sh >/dev/null 2>&1 &
  fi
  log "console report started (waits up to ${BOOTSTRAP_TIMEOUT_MIN:-40} min for node1/node2)"
fi
