#!/bin/bash
# make-team-secrets.sh - create the cluster's own keys for the team accounts.
#
#   tools/make-team-secrets.sh [OUTDIR]        (default: state/team)
#
# Reads  config/team.conf, keys/ssh/<user>.pub, keys/wg/<user>.pub
# Writes OUTDIR/  (git-ignored: PRIVATE keys, keep it off the repo)
#          cluster_ed25519{,.pub}            ubuntu's internal key (install.sh)
#          users/<user>_ed25519{,.pub}       each user's internal node-to-node key
#          hostkeys/<node>/ssh_host_ed25519_key{,.pub}   each node's SSH identity
#          wg/head.key, wg/head.pub          head node's WireGuard key
#        keys/cluster-public.env  (PUBLIC: commit it, the laptop script reads it)
#
# Keys that already exist are kept. Deleting OUTDIR and re-running makes new
# ones, after which every laptop must re-run setup-laptop.ps1 -Configure.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$HERE/state/team}"
CONF="$HERE/config/team.conf"
KEYS="$HERE/keys"
PUBLIC="$KEYS/cluster-public.env"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "'$1' not found ($2)"; }

[[ -r "$CONF" ]] || die "$CONF not found"
# shellcheck source=../config/team.conf
. "$CONF"
need ssh-keygen "apt install openssh-client / Git for Windows includes it"
if [[ "${WG_ENABLE:-no}" == yes ]] && ! command -v wg >/dev/null; then
  if [[ -f "$OUT/wg/head.key" ]]; then
    :   # already made earlier; nothing to generate
  else
    echo "WARN: 'wg' not found (apt install wireguard-tools): no VPN key made, so this build has no VPN" >&2
    WG_ENABLE=no
  fi
fi

umask 077
mkdir -p "$OUT/users" "$OUT/hostkeys" "$OUT/wg"

# A file someone sent as their "public key" must really be one.
check_ssh_pub() {
  local f="$1"
  if grep -q "PRIVATE KEY" "$f"; then
    die "$f is a PRIVATE key. Delete it, tell its owner the key is exposed, and have them make a new pair."
  fi
  ssh-keygen -lf "$f" >/dev/null 2>&1 || die "$f is not a valid SSH public key"
}
check_wg_pub() {
  local f="$1" k
  k="$(tr -d ' \r\n' < "$f")"
  [[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]] || die "$f is not a WireGuard public key (44 base64 characters)"
}

newkey() { # newkey <file> <comment>
  [[ -f "$1" ]] || ssh-keygen -q -t ed25519 -N "" -C "$2" -f "$1"
}

newkey "$OUT/cluster_ed25519" "3ncryp3d-internal-ubuntu"

users=()
while read -r user uid sudo vpn; do
  [[ -n "${user:-}" && "$user" != \#* ]] || continue
  [[ "$uid" =~ ^[0-9]+$ ]] || die "team.conf: bad uid '$uid' for $user"
  [[ "$sudo" == yes || "$sudo" == no ]] || die "team.conf: sudo must be yes/no for $user"
  [[ "$vpn" =~ ^[0-9.]+$ ]] || die "team.conf: bad vpn address '$vpn' for $user"
  users+=("$user")
  newkey "$OUT/users/${user}_ed25519" "3ncryp3d-internal-${user}"
  if [[ -f "$KEYS/ssh/${user}.pub" ]]; then
    check_ssh_pub "$KEYS/ssh/${user}.pub"
  else
    echo "WARN: no laptop key keys/ssh/${user}.pub: ${user} gets an account but can't log in from a laptop yet" >&2
  fi
  if [[ "${WG_ENABLE:-no}" == yes ]]; then
    if [[ -f "$KEYS/wg/${user}.pub" ]]; then
      check_wg_pub "$KEYS/wg/${user}.pub"
    else
      echo "WARN: no VPN key keys/wg/${user}.pub: ${user} can't use the VPN yet" >&2
    fi
  fi
done <<< "$TEAM_USERS"
(( ${#users[@]} > 0 )) || die "TEAM_USERS in team.conf is empty"

for n in node1 node2 node3; do
  mkdir -p "$OUT/hostkeys/$n"
  newkey "$OUT/hostkeys/$n/ssh_host_ed25519_key" "root@${HOST_PREFIX}-${n}"
done

if [[ "${WG_ENABLE:-no}" == yes && ! -f "$OUT/wg/head.key" ]]; then
  wg genkey > "$OUT/wg/head.key"
  wg pubkey < "$OUT/wg/head.key" > "$OUT/wg/head.pub"
fi

# short alias for a node name (node3 -> head) from NODE_ALIASES
alias_of() {
  local pair
  for pair in $NODE_ALIASES; do
    [[ "${pair%%=*}" == "$1" ]] && { echo "${pair#*=}"; return; }
  done
  echo "$1"
}

# Public summary for the laptops: no private material.
umask 022
mkdir -p "$KEYS"
{
  echo "# keys/cluster-public.env - written by tools/make-team-secrets.sh."
  echo "# PUBLIC data for laptop/setup-laptop.ps1: the cluster's identity keys and"
  echo "# VPN settings. Safe to commit and share. Regenerated keys = re-run the"
  echo "# laptop script with -Configure."
  echo "CLUSTER_NAME=\"${CLUSTER_NAME}\""
  echo "HOST_PREFIX=\"${HOST_PREFIX}\""
  for n in node1 node2 node3; do
    a="$(alias_of "$n")"
    echo "HOSTKEY_${a}=\"$(cut -d' ' -f1,2 "$OUT/hostkeys/$n/ssh_host_ed25519_key.pub")\""
  done
  echo "WG_ENABLE=\"${WG_ENABLE:-no}\""
  if [[ "${WG_ENABLE:-no}" == yes ]]; then
    echo "WG_PORT=\"${WG_PORT}\""
    echo "WG_HEAD_ADDR=\"${WG_HEAD_ADDR}\""
    echo "WG_HEAD_PUBKEY=\"$(cat "$OUT/wg/head.pub")\""
  fi
  echo "SSH_ON_UPLINK=\"${SSH_ON_UPLINK:-yes}\""
  echo "MDNS=\"${MDNS:-no}\""
  printf 'TEAM_USERS="%s"\n' "$TEAM_USERS"
} > "$PUBLIC"

echo "Secrets in $OUT (keep private). Public summary: $PUBLIC (commit it)."
echo "Users: ${users[*]}"
