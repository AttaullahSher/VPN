# Troubleshooting

## Handshake never completes (client shows no "latest handshake")

Work outward from the server.

1. **Is WireGuard even listening?**
   `sudo wg show wg0` — if there is no output, `systemctl status wg-quick@wg0`.
2. **Does the packet reach the host?**
   `sudo tcpdump -ni any udp port 51820` while the phone tries to connect.
   - *No packets at all* → the VCN security list is missing the UDP 51820
     ingress rule, or the phone is on a network that blocks outbound UDP.
   - *Packets arrive, nothing goes back* → local iptables. Go to step 3.
3. **Is the ACCEPT before the REJECT?**
   `sudo iptables -L INPUT --line-numbers -n`
   Oracle's image ends INPUT with `REJECT --reject-with icmp-host-prohibited`.
   An ACCEPT rule numbered *after* it never matches. `verify.sh` checks this
   ordering explicitly. Fix: `sudo iptables -I INPUT 1 -p udp --dport 51820 -j ACCEPT`
   then `sudo netfilter-persistent save`.

## Handshake works, but no internet

- `sysctl net.ipv4.ip_forward` must be `1`.
- NAT: `sudo iptables -t nat -L POSTROUTING -n -v` must show a MASQUERADE for
  `10.66.66.0/24` out the WAN interface, and the packet counter must climb.
- FORWARD chain: same REJECT-ordering trap as INPUT.

## Sites load partially, then hang (classic MTU black hole)

Symptom: DNS resolves, small pages load, large pages and downloads stall.

The tunnel MTU is 1420 and TCP MSS is clamped to the path MTU, which covers
almost everything. If it still happens on one specific network, lower the
client's MTU: edit the peer in the WireGuard iOS app and set `MTU = 1280`
(the IPv6 minimum, guaranteed to pass everywhere). Cost is a little throughput.

## DNS does not resolve inside the tunnel

- `systemctl status unbound`
- `dig @10.66.66.1 cloudflare.com` from the server.
- unbound binds `10.66.66.1` before `wg0` exists at boot; that works because
  `ip-freebind: yes` is set. If you removed it, unbound will fail on reboot only.

## Locked out of SSH

Oracle's console has a **serial console** per instance (Instance details →
Console connection) that works even when sshd is broken. `setup.sh` refuses to
disable password login unless it finds at least one authorized key, so the usual
lockout cannot happen through it.

## Instance disappeared

Always Free instances are reclaimed after 7 days idle on all of CPU/network/memory.
`verify.sh` section 8 shows whether the ballast is holding memory above the 20%
threshold. Upgrading to Pay As You Go removes idle reclamation entirely.

## Useful one-liners

```sh
sudo wg show                                  # peers, handshakes, transfer
sudo bash server/verify.sh                    # full health check
sudo bash server/egress.sh                    # egress vs the 10 TB cap
sudo journalctl -u wg-quick@wg0 -n 50         # interface bring-up log
sudo fail2ban-client status sshd              # who has been banned
sudo iptables -L -n -v --line-numbers         # rules with packet counters
```
