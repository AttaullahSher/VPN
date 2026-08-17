# Project state — resume from here

Last updated: 2026-08-17. Written so a fresh session can pick this up cold.

## Goal

A private WireGuard VPN for four people (owner + three family members) on an
Oracle Cloud Always Free ARM instance. Personal use, not a public service.
Primary client is **iPhone / iOS**.

Peer names to create: `atta-iphone`, `atta-laptop`, `peer3`, `peer4`.

## Where things stand

| | Status |
|---|---|
| Oracle account | ✅ created |
| Home region | ✅ `me-abudhabi-1` (UAE Central, Abu Dhabi) — **cannot be changed** |
| VCN + public subnet | ✅ created via the VCN wizard |
| Compute instance | ⏳ **launch loop running in Cloud Shell** under tmux session `wg`, logging to `~/wg/launch.log`. Repeatedly hitting "Out of host capacity", which is normal for free Ampere. This is the only outstanding blocker. |
| Security list ingress | ✅ UDP 51820 + TCP 443 open on the default security list |
| Phase 2 (server setup) | ⬜ not started — needs the public IP |
| Phase 3 (peers) | ⬜ not started |
| Phase 4 (verify) | ⬜ not started |

Availability domain is `pMOH:ME-ABUDHABI-1-AD-1` (Abu Dhabi has exactly one, so
there is no second AD to try).

## Owner's working preferences

- Wants **short, literal, sequential instructions**. No option trees, no
  trade-off essays mid-task. Define jargon on first use.
- Explain what a command does before running it.
- **Never print a private key** into chat output that might be screenshotted.
- Stop at each phase checkpoint and wait for confirmation.

## Decisions already made, and why

**Region** — Abu Dhabi. ~2–5 ms latency. Chosen; not revisitable.

**Shape** — `VM.Standard.A1.Flex`, **1 OCPU / 6 GB**. Started at 2 OCPU / 12 GB
but Ampere capacity in Abu Dhabi kept refusing, so the owner opted down. This is
not a compromise worth undoing: free A1 gives 1 Gbit/s of network per OCPU and
WireGuard is kernel-space, so 1 OCPU is already a full-gigabit tunnel for four
people — far beyond any home or mobile uplink. Resizable to 2 OCPU later from
the console with a stop/start, keeping the same IP and disk.

Note for `setup.sh`: the memory ballast takes 30% of RAM, so on 6 GB that is
~1.8 GB, still comfortably over Oracle's 20% idle threshold. No change needed.

**SSH on port 443** — the cloud-init payload adds a second SSH port. This existed
only because the original setup host was firewalled to outbound 80/443 and could
not use port 22. **The owner connects from their own Windows PC on port 22.
Ignore the 443 workaround.** It is harmless to leave as a fallback, and
removable by deleting `/etc/ssh/sshd_config.d/99-alt-port.conf` and the matching
`ssh.socket.d` drop-in.

**Launch script never overwrites `key.pub`** — an earlier version of
`oracle/cloudshell-launch-retry.sh` wrote a hardcoded `claude-setup` public key
over `key.pub` every run. That key's private half is gone, so restarting the
loop with it would have launched an instance nobody could log in to, and the
only remedy would be terminating it and re-queueing for Ampere capacity. The
script now reuses an existing `key.pub`, refuses to run without one, and prints
the fingerprints it is about to authorise. Its defaults are also 1 OCPU / 6 GB,
matching the shape actually being requested, and its work directory is `~/wg`.

**Tunnel** — `10.66.66.0/24` + `fd42:66:66::/64`, UDP 51820, MTU 1420, TCP MSS
clamped to path MTU.

**IPv6** — Oracle VCNs have no IPv6 uplink by default. Peers still route `::/0`
into the tunnel so an IPv6-capable carrier cannot route around the VPN; the
server drops it and clients fall back cleanly to IPv4.

**DNS** — `unbound` on `10.66.66.1`, reachable only from inside the tunnel,
forwarding upstream over DNS-over-TLS to Cloudflare and Quad9. Trade-off table in
`docs/PHASE1_ORACLE_CONSOLE.md`. Not yet confirmed with the owner.

**Idle reclamation** — Oracle reclaims a free instance only when CPU (95th pct),
network *and* memory all stay under 20% for 7 days. A memory ballast holding 30%
of RAM satisfies the rule at zero CPU cost, at `Nice=19` with
`OOMScoreAdjust=1000` so the kernel kills it first under real memory pressure.

## SSH keys

Two public keys should be in the instance's `ssh_authorized_keys` metadata:

1. `claude-setup` — belongs to the original ephemeral setup container. **Assume
   this key is gone.** Do not depend on it.
2. `sales@Admin` — the owner's own key, at `~/.ssh/oracle_wg` on their Windows
   machine. Fingerprint `SHA256:LLfIij8wj0wHEvqd9JSgyoAwhWBAr3YkXjXBTfCX25s`.
   **This is the one to use.**

Both are already in `~/wg/key.pub` in Cloud Shell and baked into `~/wg/md.json`,
so the instance will accept both the moment it launches.

Connect with:

    ssh -i $HOME\.ssh\oracle_wg ubuntu@<PUBLIC_IP>

## Next steps, in order

1. **Get the instance running.** In Cloud Shell: `tail -5 ~/wg/launch.log`.
   Restart the loop with `oracle/cloudshell-launch-retry.sh` if it died. Drop to
   `OCPUS=1 MEMGB=6` if capacity keeps refusing.
2. **Open the ports** — `oracle/cloudshell-open-ports.sh` (UDP 51820, TCP 443).
3. **Phase 2** — copy `server/setup.sh` to the instance and run it as root.
   Explain each of its nine stages before running. Verify it reports the public
   IP, WAN interface and server public key at the end.
4. **Phase 3** — `sudo bash peer.sh add atta-iphone` (then `atta-laptop`,
   `peer3`, `peer4`). Confirm the DNS choice with the owner first. Deliver each
   peer as a QR code — `peer.sh qr <name>` in a terminal the owner controls, not
   pasted into chat. iOS: WireGuard app → **+** → **Create from QR code**.
5. **Phase 4** — `sudo bash verify.sh`, then the three client-side checks it
   prints (dnsleaktest.com extended, ipv6-test.com, speed.cloudflare.com).

## Gotchas already hit

- The launch loop must treat **HTTP 429 `TooManyRequests`** as retryable with
  exponential backoff. Oracle throttles `launch_instance` per user; a fixed 60 s
  interval trips it within two attempts. Fixed in
  `oracle/cloudshell-launch-retry.sh` (90 s base, doubling to a 15 min ceiling,
  reset on a normal capacity answer).
- Cloud Shell disconnects after ~20 minutes idle and kills foreground jobs. Run
  the loop under `tmux` (`tmux new -d -s wg …`, reattach with `tmux attach -t wg`).
- Oracle's Ubuntu image ends INPUT and FORWARD in
  `REJECT --reject-with icmp-host-prohibited`. Opening the VCN security list is
  not sufficient — rules must be **inserted at the head** of the chain. Presence
  is not enough; ordering is the thing to check.
