# Resume prompt

Paste the block below into a **new Claude Code session running on your own
machine** (`npm install -g @anthropic-ai/claude-code`, then `claude`).

Why a local session and not the Chrome extension: the extension reads and clicks
web pages in your browser. It cannot open an SSH connection or run shell
commands, which is all the remaining work is. It can help you click through the
Oracle console if you want, but it cannot build the server.

## Accesses the new session needs

| Access | Why | How |
|---|---|---|
| Local shell | To SSH into the server and run the setup scripts | Automatic — Claude Code runs on your machine |
| This repo | All the scripts and project state live here | `git clone https://github.com/AttaullahSher/VPN.git` |
| `~/.ssh/oracle_wg` | The private key the server accepts | Already on your PC |
| OCI Cloud Shell | Only to read the launch log and get the IP | You operate it in the browser; paste output into the session |

No MCP servers, no connectors, no extension permissions are required.

---

## The prompt

```
I'm setting up a private WireGuard VPN on Oracle Cloud Always Free for 4 people
(me + 3 family members). Personal use, not a public service. Primary client is
iPhone/iOS.

First, clone and read this repo - it contains all the scripts and the full
project state:

  git clone https://github.com/AttaullahSher/VPN.git
  cd VPN

Read RESUME.md before doing anything. It records what's done, what's pending,
every decision made so far and why, and the problems already hit and solved.
Then read README.md.

CURRENT STATE:
- Oracle account created. Home region me-abudhabi-1 (Abu Dhabi). Cannot be changed.
- VCN and public subnet created.
- Security list ingress rules open: UDP 51820 and TCP 443.
- My SSH public key is registered in the instance launch metadata.
- Instance NOT created yet. A retry loop is running in OCI Cloud Shell under
  tmux session "wg", logging to ~/wg/launch.log, trying to launch a
  VM.Standard.A1.Flex at 1 OCPU / 6 GB. It keeps hitting "Out of host capacity",
  which is normal for free Ampere.

MY SETUP:
- Windows PC. SSH private key at ~/.ssh/oracle_wg (ed25519, no passphrase).
- Connect as: ssh -i $HOME\.ssh\oracle_wg ubuntu@<PUBLIC_IP>
- Use port 22. Ignore the port-443 SSH workaround mentioned in the repo - that
  existed only because an earlier session was firewalled to ports 80/443.
- I run OCI Cloud Shell in a browser tab and can paste its output to you.

WHAT I NEED, IN ORDER:
1. Get the instance running. Check the Cloud Shell loop; restart it if it died.
2. Confirm the firewall rules are actually in place.
3. Phase 2 - SSH in and run server/setup.sh (hardening, WireGuard, firewall,
   DNS, idle-reclaim protection).
4. Phase 3 - create 4 peers: atta-iphone, atta-laptop, peer3, peer4. Full
   tunnel. Deliver each as a QR code I can scan with the WireGuard iOS app.
   Also tell me how to add or revoke a peer later without touching the others.
5. Phase 4 - verify handshake, real throughput, no DNS leaks. Show me how to
   check monthly egress against the 10 TB free cap.

HOW I WANT YOU TO WORK:
- Short, literal, sequential steps. One thing at a time. No option trees.
- Label every command with WHERE it runs: my PowerShell, or Oracle Cloud Shell,
  or on the server over SSH.
- Explain what a command does before running it.
- Never print a private key into chat.
- Stop at the end of each phase and wait for me to confirm before continuing.
- If something fails, diagnose it before retrying.
```
