# Phase 1 — Oracle console (you click, on the phone)

## Region recommendation

**Pick `me-dubai-1` (UAE — Dubai) as your home region.**

- ~5–10 ms from Abu Dhabi. The Abu Dhabi region (`me-abudhabi-1`) is a couple of
  milliseconds closer, which you will never feel.
- Dubai is the larger and longer-established of the two UAE regions, so it has
  more Ampere A1 hardware — and Ampere capacity, not latency, is what actually
  decides whether this project works.
- Both UAE regions are far less contended for free-tier A1 than Frankfurt,
  Amsterdam, Phoenix or Ashburn, where free A1 is effectively permanently gone.

> **The home region cannot be changed after signup.** Not by support, not by
> re-verifying. Choose it deliberately on the signup form.

## Account limits worth knowing

- Always Free Ampere allowance is **4 OCPU + 24 GB total**. A 2 OCPU / 12 GB
  instance uses half, leaving room for a second instance later.
- Free egress allowance is **10 TB/month**. Ingress is free.
- A card is required for identity verification. Oracle places a small temporary
  authorisation (about 1 USD) and refunds it. An Always Free account cannot
  incur charges — it refuses to provision billable resources instead.

## DNS resolver choice, and the trade-off

The peer configs point at **10.66.66.1**, which is `unbound` running on your own
server, forwarding upstream over **DNS-over-TLS to Cloudflare (1.1.1.1) and
Quad9 (9.9.9.9)**.

| Option | Who can see your DNS queries | Notes |
|---|---|---|
| Resolver on your server, DoT upstream *(chosen)* | Cloudflare/Quad9 see queries, but attributed to the VPN — four people's traffic mixed together. Oracle sees only encrypted 853/tcp. | Local cache makes repeat lookups instant. One more service to keep running. |
| Public resolver directly (1.1.1.1 in the config) | Same resolvers see the same queries. Oracle's network sees them in cleartext unless the client does DoT itself. | Simplest. No server-side DNS to maintain. |
| Full recursion (no forwarder) | Nobody sees the whole picture; each authoritative server sees only its own zone. | Slower cold lookups, and some authoritative servers rate-limit or block cloud IP ranges. Fragile for a family VPN. |

The real leak protection is the same in all three cases: `DNS = 10.66.66.1` plus
`AllowedIPs = 0.0.0.0/0, ::/0` forces every query inside the tunnel, so the
café Wi-Fi or Etisalat's resolver never sees a request. The choice above is only
about *who upstream* sees them. If you would rather cut out the middle service,
say so and it is a one-line change.

## If you hit "Out of host capacity"

This is the single most common failure, and it is not your fault — free A1
capacity is genuinely exhausted much of the time. In rough order of effectiveness:

1. **Retry on a loop, not by hand.** Capacity is freed in seconds-long bursts as
   other people delete instances. Use `oracle/cloudshell-launch-retry.sh` in
   Cloud Shell and leave the tab open. Overnight local time (roughly 00:00–06:00
   UTC) has the best hit rate.
2. **Ask for less.** 1 OCPU / 6 GB succeeds far more often than 2 OCPU / 12 GB.
   Take it, then resize up later — A1 Flex can be reshaped from the console with
   a stop/start, and it keeps the same IP and disk.
3. **Upgrade to Pay As You Go.** The most reliable fix by a wide margin. Your
   Always Free resources stay free; PAYG accounts are simply not queued behind
   free-tier ones for Ampere, and they are exempt from idle reclamation. The risk
   is that you can now create billable things by accident — set a budget alert at
   1 USD under Billing → Budgets on day one.
4. **Fall back to `VM.Standard.E2.1.Micro`** (x86, 1 GB RAM, always free, always
   available). WireGuard is kernel-space and tiny, so it handles four people
   fine — but Always Free micro instances are throttled to about 50 Mbit/s,
   against roughly 1 Gbit/s per OCPU on A1. Fine as a stopgap, disappointing as
   a destination.

Changing region is *not* on this list, because you cannot.

## The SSH public key to paste

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINZOq7gwxznX1mnwaZc4WWS4DyYWWWYLiT1dhptJHF0D claude-setup
```

## The cloud-init script to paste

See `cloud-init/bootstrap.yaml`. It only adds SSH on TCP/443, because the
machine doing the remote setup can make outbound connections on ports 80 and 443
only — port 22 is blocked for it. Port 22 keeps working normally for you.

## Ingress rules needed

| Protocol | Port | Source | Why |
|---|---|---|---|
| UDP | 51820 | 0.0.0.0/0 | WireGuard itself |
| TCP | 443 | 0.0.0.0/0 | SSH-over-443 for remote setup (removable afterwards) |
| TCP | 22 | 0.0.0.0/0 | already present by default |

Adding these by hand in the console on a phone is fiddly. `oracle/cloudshell-open-ports.sh`
does it in one paste from Cloud Shell instead.
