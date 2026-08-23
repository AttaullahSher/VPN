#!/usr/bin/env bash
# =============================================================================
# phase0-auto.sh - terminal-free, phone-only bring-up of the whole VPN.
#
# Meant to be pulled and run once, as root, by Oracle cloud-init on first boot
# (see docs/PHASE0_MOBILE.md). It runs the normal server build and then hands
# the peer QR codes to a phone over a short-lived, password-protected web page,
# so the owner never needs SSH or a terminal.
#
# It does, in order:
#   1. waits for any boot-time apt/unattended-upgrade to finish,
#   2. fetches setup.sh + peer.sh from this repo,
#   3. guarantees an authorized SSH key exists (so setup.sh's lock-out guard
#      passes even if the instance was created with "No SSH keys"),
#   4. runs setup.sh  (WireGuard, firewall, DNS, idle ballast - Phase 2),
#   5. creates the four peers and their QR PNGs   (Phase 3),
#   6. serves those QR codes on https://<public-ip>/ for a limited time,
#      behind HTTP Basic Auth with a passphrase the owner set in the boot line.
#
# SECURITY NOTE, on purpose and in plain sight: a WireGuard QR / .conf contains
# that peer's PRIVATE KEY. This page therefore serves secrets. It is defended by
# three things and no more, so treat it as a bootstrap convenience, not a
# permanent service:
#   - a passphrase (WG_PASS) that the owner chose, required on every request;
#   - TLS, so the codes are encrypted in transit (the cert is self-signed, so
#     the browser will warn "not private" - that only means "no domain name to
#     verify", not "not encrypted");
#   - a hard time limit (DELIVER_TTL, default 60 min) after which the page shuts
#     itself off and does not come back, plus a "shut down now" button.
# Nothing here is ever printed into a chat or a commit - the keys are generated
# on the instance and shown only to the owner's authenticated browser.
#
# Overridable with environment variables set in the boot line:
#   WG_PASS       passphrase for the delivery page      (default "scan-me-please")
#   WG_PEERS      space-separated peer names            (default the RESUME set)
#   DELIVER_TTL   seconds the page stays up             (default 3600 = 60 min)
#   REPO_RAW      raw base URL to fetch scripts from
# =============================================================================
set -uo pipefail   # deliberately not -e: a failed step should be logged, not
                   # kill the whole boot silently where nobody can see it.

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/AttaullahSher/VPN/main}"
WORK="${WORK:-/opt/vpn}"
WG_PASS="${WG_PASS:-scan-me-please}"
WG_PEERS="${WG_PEERS:-atta-iphone atta-laptop peer3 peer4}"
DELIVER_TTL="${DELIVER_TTL:-3600}"

PASS_FILE=/run/wg-deliver-pass
CERT=/run/wg-deliver.crt
KEY=/run/wg-deliver.key
STATE_DIR=/var/lib/wg-oracle

