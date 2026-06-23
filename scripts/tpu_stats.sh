#!/bin/bash
# tpu_stats.sh — aggregate the incident log into a summary you can paste straight to Google TRC
# Usage: ./tpu_stats.sh [incident_log path]  (defaults to TPU_INCIDENT_LOG from resources.conf)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${TPU_CONF:-$SCRIPT_DIR/../resources.conf}"
[ -f "$CONF" ] && . "$CONF"
LOGF="${1:-${TPU_INCIDENT_LOG:-$HOME/.tpu_trc_incidents.tsv}}"

if [ ! -f "$LOGF" ]; then
  echo "no incident log: $LOGF (no data accumulated yet, or TPU_INCIDENT_LOG is off)"; exit 0
fi

awk -F'\t' '
  NR==1 && $1=="iso_time" { next }
  {
    n++
    if (first=="") first=$1
    last=$1
    cat[$5]++; ev[$2]++
    if ($5=="capacity-stockout") capzone[$4]++
    if ($2=="SUSPENDED")          preempt[$4]++
    if ($2=="CLAIMED")            claimed++
    if ($5=="billing-permission") blocked++
    if ($5=="quota-not-granted")  noquota[$4]++
  }
  END {
    if (n==0) { print "(log is empty)"; exit }
    print "=== TPU TRC incident summary (this machine) ==="
    print "range: " first "  ~  " last
    print "total records: " n "  | CLAIMED successfully: " claimed+0 "  | project-level blocks: " blocked+0
    print ""
    print "by category:"
    for (c in cat) printf "  %-22s %d\n", c, cat[c]
    print ""
    print "capacity stockout by zone (TRC cares most — which zone has no capacity):"
    for (z in capzone) printf "  %-20s %d times\n", z, capzone[z]
    if (length(preempt)>0) { print ""; print "spot preemption by zone:"; for (z in preempt) printf "  %-20s %d times\n", z, preempt[z] }
    if (length(noquota)>0) { print ""; print "quota not granted by zone:"; for (z in noquota) printf "  %-20s %d times\n", z, noquota[z] }
    print ""
    print "(see log for raw details; you can send the whole thing to trc-support@google.com or attach it in TRC feedback)"
  }
' "$LOGF"
echo ""
echo "log: $LOGF"
