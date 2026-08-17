#!/usr/bin/env bash
# =============================================================================
# setup.sh - Phase 2: base hardening + WireGuard server on Oracle Cloud
#            Ubuntu 24.04 LTS, VM.Standard.A1.Flex (ARM) or any Ubuntu 24.04 VM.
#
# Idempotent: safe to run more than once.
# Run as root:  sudo bash setup.sh
# =============================================================================
set -euo pipefail

# ------------------------------- configuration -------------------------------
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_DIR="${WG_DIR:-/etc/wireguard}"

WG_NET4="${WG_NET4:-10.66.66.0/24}"
WG_ADDR4="${WG_ADDR4:-10.66.66.1}"
WG_NET6="${WG_NET6:-fd42:66:66::/64}"
WG_ADDR6="${WG_ADDR6:-fd42:66:66::1}"

# 1420 = 1500 (typical internet path MTU) - 80 bytes of worst-case WireGuard
# overhead (IPv6 outer header 40 + UDP 8 + WG 32). Works for both IPv4 and IPv6
# endpoints. TCP MSS clamping (below) covers any path that is smaller still.
WG_MTU="${WG_MTU:-1420}"

# Idle-reclaim protection. Oracle reclaims an Always Free instance only when ALL
# of CPU(95th pct)/network/memory stay under 20% for 7 days, so holding memory
# above 20% alone is enough - and costs no CPU.
KEEPALIVE_MEM="${KEEPALIVE_MEM:-1}"      # 1 = enable memory ballast
KEEPALIVE_CPU="${KEEPALIVE_CPU:-0}"      # 1 = also burn ~22% CPU (belt & braces)
BALLAST_PCT="${BALLAST_PCT:-30}"         # % of total RAM to hold

STATE_DIR=/var/lib/wg-oracle
# -----------------------------------------------------------------------------

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use: sudo bash setup.sh)"

export DEBIAN_FRONTEND=noninteractive
mkdir -p "$STATE_DIR"

# =============================================================================
log "0/9  Pre-flight"
# =============================================================================
. /etc/os-release
info "OS            : ${PRETTY_NAME}"
info "Kernel/arch   : $(uname -r) / $(uname -m)"
[ "${ID:-}" = "ubuntu" ] || warn "not Ubuntu - continuing, but this is untested"

# Primary (internet-facing) interface: whatever the default route uses.
WAN_IF="$(ip -4 route show default | awk '/default/ {print $5; exit}')"
[ -n "$WAN_IF" ] || die "could not determine the default-route interface"
info "WAN interface : $WAN_IF"

# Prefer Oracle's instance metadata for the public IP - it is authoritative and
# does not depend on outbound internet working yet.
PUBLIC_IP="$(curl -fsS -m 5 -H 'Authorization: Bearer Oracle' \
              http://169.254.169.254/opc/v2/vnics/ 2>/dev/null \
              | grep -o '"publicIp"[^,]*' | head -1 | cut -d'"' -f4 || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(curl -fsS -m 8 https://api.ipify.org || true)"
[ -n "$PUBLIC_IP" ] || die "could not determine the public IP"
info "Public IP     : $PUBLIC_IP"
echo "$PUBLIC_IP" > "$STATE_DIR/public_ip"
echo "$WAN_IF"    > "$STATE_DIR/wan_if"

# Does this host have real (globally routable) IPv6? Oracle VCNs are IPv4-only
# unless IPv6 was explicitly enabled, so this is usually "no".
HAS_V6=0
if ip -6 addr show dev "$WAN_IF" scope global 2>/dev/null | grep -q 'inet6'; then
  HAS_V6=1
fi
info "Host IPv6     : $([ $HAS_V6 -eq 1 ] && echo 'yes (global)' || echo 'no - clients get IPv6 blackholed inside the tunnel, which prevents IPv6 leaks')"
echo "$HAS_V6" > "$STATE_DIR/has_v6"

# =============================================================================
log "1/9  Installing packages"
# =============================================================================
# Pre-answer iptables-persistent's interactive prompts so apt never blocks.
echo 'iptables-persistent iptables-persistent/autosave_v4 boolean false' | debconf-set-selections
echo 'iptables-persistent iptables-persistent/autosave_v6 boolean false' | debconf-set-selections

apt-get update -q
apt-get install -y -q \
  wireguard wireguard-tools qrencode \
  iptables iptables-persistent netfilter-persistent \
  unattended-upgrades apt-listchanges \
  fail2ban python3-systemd \
  unbound unbound-anchor ca-certificates \
  vnstat curl jq
info "packages installed"

