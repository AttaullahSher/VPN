#!/usr/bin/env bash
# =============================================================================
# Run this in OCI Cloud Shell (the >_ icon in the console header).
#
# It finds the security list attached to your instance's subnet and adds two
# ingress rules, without you having to navigate the console on a phone:
#     UDP 51820  from 0.0.0.0/0   -> WireGuard
#     TCP   443  from 0.0.0.0/0   -> SSH-over-443 for remote setup
#
# Idempotent: re-running it will not create duplicates.
# =============================================================================
set -euo pipefail

COMPARTMENT="${COMPARTMENT:-${OCI_TENANCY:?run this inside OCI Cloud Shell}}"
WG_PORT="${WG_PORT:-51820}"

echo "==> locating your VCN subnet..."
SUBNET_ID="$(oci network subnet list -c "$COMPARTMENT" --all \
             --query 'data[0].id' --raw-output)"
[ -n "$SUBNET_ID" ] && [ "$SUBNET_ID" != "null" ] || { echo "no subnet found"; exit 1; }

SL_ID="$(oci network subnet get --subnet-id "$SUBNET_ID" \
         --query 'data."security-list-ids"[0]' --raw-output)"
echo "    subnet        : $SUBNET_ID"
echo "    security list : $SL_ID"

echo "==> reading current ingress rules..."
oci network security-list get --security-list-id "$SL_ID" \
  --query 'data."ingress-security-rules"' > /tmp/ingress.json

echo "==> adding UDP $WG_PORT and TCP 443 (skipping any that already exist)..."
python3 - "$WG_PORT" <<'PY' > /tmp/ingress-new.json
import json, sys
port = int(sys.argv[1])
rules = json.load(open('/tmp/ingress.json'))

def have(proto, p):
    for r in rules:
        if r.get('protocol') != proto:
            continue
        opts = r.get('udp-options') if proto == '17' else r.get('tcp-options')
        if not opts:
            continue
        dst = opts.get('destination-port-range') or {}
        if dst.get('min') == p and dst.get('max') == p:
            return True
    return False

def mk(proto, p, desc):
    key = 'udp-options' if proto == '17' else 'tcp-options'
    return {
        "protocol": proto, "source": "0.0.0.0/0", "source-type": "CIDR_BLOCK",
        "is-stateless": False, "description": desc,
        key: {"destination-port-range": {"min": p, "max": p}},
    }

added = []
if not have('17', port):
    rules.append(mk('17', port, 'WireGuard VPN')); added.append(f'UDP {port}')
if not have('6', 443):
    rules.append(mk('6', 443, 'SSH over 443 (remote setup)')); added.append('TCP 443')

json.dump(rules, open('/tmp/ingress-new.json', 'w'))
print(', '.join(added) if added else 'nothing to add - both rules already present',
      file=sys.stderr)
PY

oci network security-list update --security-list-id "$SL_ID" \
  --ingress-security-rules file:///tmp/ingress-new.json --force >/dev/null

echo "==> done. Current ingress rules:"
oci network security-list get --security-list-id "$SL_ID" \
  --query 'data."ingress-security-rules"[].{protocol:protocol,source:source,tcp:"tcp-options",udp:"udp-options"}' \
  --output table
