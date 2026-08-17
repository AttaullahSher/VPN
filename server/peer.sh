#!/usr/bin/env bash
# =============================================================================
# peer.sh - add / list / show / revoke WireGuard peers.
#
#   sudo bash peer.sh add     <name>     create a peer, print nothing secret
#   sudo bash peer.sh list                show peers, IPs and last handshake
#   sudo bash peer.sh qr      <name>      print a scannable QR in the terminal
#   sudo bash peer.sh png     <name>      write a QR image to /etc/wireguard/peers/<name>/
#   sudo bash peer.sh conf    <name>      print the client config (CONTAINS A PRIVATE KEY)
#   sudo bash peer.sh revoke  <name>      remove a peer, immediately, live
#
# Adding and revoking use live "wg set" calls that touch only the named peer.
# Other peers keep their sessions - no handshake is dropped, no reconnect.
# =============================================================================
set -euo pipefail

STATE_DIR=/var/lib/wg-oracle
[ -r "$STATE_DIR/env" ] || { echo "!! run setup.sh first (missing $STATE_DIR/env)" >&2; exit 1; }
# shellcheck disable=SC1091
. "$STATE_DIR/env"

PEER_DIR="$WG_DIR/peers"
CONF="$WG_DIR/$WG_IF.conf"

info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# Base prefix of the tunnel, e.g. 10.66.66
V4_PREFIX="${WG_ADDR4%.*}"
V6_PREFIX="${WG_ADDR6%:*}"     # e.g. fd42:66:66:

valid_name() {
  [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,30}$ ]] \
    || die "invalid name '$1' (use letters, digits, '-' and '_', max 31 chars)"
}

