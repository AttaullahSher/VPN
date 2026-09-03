#!/usr/bin/env bash
# =============================================================================
# cloudshell-phase0.sh - one command, from OCI Cloud Shell, that creates the
# free AMD instance with the ENTIRE VPN setup baked into cloud-init.
#
# Why this exists: the console's "Run command" agent turned out to be unable to
# execute on the instance (it accepts a command and never runs it). cloud-init
# is a completely separate mechanism - it runs at first boot as part of the OS,
# with no dependency on that agent - so this is the reliable path.
#
# Run it in Cloud Shell (the >_ icon in the console top bar):
#
#   curl -fsSL https://raw.githubusercontent.com/AttaullahSher/VPN/main/oracle/cloudshell-phase0.sh | bash
#
# It discovers your VCN's public subnet, the newest Ubuntu 24.04 image for the
# shape, and an availability domain; launches ONE VM.Standard.E2.1.Micro with a
# cloud-init that fetches and runs server/phase0-auto.sh; waits until it is
# RUNNING; and prints the public IP and the QR-page URL.
#
# Overridable:  WG_PASS (QR-page password), NAME, SHAPE, REPO_RAW
# =============================================================================
set -uo pipefail

C="${OCI_TENANCY:?not running inside OCI Cloud Shell (no OCI_TENANCY)}"
NAME="${NAME:-wg-vpn}"
SHAPE="${SHAPE:-VM.Standard.E2.1.Micro}"
WG_PASS="${WG_PASS:-scan-me-please}"
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/AttaullahSher/VPN/main}"
WORK="${WORK:-$HOME/wg}"
mkdir -p "$WORK"; cd "$WORK"

say(){ printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# --- the cloud-init the instance runs at first boot ---------------------------
# Runs as root under cloud-init, so no sudo is needed. Fetches phase0-auto.sh,
# which installs WireGuard etc. and serves the peer QR codes on https://<ip>/.
cat > user-data.sh <<EOF
#!/bin/bash
curl -fsSL ${REPO_RAW}/server/phase0-auto.sh -o /root/phase0.sh
WG_PASS='${WG_PASS}' bash /root/phase0.sh >>/var/log/wg-phase0.log 2>&1
EOF

# --- discover the pieces oci needs, so you don't have to paste any OCIDs ------
say "finding your network and image"
SUBNET="$(oci network subnet list -c "$C" --all 2>/dev/null \
  | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or []
pub=[s for s in d if not s.get("prohibit-public-ip-on-vnic")]
print((pub[0] if pub else d[0])["id"] if d else "")')"
[ -n "$SUBNET" ] || die "no subnet found in the root compartment - is the VCN created, and is Cloud Shell set to the UAE (Abu Dhabi) region?"

IMAGE="$(oci compute image list -c "$C" \
  --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' \
  --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data") or [];print(d[0]["id"] if d else "")')"
[ -n "$IMAGE" ] || die "no Ubuntu 24.04 image found for $SHAPE in this region"

mapfile -t ADS < <(oci iam availability-domain list -c "$C" 2>/dev/null \
  | python3 -c 'import sys,json;[print(a["name"]) for a in json.load(sys.stdin)["data"]]')
[ "${#ADS[@]}" -gt 0 ] || die "could not list availability domains"

say "launching $NAME  ($SHAPE)"
echo "    subnet : $SUBNET"
echo "    image  : $IMAGE"

# --- launch, retrying only on out-of-capacity (rare for this AMD shape) -------
OCID=""
for attempt in 1 2 3 4 5; do
  for AD in "${ADS[@]}"; do
    OUT="$(oci compute instance launch \
        --compartment-id "$C" \
        --availability-domain "$AD" \
        --shape "$SHAPE" \
        --image-id "$IMAGE" \
        --subnet-id "$SUBNET" \
        --assign-public-ip true \
        --display-name "$NAME" \
        --user-data-file user-data.sh \
        --wait-for-state RUNNING 2>&1)" && {
      OCID="$(printf '%s' "$OUT" | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["data"]["id"])
except Exception: print("")' 2>/dev/null)"
      [ -n "$OCID" ] && break 2
    }
    if printf '%s' "$OUT" | grep -qiE 'capacity|LimitExceeded|too many requests'; then
      echo "    $AD: no capacity right now, trying next..."
      continue
    fi
    # A real error (not capacity): show it and stop.
    printf '%s\n' "$OUT" >&2
    die "launch failed for a reason other than capacity (see above)"
  done
  echo "    all ADs full on attempt $attempt; waiting 60s..."
  sleep 60
done
[ -n "$OCID" ] || die "could not get capacity after several attempts - try again in a few minutes"

# --- fetch the public IP ------------------------------------------------------
IP=""
for _ in 1 2 3 4 5 6; do
  IP="$(oci compute instance list-vnics --instance-id "$OCID" 2>/dev/null \
    | python3 -c 'import sys,json
d=json.load(sys.stdin).get("data") or []
print(d[0].get("public-ip","") if d else "")' 2>/dev/null)"
  [ -n "$IP" ] && break
  sleep 5
done

say "done"
cat <<EOF

  ===================================================================
   The server is RUNNING and configuring itself now.

     Wait about 5 minutes, then open on your phone:

        https://${IP:-<check the console for the public IP>}/

     Tap through the "Not Private" warning (expected), then log in:
        username: anything     password: ${WG_PASS}

     Scan the QR into the WireGuard app. Done.
  ===================================================================

  (You can delete the old, stuck "wg-vpn" instance afterwards - this is
   a fresh one. Two free micro instances are allowed, so both can coexist.)

EOF
