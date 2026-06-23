#!/usr/bin/env bash
# Biweekly usage feedback to TRC: aggregate incident log (tpu_stats.sh) → email body.
# If this machine has mail/msmtp and TRC_EMAIL is set, send directly; otherwise save the body to a file for manual pasting.
#
# Usage:
#   TRC_EMAIL=trc-support@google.com ./scripts/trc_biweekly_report.sh
# As a scheduled job (cron has no native biweekly; use the 1st/15th of each month ≈ biweekly):
#   0 9 1,15 * * cd /path/to/tpu-trc-quickstart && TRC_EMAIL=trc-support@google.com ./scripts/trc_biweekly_report.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
TRC_EMAIL="${TRC_EMAIL:-trc-support@google.com}"
DATE="$(date +%Y-%m-%d)"
OUT="${TRC_REPORT_OUT:-$HOME/.tpu_trc_report_${DATE}.txt}"
SUBJECT="TRC TPU usage feedback ${DATE}"

# Generate the body (tpu_stats.sh output = claim count / anomalies by category / capacity stockout by zone)
{
  echo "Hi TRC team,"
  echo
  echo "Biweekly TPU usage + capacity feedback below (auto-generated from queue/preemption incident log)."
  echo
  if [ -x "$HERE/tpu_stats.sh" ]; then
    bash "$HERE/tpu_stats.sh" 2>/dev/null || echo "(no incidents logged this period)"
  else
    echo "(tpu_stats.sh not found — nothing to aggregate)"
  fi
  echo
  echo "-- auto-sent by tpu-trc-quickstart biweekly routine"
} > "$OUT"

# If mail exists, send directly; otherwise prompt for manual handling
if command -v mail >/dev/null 2>&1 && [ -n "$TRC_EMAIL" ]; then
  if mail -s "$SUBJECT" "$TRC_EMAIL" < "$OUT"; then
    echo "✓ Sent to $TRC_EMAIL (body backed up at $OUT)"
  else
    echo "⚠️ mail send failed — body is at $OUT, paste it manually to $TRC_EMAIL (or Discord #tpu-research-cloud)"
  fi
else
  echo "No mail/msmtp on this machine — body generated: $OUT"
  echo "Paste it manually to $TRC_EMAIL (or Discord #tpu-research-cloud)"
fi