# Lowest host address in the tunnel not already claimed in the server config.
next_ip() {
  local used n
  used="$(grep -oE "${V4_PREFIX//./\\.}\.[0-9]+" "$CONF" 2>/dev/null | awk -F. '{print $4}' | sort -n -u)"
  for n in $(seq 2 254); do
    grep -qx "$n" <<<"$used" || { echo "$n"; return 0; }
  done
  die "no free addresses left in $WG_NET4"
}

peer_exists() { grep -q "^# BEGIN PEER $1\$" "$CONF" 2>/dev/null; }

cmd_add() {
  need_root
  local name="${1:?usage: peer.sh add <name>}"
  valid_name "$name"
  peer_exists "$name" && die "peer '$name' already exists (revoke it first, or pick another name)"

  local d="$PEER_DIR/$name"
  umask 077
  mkdir -p "$d"

  # Three secrets per peer:
  #   private key  - identifies the peer, never leaves the device (or this dir)
  #   preshared key- symmetric extra layer; makes the tunnel resistant to a
  #                  future quantum attacker who recorded today's traffic
  wg genkey > "$d/private.key"
  wg pubkey < "$d/private.key" > "$d/public.key"
  wg genpsk > "$d/preshared.key"
  chmod 600 "$d"/*.key

  local n ip4 ip6 pub
  n="$(next_ip)"
  ip4="${V4_PREFIX}.${n}"
  ip6="${V6_PREFIX}:${n}"
  pub="$(cat "$d/public.key")"
  printf '%s\n' "$ip4" > "$d/address4"
  printf '%s\n' "$ip6" > "$d/address6"

  # --- persist the peer in the server config (so it survives reboot) ---
  cat >> "$CONF" <<EOF

# BEGIN PEER $name
[Peer]
# $name  ($ip4)
PublicKey    = $pub
PresharedKey = $(cat "$d/preshared.key")
AllowedIPs   = ${ip4}/32, ${ip6}/128
# END PEER $name
EOF
  chmod 600 "$CONF"

  # --- apply it to the running interface, without touching any other peer ---
  if ip link show "$WG_IF" >/dev/null 2>&1; then
    wg set "$WG_IF" peer "$pub" \
      preshared-key "$d/preshared.key" \
      allowed-ips "${ip4}/32,${ip6}/128"
  fi

  # --- write the client config ---
  # AllowedIPs 0.0.0.0/0, ::/0 = full tunnel: every packet the device sends goes
  # through the VPN. ::/0 is included even though the server has no IPv6 uplink,
  # precisely so the phone cannot quietly route IPv6 traffic around the tunnel.
  cat > "$d/$name.conf" <<EOF
[Interface]
PrivateKey = $(cat "$d/private.key")
Address    = ${ip4}/32, ${ip6}/128
DNS        = ${WG_ADDR4}, ${WG_ADDR6}
MTU        = ${WG_MTU}

[Peer]
PublicKey           = ${SERVER_PUB}
PresharedKey        = $(cat "$d/preshared.key")
Endpoint            = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs          = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  chmod 600 "$d/$name.conf"

  info "created peer '$name'  ->  $ip4  |  $ip6"
  info "config: $d/$name.conf   (mode 600, contains this peer's private key)"
  info "show the QR with:  sudo bash peer.sh qr $name"
}

cmd_list() {
  printf '\n%-16s %-14s %-24s %s\n' "NAME" "TUNNEL IP" "LAST HANDSHAKE" "TRANSFER"
  printf '%s\n' "--------------------------------------------------------------------------------"
  local name ip pub hs rx tx
  while read -r name; do
    [ -n "$name" ] || continue
    pub="$(cat "$PEER_DIR/$name/public.key" 2>/dev/null || echo '?')"
    ip="$(cat "$PEER_DIR/$name/address4" 2>/dev/null || echo '?')"
    hs='never'; rx='-'; tx='-'
    if ip link show "$WG_IF" >/dev/null 2>&1; then
      local line
      line="$(wg show "$WG_IF" dump 2>/dev/null | awk -v p="$pub" '$1==p {print $5, $6, $7}')"
      if [ -n "$line" ]; then
        local ts
        ts="$(awk '{print $1}' <<<"$line")"
        rx="$(numfmt --to=iec --suffix=B "$(awk '{print $2}' <<<"$line")" 2>/dev/null || echo '-')"
        tx="$(numfmt --to=iec --suffix=B "$(awk '{print $3}' <<<"$line")" 2>/dev/null || echo '-')"
        [ "$ts" != "0" ] && hs="$(date -d "@$ts" '+%Y-%m-%d %H:%M:%S')"
      fi
    fi
    printf '%-16s %-14s %-24s %s\n' "$name" "$ip" "$hs" "down $rx / up $tx"
  done < <(grep -oP '^# BEGIN PEER \K.*' "$CONF" 2>/dev/null || true)
  echo
}

cmd_qr() {
  local name="${1:?usage: peer.sh qr <name>}"
  local f="$PEER_DIR/$name/$name.conf"
  [ -r "$f" ] || die "no config for peer '$name'"
  echo
  echo "  Scan with the WireGuard iOS app:  + -> Create from QR code"
  echo "  This QR encodes a private key. Do not photograph, forward or post it."
  echo
  qrencode -t ansiutf8 < "$f"
  echo "  Peer: $name"
  echo
}

cmd_png() {
  local name="${1:?usage: peer.sh png <name>}"
  local f="$PEER_DIR/$name/$name.conf"
  [ -r "$f" ] || die "no config for peer '$name'"
  qrencode -o "$PEER_DIR/$name/$name.png" -s 8 -m 3 < "$f"
  chmod 600 "$PEER_DIR/$name/$name.png"
  info "wrote $PEER_DIR/$name/$name.png"
}

cmd_conf() {
  local name="${1:?usage: peer.sh conf <name>}"
  local f="$PEER_DIR/$name/$name.conf"
  [ -r "$f" ] || die "no config for peer '$name'"
  cat "$f"
}

cmd_revoke() {
  need_root
  local name="${1:?usage: peer.sh revoke <name>}"
  peer_exists "$name" || die "no such peer: '$name'"
  local pub
  pub="$(cat "$PEER_DIR/$name/public.key" 2>/dev/null || true)"

  # 1. Kick the peer off the live interface. Takes effect instantly; every other
  #    peer's session is untouched.
  if [ -n "$pub" ] && ip link show "$WG_IF" >/dev/null 2>&1; then
    wg set "$WG_IF" peer "$pub" remove
  fi

  # 2. Delete only this peer's block from the persisted config.
  sed -i "/^# BEGIN PEER ${name}\$/,/^# END PEER ${name}\$/d" "$CONF"
  sed -i '/^$/{N;/^\n$/D}' "$CONF"   # collapse the blank line left behind

  # 3. Archive the key material out of the active directory.
  if [ -d "$PEER_DIR/$name" ]; then
    mkdir -p "$PEER_DIR/.revoked"
    mv "$PEER_DIR/$name" "$PEER_DIR/.revoked/${name}.$(date +%Y%m%d%H%M%S)"
    chmod 700 "$PEER_DIR/.revoked"
  fi

  info "revoked '$name' - its key is dead immediately, all other peers unaffected"
  info "archived under $PEER_DIR/.revoked/ (delete it to destroy the key for good)"
}

case "${1:-}" in
  add)    shift; cmd_add    "$@" ;;
  list|ls) shift 2>/dev/null || true; cmd_list ;;
  qr)     shift; cmd_qr     "$@" ;;
  png)    shift; cmd_png    "$@" ;;
  conf)   shift; cmd_conf   "$@" ;;
  revoke|rm) shift; cmd_revoke "$@" ;;
  *) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
