#!/bin/bash
# team-setup.sh - team accounts and access for one node of the 3ncryp+3d cluster.
#
# Run as root by cluster-bootstrap.sh when /etc/cluster/team/ exists (made by
# tools/team-bundle.sh). Safe to re-run, e.g. after adding a key or a user:
#   sudo /etc/cluster/team/bin/team-setup.sh
#
#   every node : team group + users (same uid everywhere), sudo, each user's
#                internal key (works only from the cables), laptop keys,
#                pre-made SSH host key + known_hosts, sshd lock-down,
#                login banner and prompt, team-key command
#   head only  : /mnt/shared/runs for the team, WireGuard VPN, fail2ban, mDNS
set -euo pipefail

T=/etc/cluster/team
# shellcheck source=/dev/null
. /etc/cluster/node.env
# shellcheck source=../config/team.conf
. "$T/team.conf"

CU="${CLUSTER_USER:-ubuntu}"
log() { echo "[$(date -Is)] team-setup: $*"; }
die() { log "ERROR: $*"; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

alias_of() {
  local pair
  for pair in $NODE_ALIASES; do
    [[ "${pair%%=*}" == "$1" ]] && { echo "${pair#*=}"; return; }
  done
  echo "$1"
}
ALIAS="$(alias_of "$NODE_NAME")"

# Mesh addresses of each node: fixed by the cabled design (design report Rev. 3).
declare -A NODE_IPS=(
  [node1]="10.0.31.1 10.0.12.1"
  [node2]="10.0.12.2 10.0.23.2"
  [node3]="10.0.23.3 10.0.31.3"
)

# TEAM_USERS -> parallel arrays
U_NAME=() U_UID=() U_SUDO=() U_VPN=()
while read -r u uid sudo vpn; do
  [[ -n "${u:-}" && "$u" != \#* ]] || continue
  U_NAME+=("$u"); U_UID+=("$uid"); U_SUDO+=("$sudo"); U_VPN+=("$vpn")
done <<< "$TEAM_USERS"
(( ${#U_NAME[@]} > 0 )) || die "no users in TEAM_USERS"

# ---------------------------------------------------------------------------
# 1. Group and users: the same numbers on every node, or NFS mixes up owners
# ---------------------------------------------------------------------------
if getent group "$TEAM_GROUP" >/dev/null; then
  [[ "$(getent group "$TEAM_GROUP" | cut -d: -f3)" == "$TEAM_GID" ]] \
    || die "group $TEAM_GROUP exists with a different gid (want $TEAM_GID)"
else
  getent group "$TEAM_GID" >/dev/null && die "gid $TEAM_GID is already used by $(getent group "$TEAM_GID" | cut -d: -f1)"
  groupadd -g "$TEAM_GID" "$TEAM_GROUP"
fi

for i in "${!U_NAME[@]}"; do
  u="${U_NAME[$i]}" uid="${U_UID[$i]}"
  if id "$u" >/dev/null 2>&1; then
    [[ "$(id -u "$u")" == "$uid" ]] || die "user $u exists with uid $(id -u "$u"), team.conf says $uid"
  else
    if getent passwd "$uid" >/dev/null; then
      die "uid $uid (for $u) is already used by $(getent passwd "$uid" | cut -d: -f1)"
    fi
    if ! getent group "$u" >/dev/null; then
      getent group "$uid" >/dev/null && die "gid $uid (for $u) is already used"
      groupadd -g "$uid" "$u"
    fi
    # no password at all: login is by key only (sshd below)
    useradd -m -u "$uid" -g "$u" -G "$TEAM_GROUP" -s /bin/bash -c "3ncryp+3d $u" "$u"
    log "created user $u (uid $uid)"
  fi
  usermod -aG "$TEAM_GROUP" "$u"
done
# the break-glass user is in the team too, so it can read team files
id "$CU" >/dev/null 2>&1 && usermod -aG "$TEAM_GROUP" "$CU"

# ---------------------------------------------------------------------------
# 2. sudo
# ---------------------------------------------------------------------------
SUDOERS=/etc/sudoers.d/90-3ncryp3d
{
  echo "# 3ncryp+3d team admin rights - written by team-setup.sh from team.conf"
  for i in "${!U_NAME[@]}"; do
    [[ "${U_SUDO[$i]}" == yes ]] || continue
    if [[ "$SUDO_NOPASSWD" == yes ]]; then
      echo "${U_NAME[$i]} ALL=(ALL:ALL) NOPASSWD: ALL"
    else
      echo "${U_NAME[$i]} ALL=(ALL:ALL) ALL"
    fi
  done
} > "$SUDOERS.new"
chmod 440 "$SUDOERS.new"
visudo -cqf "$SUDOERS.new" || die "generated sudoers file is invalid"
mv "$SUDOERS.new" "$SUDOERS"
if [[ "$SUDO_NOPASSWD" != yes ]]; then
  log "SUDO_NOPASSWD=no: set each user's password from the console as $CU: sudo passwd <user>"
fi

# ---------------------------------------------------------------------------
# 3. Keys. /etc/ssh/team_keys/<user> is root-owned, so nobody breaks their own
#    access by accident and team-key can manage it in one place.
#    - laptop keys (keys/ssh/<user>.pub): from anywhere sshd accepts
#    - the user's internal key: only from the cables (INTERNAL_KEY_FROM)
# ---------------------------------------------------------------------------
install -d -m 755 /etc/ssh/team_keys
for u in "${U_NAME[@]}" "$CU"; do
  id "$u" >/dev/null 2>&1 || continue
  home="$(getent passwd "$u" | cut -d: -f6)"
  grp="$(id -gn "$u")"
  if [[ "$u" == "$CU" ]]; then
    priv=/etc/cluster/ssh/id_ed25519      # ubuntu keeps the existing cluster key
  else
    priv="$T/users/${u}_ed25519"
  fi
  [[ -f "$priv" && -f "$priv.pub" ]] || { log "WARN: no internal key for $u"; continue; }

  install -d -m 700 -o "$u" -g "$grp" "$home/.ssh"
  install -m 600 -o "$u" -g "$grp" "$priv" "$home/.ssh/id_ed25519"
  install -m 644 -o "$u" -g "$grp" "$priv.pub" "$home/.ssh/id_ed25519.pub"

  {
    echo "# $u - managed by team-setup.sh / team-key. Do not edit by hand."
    echo "from=\"${INTERNAL_KEY_FROM}\" $(cut -d' ' -f1,2 "$priv.pub") 3ncryp3d-internal-${u}"
    if [[ -f "$T/keys/ssh/${u}.pub" ]]; then
      grep -E '^(ssh-|ecdsa-|sk-)' "$T/keys/ssh/${u}.pub" || true
    fi
  } > "/etc/ssh/team_keys/$u.new"
  chmod 644 "/etc/ssh/team_keys/$u.new"
  mv "/etc/ssh/team_keys/$u.new" "/etc/ssh/team_keys/$u"
  [[ -f "$T/keys/ssh/${u}.pub" || "$u" == "$CU" ]] || log "WARN: $u has no laptop key yet"

  # prompt hook (Ubuntu's ~/.bashrc sets PS1 after /etc/profile.d, so hook it there)
  if [[ -f "$home/.bashrc" ]] && ! grep -q '/etc/cluster/prompt.sh' "$home/.bashrc"; then
    printf '\n# 3ncryp+3d prompt\n[ -r /etc/cluster/prompt.sh ] && . /etc/cluster/prompt.sh\n' >> "$home/.bashrc"
  fi
done

# ---------------------------------------------------------------------------
# 4. Host identity: pre-made host key, so laptops (and the nodes themselves)
#    know each node before the first connection and refuse an impostor.
# ---------------------------------------------------------------------------
HOSTKEY_CHANGED=0
if [[ -f "$T/hostkey/ssh_host_ed25519_key" ]]; then
  if ! cmp -s "$T/hostkey/ssh_host_ed25519_key" /etc/ssh/ssh_host_ed25519_key 2>/dev/null; then
    install -m 600 -o root -g root "$T/hostkey/ssh_host_ed25519_key" /etc/ssh/ssh_host_ed25519_key
    install -m 644 -o root -g root "$T/hostkey/ssh_host_ed25519_key.pub" /etc/ssh/ssh_host_ed25519_key.pub
    HOSTKEY_CHANGED=1
  fi
fi

KH=/etc/ssh/ssh_known_hosts
sed -i '/# BEGIN 3ncryp3d/,/# END 3ncryp3d/d' "$KH" 2>/dev/null || true
{
  echo "# BEGIN 3ncryp3d"
  for n in node1 node2 node3; do
    [[ -f "$T/hostkeys/$n.pub" ]] || continue
    a="$(alias_of "$n")"
    names="$n,$a,${HOST_PREFIX}-$a,$n.cluster"
    for ip in ${NODE_IPS[$n]}; do names+=",$ip"; done
    echo "$names $(cut -d' ' -f1,2 "$T/hostkeys/$n.pub")"
  done
  echo "# END 3ncryp3d"
} >> "$KH"
chmod 644 "$KH"

aliases=""
for pair in $NODE_ALIASES; do aliases+=" ${pair#*=} ${HOST_PREFIX}-${pair#*=}"; done
cat > /etc/ssh/ssh_config.d/10-3ncryp3d.conf <<EOF
# 3ncryp+3d - node to node. Host keys are pre-shared in $KH.
Host node1 node2 node3${aliases} *.cluster 10.0.*
    StrictHostKeyChecking yes
    ForwardAgent no
    IdentityFile ~/.ssh/id_ed25519
EOF

# ---------------------------------------------------------------------------
# 5. sshd: keys only, no root, only the team and the break-glass user.
#    The break-glass user ($CU) keeps its password for the iLO console.
# ---------------------------------------------------------------------------
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-3ncryp3d.conf
cat > "$SSHD_DROPIN.new" <<EOF
# 3ncryp+3d - written by team-setup.sh. First match wins in sshd, hence "10-".
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/team_keys/%u
AllowUsers ${CU} ${U_NAME[*]}
MaxAuthTries 4
X11Forwarding no
AllowAgentForwarding no
# ProxyJump through the head needs TCP forwarding
AllowTcpForwarding yes
EOF
mv "$SSHD_DROPIN.new" "$SSHD_DROPIN"
if command -v sshd >/dev/null; then
  mkdir -p /run/sshd
  if ! sshd -t; then
    rm -f "$SSHD_DROPIN"
    die "sshd rejected the new settings; removed them so SSH keeps working"
  fi
  if (( HOSTKEY_CHANGED )); then
    systemctl try-restart ssh.service 2>/dev/null || true
  else
    systemctl try-reload-or-restart ssh.service 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# 6. Login banner and prompt
# ---------------------------------------------------------------------------
cat > /etc/cluster/prompt.sh <<EOF
# shellcheck shell=bash
# 3ncryp+3d prompt: user@cluster:node:dir
case \$- in *i*)
  PS1='\[\e[1;36m\]\u@${CLUSTER_NAME}\[\e[0m\]:\[\e[1;33m\]${ALIAS}\[\e[0m\]:\w\\\$ '
esac
EOF
chmod 644 /etc/cluster/prompt.sh

cat > /etc/update-motd.d/05-3ncryp3d <<EOF
#!/bin/sh
# 3ncryp+3d login banner - written by team-setup.sh
cat <<'BANNER'
 _____                                  _____     _
|___ / _ __   ___ _ __ _   _ _ __    _ |___ /  __| |
  |_ \\| '_ \\ / __| '__| | | | '_ \\ _| |_ |_ \\ / _\` |
 ___) | | | | (__| |  | |_| | |_) |_   _|__) | (_| |
|____/|_| |_|\\___|_|   \\__, | .__/  |_||____/ \\__,_|
                       |___/|_|
BANNER
echo "  ${CLUSTER_NAME}  ::  ${ALIAS} (\$(hostname))  ::  role ${ROLE}"
S=/mnt/shared/status/summary.txt
if [ -r "\$S" ]; then sed 's/^/  /' "\$S"; else echo "  status: not checked yet"; fi
echo
EOF
chmod 755 /etc/update-motd.d/05-3ncryp3d
for f in 10-help-text 50-motd-news 91-contract-ua-esm-status; do
  [[ -f "/etc/update-motd.d/$f" ]] && chmod -x "/etc/update-motd.d/$f"
done

install -m 755 "$T/bin/team-key" /usr/local/sbin/team-key

# ---------------------------------------------------------------------------
# 7. Head node only
# ---------------------------------------------------------------------------
if [[ "$ROLE" == head ]]; then
  # shared run folder: everyone in the team can read, rerun and submit
  if mountpoint -q /mnt/shared; then
    install -d -m 2775 -o "$CU" -g "$TEAM_GROUP" /mnt/shared/runs /mnt/shared/status
  fi

  up_if=""
  if [[ -n "${UPLINK_MAC:-}" ]]; then
    for d in /sys/class/net/*; do
      [[ "$(cat "$d/address" 2>/dev/null)" == "${UPLINK_MAC,,}" ]] && up_if="$(basename "$d")"
    done
  fi

  pkgs=()
  [[ "${WG_ENABLE:-no}" == yes ]] && pkgs+=(wireguard-tools)
  [[ "${FAIL2BAN:-no}" == yes ]] && pkgs+=(fail2ban)
  [[ "${MDNS:-no}" == yes && -n "$up_if" ]] && pkgs+=(avahi-daemon)
  if (( ${#pkgs[@]} > 0 )); then
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y "${pkgs[@]}" \
      || log "WARN: could not install ${pkgs[*]}"
  fi

  # WireGuard: laptops <-> head only. Cluster traffic never uses it.
  if [[ "${WG_ENABLE:-no}" == yes && -f "$T/wg/head.key" ]] && command -v wg >/dev/null; then
    WGC=/etc/wireguard/wg0.conf
    umask 077
    {
      echo "# 3ncryp+3d VPN - written by team-setup.sh. One [Peer] per laptop."
      echo "[Interface]"
      echo "Address = ${WG_HEAD_ADDR}"
      echo "ListenPort = ${WG_PORT}"
      echo "PrivateKey = $(cat "$T/wg/head.key")"
      for i in "${!U_NAME[@]}"; do
        f="$T/keys/wg/${U_NAME[$i]}.pub"
        [[ -f "$f" ]] || continue
        echo
        echo "# user: ${U_NAME[$i]}"
        echo "[Peer]"
        echo "PublicKey = $(tr -d ' \r\n' < "$f")"
        echo "AllowedIPs = ${U_VPN[$i]}/32"
      done
    } > "$WGC.new"
    umask 022
    mv "$WGC.new" "$WGC"
    systemctl enable wg-quick@wg0 >/dev/null 2>&1 || true
    if systemctl is-active -q wg-quick@wg0; then
      wg syncconf wg0 <(wg-quick strip wg0) || systemctl restart wg-quick@wg0 || true
    else
      systemctl start wg-quick@wg0 || true
    fi
    if systemctl is-active -q wg-quick@wg0; then
      log "WireGuard up on ${WG_HEAD_ADDR}, port ${WG_PORT}"
    else
      log "WARN: WireGuard did not start (journalctl -u wg-quick@wg0)"
    fi
  fi

  # fail2ban: ban an address after repeated failed SSH logins
  if [[ "${FAIL2BAN:-no}" == yes ]] && command -v fail2ban-client >/dev/null; then
    ignore="127.0.0.1/8 ::1 10.0.0.0/16"
    if [[ "${WG_ENABLE:-no}" == yes ]]; then
      ignore+=" $(python3 -c "import ipaddress,sys;print(ipaddress.ip_interface(sys.argv[1]).network)" "$WG_HEAD_ADDR")"
    fi
    cat > /etc/fail2ban/jail.d/3ncryp3d.conf <<EOF
# 3ncryp+3d - written by team-setup.sh
[DEFAULT]
banaction = nftables-multiport
banaction_allports = nftables-allports
backend = systemd
ignoreip = ${ignore}

[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban || log "WARN: fail2ban did not start (journalctl -u fail2ban)"
  fi

  # mDNS: answer "<hostname>.local" on the venue uplink only. No services listed.
  if [[ "${MDNS:-no}" == yes && -n "$up_if" && -d /etc/avahi ]]; then
    cat > /etc/avahi/avahi-daemon.conf <<EOF
# 3ncryp+3d - written by team-setup.sh: publish the head's name on the uplink only
[server]
use-ipv4=yes
use-ipv6=no
allow-interfaces=${up_if}
[wide-area]
enable-wide-area=no
[publish]
publish-addresses=yes
publish-hinfo=no
publish-workstation=no
publish-domain=yes
[reflector]
[rlimits]
EOF
    rm -f /etc/avahi/services/*.service
    systemctl restart avahi-daemon || log "WARN: avahi-daemon did not start"
  fi
fi

log "done on ${NODE_NAME} (${HOST_PREFIX}-${ALIAS}): users ${U_NAME[*]}"