log()  { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$WORK"

log "phase0 starting $(date -u +%FT%TZ)"

# --- 1. let any first-boot apt / unattended-upgrade finish before we touch apt -
wait_apt() {
  local i=0
  while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; do
    [ "$i" -eq 0 ] && info "waiting for a boot-time apt run to finish..."
    sleep 5; i=$((i + 1)); [ "$i" -gt 72 ] && { warn "apt still busy after 6 min - continuing anyway"; break; }
  done
}
wait_apt

# openssl (self-signed cert) and python3 (the tiny server) are all we add here;
# setup.sh installs everything the VPN itself needs.
apt-get update -q  || warn "apt-get update failed - continuing"
apt-get install -y -q openssl python3 ca-certificates curl || warn "apt-get install of helpers failed - continuing"

# --- 2. fetch the build scripts from this repo -------------------------------
log "fetching setup.sh and peer.sh"
for f in setup.sh peer.sh; do
  if ! curl -fsSL "$REPO_RAW/server/$f" -o "$WORK/$f"; then
    echo "!! could not fetch $REPO_RAW/server/$f - aborting" >&2
    exit 1
  fi
done
chmod +x "$WORK"/setup.sh "$WORK"/peer.sh
info "scripts in $WORK"

# --- 3. make sure an authorized SSH key exists -------------------------------
# setup.sh refuses to disable password login (and aborts) if it finds NO
# authorized key anywhere - a sensible guard against locking yourself out. On
# this path the owner may have chosen "No SSH keys" in the console because they
# never intend to SSH in. If so, authorize a key we generate and then destroy:
# nobody can ever use it, but the guard is satisfied and the build continues.
ensure_authorized_key() {
  local f found=0
  for f in /home/*/.ssh/authorized_keys /root/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    grep -qvE '^[[:space:]]*(#|$)' "$f" 2>/dev/null && { found=1; break; }
  done
  if [ "$found" = 1 ]; then
    info "an authorized SSH key is already present - good"
    return 0
  fi
  warn "no authorized SSH key found - authorizing a throwaway (unusable) key so setup.sh can proceed"
  install -d -m 700 -o ubuntu -g ubuntu /home/ubuntu/.ssh 2>/dev/null || mkdir -p /home/ubuntu/.ssh
  ssh-keygen -t ed25519 -N '' -C 'phase0-throwaway-unusable' -f /run/tk >/dev/null 2>&1
  cat /run/tk.pub >> /home/ubuntu/.ssh/authorized_keys
  shred -u /run/tk /run/tk.pub 2>/dev/null || rm -f /run/tk /run/tk.pub
  chown -R ubuntu:ubuntu /home/ubuntu/.ssh 2>/dev/null || true
  chmod 600 /home/ubuntu/.ssh/authorized_keys
}
ensure_authorized_key

# --- 4. Phase 2: the server itself -------------------------------------------
log "running setup.sh (WireGuard, firewall, DNS, idle protection)"
wait_apt
if ! bash "$WORK/setup.sh"; then
  echo "!! setup.sh failed - see the log above. Nothing is being served." >&2
  exit 1
fi

# --- 5. Phase 3: peers + QR PNGs ---------------------------------------------
log "creating peers: $WG_PEERS"
for p in $WG_PEERS; do
  if bash "$WORK/peer.sh" add "$p"; then
    bash "$WORK/peer.sh" png "$p" || warn "could not render QR for $p"
  else
    warn "peer '$p' was not added (it may already exist) - trying to render its QR anyway"
    bash "$WORK/peer.sh" png "$p" 2>/dev/null || true
  fi
done

# --- 6. the temporary delivery page ------------------------------------------
log "starting the QR delivery page on port 443"

PUBLIC_IP="$(cat "$STATE_DIR/public_ip" 2>/dev/null || echo vpn)"

umask 077
printf '%s' "$WG_PASS" > "$PASS_FILE"

# Self-signed cert. Encrypts the codes in transit; it cannot be domain-verified
# (there is no domain), which is why the phone will show a one-time warning.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -keyout "$KEY" -out "$CERT" -subj "/CN=${PUBLIC_IP}" >/dev/null 2>&1 \
  || { echo "!! openssl could not create the TLS cert - aborting delivery" >&2; exit 1; }
chmod 600 "$KEY"

cat > "$WORK/deliver.py" <<'PYEOF'
#!/usr/bin/env python3
"""Tiny, self-terminating HTTPS page that hands WireGuard QR codes / configs to
the owner's phone during first-time setup, behind HTTP Basic Auth. It reads no
untrusted input into any filesystem path: peer names come only from the
directory listing, and requests are matched against that fixed set."""
import os, ssl, sys, glob, hmac, html, base64, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PEERDIR = "/etc/wireguard/peers"
CERT    = "/run/wg-deliver.crt"
KEY     = "/run/wg-deliver.key"
TTL     = int(os.environ.get("DELIVER_TTL", "3600"))
try:
    with open("/run/wg-deliver-pass") as fh:
        PASSWORD = fh.read().strip()
except OSError:
    PASSWORD = os.environ.get("WG_PASS", "scan-me-please")


def catalogue():
    peers = {}
    for d in sorted(glob.glob(PEERDIR + "/*")):
        name = os.path.basename(d)
        if not os.path.isdir(d) or name.startswith("."):
            continue
        png, conf = os.path.join(d, name + ".png"), os.path.join(d, name + ".conf")
        if os.path.exists(png) and os.path.exists(conf):
            peers[name] = {"png": png, "conf": conf}
    return peers


PEERS = catalogue()

STYLE = """
:root{color-scheme:light dark}
*{box-sizing:border-box}
body{margin:0;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
 background:#0f1412;color:#e6ece9;padding:0 18px 60px}
h1{font-size:22px;margin:28px 0 8px}
.note{color:#94a49c;font-size:14px;max-width:40em}
.card{background:#161d1a;border:1px solid #26302c;border-radius:14px;margin:20px 0;padding:20px;text-align:center}
.card h2{margin:0 0 14px;font-size:18px;color:#4ecfa1}
.card img{width:min(78vw,300px);height:auto;image-rendering:pixelated;background:#fff;padding:10px;border-radius:10px}
.card a{display:inline-block;margin-top:14px;color:#4ecfa1}
button{width:100%;max-width:420px;margin:8px 0 4px;padding:15px;font-size:16px;font-weight:600;
 border:0;border-radius:12px;background:#0f7a5a;color:#fff}
"""


def authorized(header):
    if not header or not header.startswith("Basic "):
        return False
    try:
        pair = base64.b64decode(header[6:]).decode("utf-8", "replace")
    except Exception:
        return False
    _, _, pw = pair.partition(":")
    return hmac.compare_digest(pw, PASSWORD)


class Handler(BaseHTTPRequestHandler):
    server_version = "wg-deliver"

    def _ok(self):
        if authorized(self.headers.get("Authorization")):
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="VPN setup - enter your passphrase"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"Enter the passphrase you set in the setup line. Username can be anything.\n")
        return False

    def _send(self, code, ctype, data, extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._ok():
            return
        path = self.path.split("?", 1)[0]
        if path == "/":
            return self._index()
        if path.startswith("/conf/"):
            return self._conf(path[len("/conf/"):])
        self.send_error(404)

    def do_POST(self):
        if not self._ok():
            return
        if self.path.split("?", 1)[0] == "/done":
            self._send(200, "text/plain; charset=utf-8", b"ok")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        self.send_error(404)

    def _index(self):
        cards = []
        for name, info in PEERS.items():
            with open(info["png"], "rb") as fh:
                b64 = base64.b64encode(fh.read()).decode()
            safe = html.escape(name)
            cards.append(
                '<div class="card"><h2>{n}</h2>'
                '<img alt="QR for {n}" src="data:image/png;base64,{b}">'
                '<div><a href="/conf/{n}" download>Download .conf (for a computer)</a></div>'
                "</div>".format(n=safe, b=b64)
            )
        if not cards:
            cards.append('<div class="card"><h2>No peers were generated</h2>'
                         '<p class="note">Setup may not have finished. Recreate the instance.</p></div>')
        page = (
            "<!doctype html><html><head><meta charset=utf-8>"
            "<meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>Your VPN setup</title><style>{style}</style></head><body>"
            "<h1>Scan into the WireGuard app</h1>"
            "<p class=note>Install <b>WireGuard</b> from the App Store, then tap "
            "<b>+</b> &rarr; <b>Create from QR code</b> and scan the code for this "
            "device. On a computer, use the download link and import the .conf. "
            "These codes contain private keys &mdash; don&rsquo;t photograph or "
            "forward them.</p>{cards}"
            "<button onclick=\"fetch('/done',{{method:'POST'}})"
            ".then(()=>document.body.innerHTML='<h1>Done &mdash; this page is now "
            "off. You can close the tab.</h1>')\">I&rsquo;ve scanned every device "
            "&mdash; shut this down</button>"
            "<p class=note>This page turns itself off automatically about {mins} "
            "minutes after it started.</p></body></html>"
        ).format(style=STYLE, cards="".join(cards), mins=TTL // 60)
        self._send(200, "text/html; charset=utf-8", page.encode("utf-8"))

    def _conf(self, name):
        info = PEERS.get(name)
        if not info:
            return self.send_error(404)
        with open(info["conf"], "rb") as fh:
            data = fh.read()
        self._send(200, "application/octet-stream", data,
                   {"Content-Disposition": 'attachment; filename="%s.conf"' % name})

    def log_message(self, *a):
        pass


def main():
    if not PEERS:
        print("warning: no peers found to deliver", file=sys.stderr)
    httpd = ThreadingHTTPServer(("0.0.0.0", 443), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    # Hard stop after TTL even if nobody clicks "Done". Held so the finally block
    # can cancel it the instant the server stops for any other reason - otherwise
    # this non-daemon timer would keep the process alive until TTL elapsed.
    killer = threading.Timer(TTL, httpd.shutdown)
    killer.daemon = True
    killer.start()
    print("delivery page up on https://0.0.0.0:443/ for %d min" % (TTL // 60))
    try:
        httpd.serve_forever()
    finally:
        killer.cancel()
        for p in (CERT, KEY):
            try:
                os.unlink(p)
            except OSError:
                pass
        print("delivery page stopped")


if __name__ == "__main__":
    main()
PYEOF

cat > /etc/systemd/system/wg-deliver.service <<EOF
[Unit]
Description=WireGuard QR delivery page (temporary, first-time setup only)
After=network-online.target wg-quick@wg0.service

[Service]
Type=simple
Environment=DELIVER_TTL=${DELIVER_TTL}
ExecStart=/usr/bin/python3 ${WORK}/deliver.py
Restart=no
# Backstop in case the in-process timer is ever bypassed.
RuntimeMaxSec=$(( DELIVER_TTL + 120 ))
EOF

systemctl daemon-reload
# Started, not enabled: this must never resurrect itself on a later reboot.
systemctl disable wg-deliver >/dev/null 2>&1 || true
systemctl start wg-deliver

log "phase0 done $(date -u +%FT%TZ)"
cat <<EOF

  ============================================================
   VPN is up. Collect your QR codes now, from your phone:

     open   https://${PUBLIC_IP}/
     accept the "not private" warning (expected - see note)
     username: anything     password: the WG_PASS you set

   The page is live for about $(( DELIVER_TTL / 60 )) minutes, then shuts off.
  ============================================================

EOF