# =============================================================================
log "2/9  Automatic security updates (unattended-upgrades)"
# =============================================================================
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/51-wg-unattended <<'EOF'
// Security pocket only - avoids surprise feature upgrades on a VPN gateway.
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
// Kernel security fixes need a reboot to take effect. WireGuard reconnects on
// its own, so an off-peak reboot is cheap insurance.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
info "security-only auto-updates on; auto-reboot 04:30 server time if a kernel update needs it"

# =============================================================================
log "3/9  SSH hardening + fail2ban"
# =============================================================================
# Refuse to disable password auth if the current user has no authorized key -
# that would lock everyone out permanently.
KEYCOUNT=0
for f in /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys; do
  [ -f "$f" ] || continue
  # grep -c prints 0 and exits 1 when there are no matches; swallow the status
  # so neither the arithmetic nor "set -e" trips on an empty authorized_keys.
  n="$(grep -cvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null || true)"
  KEYCOUNT=$(( KEYCOUNT + ${n:-0} ))
done
[ "$KEYCOUNT" -gt 0 ] || die "no authorized_keys found anywhere - refusing to disable password login (you would be locked out)"
info "found $KEYCOUNT authorized SSH key(s) - safe to disable password login"

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PermitEmptyPasswords no
MaxAuthTries 3
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 120
ClientAliveCountMax 3
EOF
sshd -t || die "sshd config test failed - not restarting sshd"
systemctl restart ssh.socket 2>/dev/null || true
systemctl restart ssh 2>/dev/null || true
info "password + root SSH login disabled (keys only)"

cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
port     = 22,443
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban || warn "fail2ban restart failed - check: journalctl -u fail2ban"
info "fail2ban watching sshd on ports 22 and 443 (5 strikes = 1h ban)"

# =============================================================================
log "4/9  Kernel forwarding + network tuning (persisted)"
# =============================================================================
cat > /etc/sysctl.d/99-wireguard.conf <<'EOF'
# Route packets between wg0 and the internet.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# Loose reverse-path filtering: strict mode drops legitimate VPN return
# traffic on multi-path/asymmetric cloud networking.
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# BBR + fq: markedly better throughput than cubic on long-haul, lossy links.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Larger conntrack table - 4 peers doing normal browsing generate a lot of flows.
net.netfilter.nf_conntrack_max = 262144
EOF
modprobe nf_conntrack 2>/dev/null || true
sysctl --system >/dev/null
info "ip_forward=$(sysctl -n net.ipv4.ip_forward)  ipv6.forwarding=$(sysctl -n net.ipv6.conf.all.forwarding)  cc=$(sysctl -n net.ipv4.tcp_congestion_control)"

# =============================================================================
log "5/9  WireGuard server keys and $WG_IF"
# =============================================================================
umask 077
mkdir -p "$WG_DIR/peers"
chmod 700 "$WG_DIR" "$WG_DIR/peers"

if [ ! -s "$WG_DIR/server.key" ]; then
  wg genkey > "$WG_DIR/server.key"
  chmod 600 "$WG_DIR/server.key"
  wg pubkey < "$WG_DIR/server.key" > "$WG_DIR/server.pub"
  info "generated a new server keypair"
else
  info "reusing the existing server keypair (peers stay valid)"
fi
chmod 644 "$WG_DIR/server.pub"
SERVER_PUB="$(cat "$WG_DIR/server.pub")"

if [ ! -f "$WG_DIR/$WG_IF.conf" ]; then
  cat > "$WG_DIR/$WG_IF.conf" <<EOF
# WireGuard server - managed by setup.sh / peer.sh
# Peers are added below between "# BEGIN PEER <name>" / "# END PEER <name>"
# markers. Do not remove those markers: peer.sh uses them to add and revoke
# individual peers without disturbing the others.
[Interface]
Address    = ${WG_ADDR4}/24, ${WG_ADDR6}/64
ListenPort = ${WG_PORT}
PostUp     = wg set %i private-key ${WG_DIR}/server.key
MTU        = ${WG_MTU}

EOF
  chmod 600 "$WG_DIR/$WG_IF.conf"
  info "created $WG_DIR/$WG_IF.conf"
else
  info "$WG_DIR/$WG_IF.conf already exists - left untouched"
fi
# The private key lives in its own 0600 file and is injected at interface bring-up,
# so it never has to sit inside a config that tooling might copy or print.

