#!/usr/bin/env bash
# =============================================================================
# Create the VPN instance from OCI Cloud Shell, instead of the console form.
#
# Discovers the subnet, the newest Ubuntu 24.04 ARM image and every availability
# domain by itself, then launches VM.Standard.A1.Flex and RETRIES on "Out of
# host capacity" until it lands. Prints the public IP when it succeeds.
#
# Prerequisite: a VCN must exist (Networking -> Virtual Cloud Networks ->
# Start VCN Wizard -> "VCN with Internet Connectivity").
#
#   bash cloudshell-launch-retry.sh
#   OCPUS=2 MEMGB=12 bash cloudshell-launch-retry.sh   # bigger, lands less often
# =============================================================================
set -uo pipefail

C="${OCI_TENANCY:?not running inside OCI Cloud Shell}"
NAME="${NAME:-wg-vpn}"
OCPUS="${OCPUS:-1}"
MEMGB="${MEMGB:-6}"
WORK="${WORK:-$HOME/wg}"
mkdir -p "$WORK"; cd "$WORK"

# --- the SSH public keys that will be authorised on the instance ---
# NEVER overwrite an existing key.pub. Whoever seeded it put the key they
# actually hold the private half of in there; replacing it would launch an
# instance that nobody can log in to, and the only fix is to destroy and
# relaunch - which means queueing for scarce Ampere capacity all over again.
if [ ! -s key.pub ]; then
  if [ -n "${KEYFILE:-}" ] && [ -s "$KEYFILE" ]; then
    cp "$KEYFILE" key.pub
  else
    cat >&2 <<MSG
!! $WORK/key.pub is missing or empty, and no KEYFILE was given.

   Put YOUR OWN SSH public key there first - the one whose private half is on
   the machine you will SSH from:

     cat > $WORK/key.pub <<'EOF'
     ssh-ed25519 AAAA...your key... you@your-pc
     EOF

   Launching without it creates an instance you cannot get into.
MSG
    exit 1
  fi
fi

echo "==> these keys will be authorised on the instance:"
ssh-keygen -l -f key.pub 2>/dev/null | sed 's/^/    /' \
  || { echo "!! key.pub is not a valid SSH public key file"; exit 1; }
echo "    ^ at least one of these fingerprints must be a key YOU hold."
echo

# --- first-boot config: add SSH on 443 as a fallback path in ---
# Harmless if unused. Written only if absent, so a hand-edited one survives.
[ -s bootstrap.yaml ] || cat > bootstrap.yaml <<'CI_EOF'
#cloud-config
write_files:
  - path: /etc/systemd/system/ssh.socket.d/99-alt-port.conf
    permissions: '0644'
    content: |
      [Socket]
      ListenStream=
      ListenStream=22
      ListenStream=443
  - path: /etc/ssh/sshd_config.d/99-alt-port.conf
    permissions: '0644'
    content: |
      Port 22
      Port 443
runcmd:
  - [ sh, -c, "iptables -C INPUT -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -p tcp --dport 443 -m conntrack --ctstate NEW -j ACCEPT" ]
  - [ sh, -c, "netfilter-persistent save || true" ]
  - [ systemctl, daemon-reload ]
  - [ sh, -c, "systemctl restart ssh.socket 2>/dev/null || systemctl restart ssh || true" ]
CI_EOF

echo "==> discovering subnet, image and availability domains..."

SUBNET="$(oci network subnet list -c "$C" --all 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data") or [];print(d[0]["id"] if d else "")')"
if [ -z "$SUBNET" ]; then
  echo "!! No subnet found. Create the network first:"
  echo "   Networking -> Virtual Cloud Networks -> Start VCN Wizard"
  echo "   -> 'Create VCN with Internet Connectivity' -> name it 'vpn-vcn' -> Next -> Create"
  exit 1
fi

IMAGE="$(oci compute image list -c "$C" \
  --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' \
  --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC 2>/dev/null \
  | python3 -c 'import sys,json;d=json.load(sys.stdin).get("data") or [];print(d[0]["id"] if d else "")')"
[ -n "$IMAGE" ] || { echo "!! No Ubuntu 24.04 ARM image found in this region."; exit 1; }

mapfile -t ADS < <(oci iam availability-domain list -c "$C" 2>/dev/null \
  | python3 -c 'import sys,json;[print(a["name"]) for a in json.load(sys.stdin)["data"]]')
[ "${#ADS[@]}" -gt 0 ] || { echo "!! Could not list availability domains."; exit 1; }

# Build the metadata blob in Python so quoting and base64 cannot go wrong.
python3 - <<'PY'
import base64, json
json.dump({
    "ssh_authorized_keys": open("key.pub").read().strip(),
    "user_data": base64.b64encode(open("bootstrap.yaml","rb").read()).decode(),
}, open("metadata.json","w"))
PY

echo "    subnet : $SUBNET"
echo "    image  : $IMAGE"
echo "    ADs    : ${ADS[*]}"
echo "    shape  : VM.Standard.A1.Flex  ${OCPUS} OCPU / ${MEMGB} GB"
echo
echo "==> launching. Capacity errors are expected; this retries every ${SLEEP}s."
echo "    Leave this tab open. Ctrl-C to stop."
echo

ATTEMPT=0
BASE="${BASE:-90}"        # seconds between ordinary capacity retries
BACKOFF="$BASE"           # grows when Oracle rate-limits us
MAXBACKOFF=900

while :; do
  for AD in "${ADS[@]}"; do
    ATTEMPT=$((ATTEMPT+1))
    printf '[%s] attempt %-4d %s ... ' "$(date +%H:%M:%S)" "$ATTEMPT" "$AD"
    OUT="$(oci compute instance launch \
        --compartment-id "$C" \
        --availability-domain "$AD" \
        --shape VM.Standard.A1.Flex \
        --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMGB}}" \
        --image-id "$IMAGE" \
        --subnet-id "$SUBNET" \
        --assign-public-ip true \
        --display-name "$NAME" \
        --metadata file://metadata.json \
        --wait-for-state RUNNING 2>&1)"

    if printf '%s' "$OUT" | grep -q '"lifecycle-state": *"RUNNING"'; then
      echo "SUCCESS"
      ID="$(printf '%s' "$OUT" | grep -o '"id": *"ocid1\.instance[^"]*"' | head -1 | cut -d'"' -f4)"
      IP="$(oci compute instance list-vnics --instance-id "$ID" 2>/dev/null \
            | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"];print(d[0].get("public-ip",""))')"
      echo
      echo "  =========================================="
      echo "   Instance is RUNNING"
      echo "   Public IP: $IP"
      echo "  =========================================="
      echo
      echo "  Send that IP back to continue with Phase 2."
      exit 0
    fi

    # 429. Oracle throttles launch_instance per user, and retrying through a
    # throttle makes it worse - so back off exponentially and reset once a
    # normal capacity answer comes back.
    if printf '%s' "$OUT" | grep -qi 'TooManyRequests\|"status": *429'; then
      BACKOFF=$(( BACKOFF * 2 ))
      [ "$BACKOFF" -gt "$MAXBACKOFF" ] && BACKOFF="$MAXBACKOFF"
      echo "rate limited - backing off ${BACKOFF}s"
      sleep "$BACKOFF"
      continue
    fi

    if printf '%s' "$OUT" | grep -qiE 'out of host capacity|LimitExceeded|InternalError|ServiceUnavailable'; then
      BACKOFF="$BASE"
      echo "no capacity"
      sleep "$BASE"
      continue
    fi

    echo "FAILED - this is not a capacity or throttling error:"
    printf '%s\n' "$OUT" | tail -25
    exit 1
  done
done
