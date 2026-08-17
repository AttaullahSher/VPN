#!/usr/bin/env bash
# =============================================================================
# "Out of host capacity" workaround - run in OCI Cloud Shell.
#
# Free-tier Ampere (A1) capacity is released in small bursts as other people
# delete instances. Clicking "Create" by hand almost never catches one. This
# retries the launch every 60 seconds until it succeeds, then prints the IP.
#
# Leave the Cloud Shell tab open. It usually lands within a few hours; some
# regions take a day or two.
#
#   OCPUS=2 MEMGB=12 bash cloudshell-launch-retry.sh
# =============================================================================
set -uo pipefail

COMPARTMENT="${COMPARTMENT:-${OCI_TENANCY:?run this inside OCI Cloud Shell}}"
NAME="${NAME:-wg-vpn}"
OCPUS="${OCPUS:-2}"
MEMGB="${MEMGB:-12}"
SLEEP="${SLEEP:-60}"
SSH_PUB_FILE="${SSH_PUB_FILE:-$HOME/wg-key.pub}"
CLOUD_INIT_FILE="${CLOUD_INIT_FILE:-$HOME/bootstrap.yaml}"

[ -r "$SSH_PUB_FILE" ]     || { echo "missing $SSH_PUB_FILE (put the SSH public key there)"; exit 1; }
[ -r "$CLOUD_INIT_FILE" ]  || { echo "missing $CLOUD_INIT_FILE (put the cloud-init YAML there)"; exit 1; }

echo "==> discovering subnet, availability domains and the newest Ubuntu 24.04 ARM image..."
SUBNET_ID="$(oci network subnet list -c "$COMPARTMENT" --all --query 'data[0].id' --raw-output)"
IMAGE_ID="$(oci compute image list -c "$COMPARTMENT" \
            --operating-system 'Canonical Ubuntu' --operating-system-version '24.04' \
            --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC \
            --query 'data[0].id' --raw-output)"
mapfile -t ADS < <(oci iam availability-domain list -c "$COMPARTMENT" --query 'data[].name' --raw-output | tr -d '[]", ' | grep -v '^$')

[ -n "$SUBNET_ID" ] || { echo "no subnet - create the VCN first"; exit 1; }
[ -n "$IMAGE_ID" ]  || { echo "no Ubuntu 24.04 ARM image found"; exit 1; }
echo "    subnet : $SUBNET_ID"
echo "    image  : $IMAGE_ID"
echo "    ADs    : ${ADS[*]}"

USERDATA="$(base64 -w0 < "$CLOUD_INIT_FILE")"
ATTEMPT=0
while :; do
  for AD in "${ADS[@]}"; do
    ATTEMPT=$((ATTEMPT+1))
    printf '[%s] attempt %d in %s ... ' "$(date +%H:%M:%S)" "$ATTEMPT" "$AD"
    OUT="$(oci compute instance launch \
        --compartment-id "$COMPARTMENT" \
        --availability-domain "$AD" \
        --shape VM.Standard.A1.Flex \
        --shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMGB}}" \
        --image-id "$IMAGE_ID" \
        --subnet-id "$SUBNET_ID" \
        --assign-public-ip true \
        --display-name "$NAME" \
        --metadata "{\"ssh_authorized_keys\":\"$(sed 's/"/\\"/g' "$SSH_PUB_FILE" | tr -d '\n')\",\"user_data\":\"${USERDATA}\"}" \
        --wait-for-state RUNNING 2>&1)"
    if grep -q '"lifecycle-state": *"RUNNING"' <<<"$OUT"; then
      echo "SUCCESS"
      ID="$(grep -o '"id": *"ocid1.instance[^"]*"' <<<"$OUT" | head -1 | cut -d'"' -f4)"
      echo
      echo "  instance : $ID"
      echo "  public IP: $(oci compute instance list-vnics --instance-id "$ID" --query 'data[0]."public-ip"' --raw-output)"
      exit 0
    fi
    if grep -qi 'out of host capacity\|LimitExceeded\|InternalError' <<<"$OUT"; then
      echo "no capacity"
    else
      echo "FAILED (not a capacity error):"; echo "$OUT" | tail -20; exit 1
    fi
  done
  sleep "$SLEEP"
done