cat > "$STATE_DIR/env" <<EOF
WG_IF=$WG_IF
WG_PORT=$WG_PORT
WG_DIR=$WG_DIR
WG_NET4=$WG_NET4
WG_ADDR4=$WG_ADDR4
WG_NET6=$WG_NET6
WG_ADDR6=$WG_ADDR6
WG_MTU=$WG_MTU
WAN_IF=$WAN_IF
PUBLIC_IP=$PUBLIC_IP
HAS_V6=$HAS_V6
SERVER_PUB=$SERVER_PUB
EOF
chmod 600 "$STATE_DIR/env"

# =============================================================================
log "6/9  Firewall - fixing Oracle's default deny-all ruleset"
# =============================================================================
# Oracle's Ubuntu image ships /etc/iptables/rules.v4 whose INPUT and FORWARD
# chains both end in "REJECT --reject-with icmp-host-prohibited". Opening the
# VCN security list is therefore NOT enough: packets arrive at the instance and
# are dropped locally. Every rule below is INSERTED at the top of its chain so
# it is evaluated before that REJECT.
ipt4() { iptables  -C "$@" 2>/dev/null || iptables  -I "$@"; }
ipt6() { ip6tables -C "$@" 2>/dev/null || ip6tables -I "$@"; }

# --- INPUT: traffic addressed to the server itself ---
ipt4 INPUT -p udp --dport "$WG_PORT" -j ACCEPT                                  # WireGuard
ipt4 INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT              # SSH-over-443
ipt4 INPUT -i "$WG_IF" -j ACCEPT                                                # peers -> local DNS
ipt6 INPUT -p udp --dport "$WG_PORT" -j ACCEPT
ipt6 INPUT -i "$WG_IF" -j ACCEPT

# --- FORWARD: traffic passing through the server ---
ipt4 FORWARD -i "$WG_IF" -j ACCEPT                                              # peer -> internet
ipt4 FORWARD -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT   # replies back
ipt6 FORWARD -i "$WG_IF" -j ACCEPT
ipt6 FORWARD -o "$WG_IF" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# --- MSS clamping ---
# Rewrites the TCP MSS on SYN packets to fit the real path MTU. Without this,
# any path narrower than our 1420 MTU produces "site loads but hangs forever"
# black-hole symptoms that are painful to diagnose.
iptables  -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || iptables  -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || ip6tables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# --- NAT: rewrite peer source addresses to the server's public IP ---
iptables -t nat -C POSTROUTING -s "$WG_NET4" -o "$WAN_IF" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$WG_NET4" -o "$WAN_IF" -j MASQUERADE
if [ "$HAS_V6" -eq 1 ]; then
  ip6tables -t nat -C POSTROUTING -s "$WG_NET6" -o "$WAN_IF" -j MASQUERADE 2>/dev/null \
    || ip6tables -t nat -A POSTROUTING -s "$WG_NET6" -o "$WAN_IF" -j MASQUERADE
  info "IPv6 NAT enabled (host has a global IPv6 address)"
else
  info "IPv6 NAT skipped (host has no global IPv6). Peers still route ::/0 into the"
  info "tunnel, where it is dropped - that is deliberate: it stops the phone from"
  info "quietly sending IPv6 traffic around the VPN over the carrier network."
fi

netfilter-persistent save >/dev/null
systemctl enable netfilter-persistent >/dev/null 2>&1 || true
info "rules written to /etc/iptables/rules.v4 and rules.v6 - they survive reboot"

# =============================================================================
log "7/9  DNS resolver (unbound, reachable only from inside the tunnel)"
# =============================================================================
# Peers point at 10.66.66.1, so DNS queries travel inside the tunnel and cannot
# leak to the local Wi-Fi / carrier resolver. unbound then forwards upstream over
# DNS-over-TLS, so Oracle's network cannot read the queries either.
cat > /etc/unbound/unbound.conf.d/wg.conf <<EOF
server:
    verbosity: 0
    interface: ${WG_ADDR4}
    interface: ${WG_ADDR6}
    # Bind these addresses before wg0 exists (unbound starts first at boot).
    ip-freebind: yes
    port: 53

    do-ip4: yes
    do-ip6: yes
    do-udp: yes
    do-tcp: yes

    # Answer only peers. Everything else is refused, so this can never be
    # abused as an open resolver for DNS amplification.
    access-control: 0.0.0.0/0 refuse
    access-control: ::0/0 refuse
    access-control: 127.0.0.0/8 allow
    access-control: ${WG_NET4} allow
    access-control: ${WG_NET6} allow

    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    use-caps-for-id: no
    qname-minimisation: yes
    aggressive-nsec: yes
    prefetch: yes
    cache-min-ttl: 60
    cache-max-ttl: 86400
    msg-cache-size: 64m
    rrset-cache-size: 128m
    so-reuseport: yes

    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt

