# Private WireGuard VPN on Oracle Cloud Always Free

A four-person family VPN on an Oracle Cloud `VM.Standard.A1.Flex` ARM instance
(2 OCPU / 12 GB, Ubuntu 24.04 LTS). Personal use, not a public service.

Everything here is scripted and idempotent. Nothing prints a private key unless
you explicitly ask it to.

## Layout

| Path | What it does |
|---|---|
| `cloud-init/bootstrap.yaml` | Pasted at instance creation. Only adds SSH on TCP/443. |
| `oracle/cloudshell-open-ports.sh` | Opens UDP 51820 + TCP 443 in the VCN security list, from Cloud Shell. |
| `oracle/cloudshell-launch-retry.sh` | Retry loop for "Out of host capacity". |
| `server/setup.sh` | Phase 2. Hardening, WireGuard, firewall, DNS, keep-alive. |
| `server/peer.sh` | Phase 3. `add` / `list` / `qr` / `png` / `conf` / `revoke`. |
| `server/verify.sh` | Phase 4. Handshakes, firewall ordering, DNS, MTU, throughput. |
| `server/egress.sh` | Month-to-date egress vs the 10 TB free cap. |
| `docs/` | Phase 1 console walkthrough and troubleshooting. |

## Design decisions

**Tunnel** — `10.66.66.0/24` + `fd42:66:66::/64`, UDP 51820, MTU 1420.
1420 = 1500 minus 80 bytes of worst-case WireGuard overhead. TCP MSS is also
clamped to the real path MTU on the server, which kills the "page half-loads
then hangs" class of bug on networks with a smaller MTU.

**Oracle's firewall trap** — the Ubuntu image ships an iptables ruleset whose
INPUT and FORWARD chains both end in `REJECT --reject-with icmp-host-prohibited`.
Opening the VCN security list is *not* enough; packets reach the instance and
get dropped locally. Every rule is therefore **inserted at the top** of its
chain, and `verify.sh` explicitly checks the ACCEPT is numbered lower than the
REJECT. Rules persist via `netfilter-persistent` to `/etc/iptables/rules.v4`.

**IPv6** — Oracle VCNs are IPv4-only unless you enable IPv6 explicitly, so the
server usually has no IPv6 uplink. Peers still route `::/0` into the tunnel
anyway. That is deliberate: without it, a phone on an IPv6-capable carrier would
send IPv6 traffic around the VPN over the mobile network. Routing it into a
tunnel that drops it forces a clean fallback to IPv4.

**DNS** — `unbound` on `10.66.66.1`, reachable only from inside the tunnel,
forwarding upstream over DNS-over-TLS to Cloudflare and Quad9. Trade-off in
`docs/PHASE1_ORACLE_CONSOLE.md`.

**Peer add/revoke isolation** — peers are applied with live `wg set` calls, never
by restarting the interface. Adding or revoking one peer does not drop anyone
else's session.

**Idle reclamation** — Oracle reclaims an Always Free instance only when CPU
(95th percentile), network *and* memory all stay under 20% for 7 days. A memory
ballast holding 30% of RAM satisfies the rule at zero CPU cost, and is given the
maximum OOM score so the kernel kills it first if real memory is ever needed.

## SSH access key

The setup machine uses this public key. It is safe to publish:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINZOq7gwxznX1mnwaZc4WWS4DyYWWWYLiT1dhptJHF0D claude-setup
```

The matching private key never leaves the setup machine and is never printed.
