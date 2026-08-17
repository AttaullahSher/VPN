#!/usr/bin/env bash
# =============================================================================
# egress.sh - month-to-date outbound traffic vs. Oracle's 10 TB/month free cap.
#
# Oracle bills OUTBOUND (egress) from the instance to the internet. Inbound is
# free. The Always Free allowance is 10 TB per month across the tenancy.
#   bash egress.sh
# =============================================================================
set -uo pipefail

STATE_DIR=/var/lib/wg-oracle
WAN_IF="$(cat "$STATE_DIR/wan_if" 2>/dev/null || ip -4 route show default | awk '{print $5; exit}')"
CAP_TB=10
CAP_BYTES=$(( CAP_TB * 1000 * 1000 * 1000 * 1000 ))

command -v vnstat >/dev/null 2>&1 || { echo "vnstat not installed (apt-get install -y vnstat)"; exit 1; }

# vnstat's JSON gives exact byte counts for the current month.
TX="$(vnstat -i "$WAN_IF" --json m 2>/dev/null \
      | jq -r '[.interfaces[0].traffic.month[]] | last | .tx' 2>/dev/null)"
RX="$(vnstat -i "$WAN_IF" --json m 2>/dev/null \
      | jq -r '[.interfaces[0].traffic.month[]] | last | .rx' 2>/dev/null)"

if [ -z "${TX:-}" ] || [ "$TX" = "null" ]; then
  echo "  vnstat has not collected a full month yet - showing live interface counters instead."
  TX="$(cat "/sys/class/net/$WAN_IF/statistics/tx_bytes")"
  RX="$(cat "/sys/class/net/$WAN_IF/statistics/rx_bytes")"
  echo "  (these reset on reboot; vnstat's figures become authoritative within a day)"
fi

PCT=$(awk -v t="$TX" -v c="$CAP_BYTES" 'BEGIN{printf "%.3f", t*100/c}')
DAY=$(date +%-d); DIM=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%-d)
PROJ=$(awk -v t="$TX" -v d="$DAY" -v m="$DIM" 'BEGIN{printf "%.0f", t/d*m}')
PROJPCT=$(awk -v p="$PROJ" -v c="$CAP_BYTES" 'BEGIN{printf "%.2f", p*100/c}')

printf '  Interface        : %s\n' "$WAN_IF"
printf '  Month to date    : egress %s  |  ingress %s\n' \
  "$(numfmt --to=si --suffix=B "$TX")" "$(numfmt --to=si --suffix=B "$RX")"
printf '  Free cap         : %s TB egress/month\n' "$CAP_TB"
printf '  Used             : %s%% of the cap\n' "$PCT"
printf '  Projected (day %s of %s): %s = %s%% of the cap\n' \
  "$DAY" "$DIM" "$(numfmt --to=si --suffix=B "$PROJ")" "$PROJPCT"
awk -v p="$PROJPCT" 'BEGIN{ if (p+0 > 80) print "  \033[1;31m** projected to exceed 80% of the free cap **\033[0m";
                            else print "  Comfortably inside the free tier." }'
echo
echo "  Authoritative figure: OCI Console -> Billing & Cost Management -> Cost Analysis,"
echo "  filter service = 'Networking'. vnstat above is the on-host view and matches closely."