forward-zone:
    name: "."
    forward-tls-upstream: yes
    forward-addr: 1.1.1.1@853#cloudflare-dns.com
    forward-addr: 1.0.0.1@853#cloudflare-dns.com
    forward-addr: 9.9.9.9@853#dns.quad9.net
    forward-addr: 149.112.112.112@853#dns.quad9.net
EOF

# unbound-resolvconf tries to hijack the host's own /etc/resolv.conf; we only
# want unbound serving VPN peers, not replacing systemd-resolved locally.
systemctl disable --now unbound-resolvconf.service >/dev/null 2>&1 || true

unbound-checkconf >/dev/null || die "unbound config is invalid"
systemctl enable unbound >/dev/null 2>&1 || true
info "unbound configured (DNS-over-TLS to Cloudflare + Quad9, VPN-only access)"

# =============================================================================
log "8/9  Enabling wg-quick@$WG_IF at boot"
# =============================================================================
systemctl enable "wg-quick@$WG_IF" >/dev/null 2>&1
if systemctl is-active --quiet "wg-quick@$WG_IF"; then
  systemctl restart "wg-quick@$WG_IF"
  info "$WG_IF restarted to pick up interface-level settings (address/MTU/port)"
else
  systemctl start "wg-quick@$WG_IF"
  info "$WG_IF started"
fi
# Note: individual peers are added and removed later with live "wg set" calls,
# which never restart the interface and never disturb other peers sessions.
systemctl restart unbound
systemctl enable --now vnstat >/dev/null 2>&1 || true
info "vnstat started (it meters egress for the 10 TB free-tier cap)"

# =============================================================================
log "9/9  Idle-reclaim protection"
# =============================================================================
# Oracle reclaims an Always Free instance only if, across a 7-day window, ALL of
# these stay below 20%: CPU (95th percentile), network, and memory. Holding
# memory above the threshold satisfies the rule on its own and costs no CPU.
if [ "$KEEPALIVE_MEM" = "1" ]; then
  TOTAL_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
  BALLAST_MB=$(( TOTAL_MB * BALLAST_PCT / 100 ))
  cat > /usr/local/bin/wg-ballast <<EOF
#!/usr/bin/env python3
"""Hold ${BALLAST_PCT}% of RAM resident so Oracle does not classify this
instance as idle. Touches each page once, then sleeps forever."""
import time
size = ${BALLAST_MB} * 1024 * 1024
buf = bytearray(size)
for i in range(0, size, 4096):
    buf[i] = 1
while True:
    time.sleep(3600)
EOF
  chmod +x /usr/local/bin/wg-ballast
  cat > /etc/systemd/system/wg-ballast.service <<EOF
[Unit]
Description=Memory ballast to prevent Oracle Always Free idle reclamation
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wg-ballast
Restart=always
RestartSec=30
Nice=19
# Never let the ballast be the reason a real process gets OOM-killed.
OOMScoreAdjust=1000

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now wg-ballast >/dev/null 2>&1
  info "memory ballast: holding ${BALLAST_MB} MB of ${TOTAL_MB} MB (${BALLAST_PCT}%) - above Oracle's 20% idle threshold"
  info "OOM score is maxed, so the kernel kills the ballast first if memory ever runs short"
else
  info "memory ballast disabled (KEEPALIVE_MEM=0)"
fi

if [ "$KEEPALIVE_CPU" = "1" ]; then
  cat > /etc/systemd/system/wg-cpukeep.service <<'EOF'
[Unit]
Description=Low-priority CPU load to prevent Oracle idle reclamation
After=multi-user.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'while :; do :; done'
# ~45% of one core. On a 2-OCPU shape that is ~22% total, over the 20% threshold.
CPUQuota=45%
Nice=19
Restart=always

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now wg-cpukeep >/dev/null 2>&1
  info "CPU keeper enabled (~22% of total CPU, lowest priority - yields instantly to VPN traffic)"
else
  info "CPU keeper disabled - memory ballast alone satisfies Oracle's rule"
  info "to enable later: systemctl enable --now wg-cpukeep  (unit is not installed unless KEEPALIVE_CPU=1)"
fi

# =============================================================================
log "Done"
# =============================================================================
cat <<EOF

  Server public key : ${SERVER_PUB}
  Endpoint          : ${PUBLIC_IP}:${WG_PORT}/udp
  Tunnel subnets    : ${WG_NET4}  |  ${WG_NET6}
  Tunnel MTU        : ${WG_MTU}   (+ TCP MSS clamped to path MTU)
  DNS for peers     : ${WG_ADDR4} , ${WG_ADDR6}

  Next: create peers with   sudo bash peer.sh add <name>

EOF
