#!/usr/bin/env bash
# =============================================================================
# verify.sh - Phase 4: prove the tunnel is actually working and actually sealed.
# Read-only: it changes nothing. Run as root for the firewall checks.
#   sudo bash verify.sh
# =============================================================================
set -uo pipefail

STATE_DIR=/var/lib/wg-oracle
[ -r "$STATE_DIR/env" ] || { echo "!! run setup.sh first" >&2; exit 1; }
# shellcheck disable=SC1091
. "$STATE_DIR/env"

PASS=0; FAIL=0; WARN=0
ok()   { printf '  \033[1;32m[ OK ]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
sec()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

sec "1. WireGuard interface"
if ip link show "$WG_IF" >/dev/null 2>&1; then
  ok "$WG_IF exists"
  MTU_NOW="$(cat "/sys/class/net/$WG_IF/mtu")"
  [ "$MTU_NOW" = "$WG_MTU" ] && ok "MTU is $MTU_NOW" || warn "MTU is $MTU_NOW, expected $WG_MTU"
  LPORT="$(wg show "$WG_IF" listen-port 2>/dev/null)"
  [ "$LPORT" = "$WG_PORT" ] && ok "listening on UDP $LPORT" || bad "listening on $LPORT, expected $WG_PORT"
else
  bad "$WG_IF is DOWN"
fi
if systemctl is-enabled --quiet "wg-quick@$WG_IF" 2>/dev/null; then
  ok "wg-quick@$WG_IF is enabled at boot"
else
  bad "wg-quick@$WG_IF is NOT enabled - the VPN will not come back after a reboot"
fi

sec "2. Peers and handshakes"
PEERCOUNT=0; HANDSHAKEN=0
while read -r pub _ _ _ hs rx tx _; do
  [ -n "$pub" ] || continue
  PEERCOUNT=$((PEERCOUNT+1))
  name="$(grep -rl "^${pub}$" "$WG_DIR"/peers/*/public.key 2>/dev/null | head -1 | awk -F/ '{print $(NF-1)}')"
  name="${name:-unknown}"
  if [ "${hs:-0}" != "0" ]; then
    HANDSHAKEN=$((HANDSHAKEN+1))
    age=$(( $(date +%s) - hs ))
    printf '  \033[1;32m[ OK ]\033[0m %-14s handshake %ss ago, down %s / up %s\n' \
      "$name" "$age" \
      "$(numfmt --to=iec --suffix=B "${rx:-0}" 2>/dev/null)" \
      "$(numfmt --to=iec --suffix=B "${tx:-0}" 2>/dev/null)"
    PASS=$((PASS+1))
  else
    warn "$name has never completed a handshake (device not connected yet)"
  fi
done < <(wg show "$WG_IF" dump 2>/dev/null | tail -n +2)
[ "$PEERCOUNT" -gt 0 ] && ok "$PEERCOUNT peer(s) configured, $HANDSHAKEN connected" \
                       || bad "no peers configured"

sec "3. Kernel forwarding (must survive reboot)"
for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding; do
  v="$(sysctl -n "$k" 2>/dev/null)"
  [ "$v" = "1" ] && ok "$k = 1 (live)" || bad "$k = $v"
done
if grep -qs 'net.ipv4.ip_forward *= *1' /etc/sysctl.d/99-wireguard.conf; then
  ok "forwarding persisted in /etc/sysctl.d/99-wireguard.conf"
else
  bad "forwarding is NOT persisted - it will reset on reboot"
fi
ok "congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"

sec "4. Firewall (the part Oracle's image gets wrong)"
chk4() { iptables  -C "$@" 2>/dev/null && ok "iptables  $*"  || bad "MISSING: iptables $*"; }
if iptables -S INPUT 2>/dev/null | grep -qE 'REJECT|DROP'; then
  ok "Oracle's default deny rule is present (as expected) - our ACCEPTs must precede it"
fi
chk4 INPUT -p udp --dport "$WG_PORT" -j ACCEPT
chk4 INPUT -i "$WG_IF" -j ACCEPT
chk4 FORWARD -i "$WG_IF" -j ACCEPT
chk4 FORWARD -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t nat -C POSTROUTING -s "$WG_NET4" -o "$WAN_IF" -j MASQUERADE 2>/dev/null \
  && ok "NAT masquerade $WG_NET4 out $WAN_IF" || bad "MISSING NAT masquerade"
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  && ok "TCP MSS clamped to path MTU" || warn "MSS clamping missing - expect stalled page loads on some networks"

# Ordering matters more than presence: an ACCEPT after the REJECT is dead code.
if [ -n "${WG_PORT:-}" ]; then
  acc="$(iptables -L INPUT --line-numbers -n 2>/dev/null | awk -v p="dpt:$WG_PORT" '$0 ~ p {print $1; exit}')"
  rej="$(iptables -L INPUT --line-numbers -n 2>/dev/null | awk '/REJECT|DROP/ {print $1; exit}')"
  if [ -n "$acc" ] && [ -n "$rej" ]; then
    [ "$acc" -lt "$rej" ] && ok "WireGuard ACCEPT (rule $acc) comes before the REJECT (rule $rej)" \
                          || bad "WireGuard ACCEPT is AFTER the REJECT - it never matches"
  fi
fi

if grep -qs -- "--dport $WG_PORT" /etc/iptables/rules.v4; then
  ok "rules persisted in /etc/iptables/rules.v4 (survive reboot)"
else
  bad "rules NOT in /etc/iptables/rules.v4 - they will vanish on reboot"
fi

sec "5. DNS"
if systemctl is-active --quiet unbound; then
  ok "unbound is running"
else
  bad "unbound is not running"
fi
if command -v dig >/dev/null 2>&1; then Q="dig +short +time=3 +tries=1"; else Q=""; fi
if [ -n "$Q" ]; then
  r="$($Q @"$WG_ADDR4" cloudflare.com A 2>/dev/null | head -1)"
  [ -n "$r" ] && ok "resolver answers on the tunnel address $WG_ADDR4 (-> $r)" \
              || bad "no answer from $WG_ADDR4"
  r2="$($Q @"$PUBLIC_IP" cloudflare.com A 2>/dev/null | head -1)"
  [ -z "$r2" ] && ok "resolver REFUSES queries from the public internet (not an open resolver)" \
               || bad "resolver answers on the public IP - it is an open resolver, fix access-control"
else
  warn "dig not installed - skipping resolver probes (apt-get install -y dnsutils)"
fi
grep -qs 'forward-tls-upstream: yes' /etc/unbound/unbound.conf.d/wg.conf \
  && ok "upstream queries use DNS-over-TLS (Oracle's network cannot read them)" \
  || warn "DNS-over-TLS not enabled upstream"

sec "6. Path MTU probe"
# Largest un-fragmented payload that survives to the internet. Add 28 bytes
# (IP+ICMP headers) to get the real path MTU.
best=0
for s in 1500 1472 1440 1412 1392 1372 1352; do
  if ping -c1 -W2 -M do -s "$s" 1.1.1.1 >/dev/null 2>&1; then best=$s; break; fi
done
if [ "$best" -gt 0 ]; then
  ok "server->internet path MTU is $((best+28)); tunnel MTU $WG_MTU leaves $(( best+28-WG_MTU-60 )) bytes of headroom"
else
  warn "ICMP probes blocked - cannot measure path MTU (MSS clamping covers TCP anyway)"
fi

sec "7. Throughput (server -> internet)"
echo "     downloading 100 MB from Cloudflare, please wait..."
spd="$(curl -s -o /dev/null -m 60 -w '%{speed_download}' https://speed.cloudflare.com/__down?bytes=100000000 2>/dev/null)"
if [ -n "$spd" ] && [ "${spd%%.*}" -gt 0 ] 2>/dev/null; then
  ok "server downlink: $(awk -v s="$spd" 'BEGIN{printf "%.1f Mbit/s", s*8/1000000}')"
  echo "     (an Always Free A1 gets ~1 Gbit/s per OCPU; this shape has $(nproc) -> ~$(nproc) Gbit/s ceiling)"
else
  warn "throughput test failed"
fi

sec "8. Idle-reclaim protection"
if systemctl is-active --quiet wg-ballast 2>/dev/null; then
  used=$(free -m | awk '/^Mem:/ {printf "%d", $3*100/$2}')
  [ "$used" -ge 20 ] && ok "memory ballast active - memory utilisation ${used}% (Oracle's idle threshold is 20%)" \
                     || bad "ballast running but memory only ${used}% - raise BALLAST_PCT"
else
  warn "no memory ballast - Oracle may reclaim this instance after 7 idle days"
fi
systemctl is-active --quiet wg-cpukeep 2>/dev/null && ok "CPU keeper active" \
  || echo "     CPU keeper off (not needed while the memory ballast is running)"

sec "9. Egress against the 10 TB/month free cap"
bash "$(dirname "$0")/egress.sh" 2>/dev/null || warn "run egress.sh separately"

printf '\n\033[1m Result: %d passed, %d warnings, %d failed\033[0m\n\n' "$PASS" "$WARN" "$FAIL"
echo " Client-side checks (do these on the iPhone, with the VPN connected):"
echo "   1. https://dnsleaktest.com  -> Extended test. Every server listed must be"
echo "      Cloudflare or Quad9, and your ISP (Etisalat/du) must NOT appear."
echo "   2. https://ipv6-test.com    -> IPv4 should show the server's public IP;"
echo "      IPv6 must show 'not supported' (proof it is not leaking around the tunnel)."
echo "   3. https://speed.cloudflare.com -> real end-to-end tunnel throughput."
echo
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
