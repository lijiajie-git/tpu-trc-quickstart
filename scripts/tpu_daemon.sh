#!/bin/bash
# tpu_daemon.sh — TRC TPU grab daemon (generic, conf-driven)
#
# Single process: poll queue → claim on grab → cancel surplus requests → health check (no dependency install) → optional user hook.
#   - Every 30s scan VM; READY → health + SSH (+ optional job liveness) → claim → write marker → cancel loser → setup
#   - Every 10min scan QR; FAILED routed by root cause, SUSPENDED/true MISSING → requeue (transient failures not mis-deleted)
#
# Usage: cp resources.conf.template resources.conf && fill in → nohup ./scripts/tpu_daemon.sh &
# Stop: kill $(cat /tmp/tpu_daemon.pid)
# Exit codes: 0=grabbed+configured / 1=preflight failed / 2=timeout / 3=project-level block / 4=claimed but config incomplete
#
# Safety (adversarial-audit hardening): assert_owned uses conf's TPU_OWNER_PATTERN (empty/`*` refuses to start); describe
# transient failure ≠ resource gone (UNKNOWN→noop, recheck whether VM is alive before deleting); deferred cancellations are consumed at startup;
# optional TPU_BUSY_PATTERN: if a matching process is running on the VM, do not take over (prevents setup from disturbing a running job).
#
# macOS stock bash 3.2: no declare -A, no set -e, only set -u.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="${TPU_CONF:-$SCRIPT_DIR/../resources.conf}"
if [ -f "$CONF" ]; then
  . "$CONF"
else
  echo "FATAL: resources.conf missing: $CONF (first cp resources.conf.template resources.conf and fill in)" >&2
  exit 1
fi

GCLOUD="${GCLOUD:-$(command -v gcloud || echo /opt/homebrew/bin/gcloud)}"
ACCOUNT="${ACCOUNT:-$TPU_ACCOUNT}"
PROJECT="${PROJECT:-$TPU_PROJECT}"
OWNER_PAT="${TPU_OWNER_PATTERN:-}"
BUSY_PAT="${TPU_BUSY_PATTERN:-}"          # optional: do not take over if this process is running on the VM (empty = no check)
INCIDENT_LOG="${TPU_INCIDENT_LOG:-}"      # incident registry TSV (empty = no logging)
QR_VALID_DUR="${TPU_QR_VALID_DURATION:-}" # QR lifetime (official --valid-until-duration, empty = not set)

LOG=/tmp/tpu_daemon.log;        PIDFILE=/tmp/tpu_daemon.pid
FLAG=/tmp/tpu_claimed.flag;     SETUP_LOG=/tmp/tpu_setup.log
SSH_CMD_FILE=/tmp/tpu_ssh_cmd.txt
STOPFILE=/tmp/tpu_daemon.stop                 # kill touches it → daemon exits on seeing it, no longer recreates
DEFERRED=/tmp/tpu_deferred_cleanup;  BLOCKED=/tmp/tpu_blocked.marker

POLL_SEC=30; QR_EVERY=20; MAX_ITER=720; UNKNOWN_CAP=3

export CLOUDSDK_CORE_ACCOUNT="$ACCOUNT"
export CLOUDSDK_CORE_PROJECT="$PROJECT"

log() { echo "[$(date '+%m-%d %H:%M:%S')] $*" >> "$LOG"; }

notify() {  # cross-platform: macOS osascript/say, Linux notify-send
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$2\" with title \"$1\" sound name \"Glass\"" 2>>"$LOG" || true
    [ -n "${3:-}" ] && command -v say >/dev/null 2>&1 && { say "$3" 2>>"$LOG" & }
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$1" "$2" 2>>"$LOG" || true
  fi
  log "NOTIFY: $1 — $2"; return 0
}

f() { echo "$1" | cut -d'|' -f"$2"; }

# incident registry (for TRC stats): $1=event $2=accel_type $3=zone $4=category $5=action $6=raw_msg
log_incident() {
  [ -z "$INCIDENT_LOG" ] && return 0
  if [ ! -f "$INCIDENT_LOG" ]; then
    printf 'iso_time\tevent\taccel_type\tzone\tcategory\taction\traw_msg\n' > "$INCIDENT_LOG" 2>/dev/null || return 0
  fi
  local m; m=$(printf '%s' "${6:-}" | tr '\t\n' '  ' | cut -c1-200)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" "$3" "$4" "$5" "$m" >> "$INCIDENT_LOG" 2>/dev/null || true
}

assert_owned() {  # use conf's OWNER_PAT
  case "$1" in
    $OWNER_PAT) return 0 ;;
    *) log "REJECT not-own resource $1 (allowlist=$OWNER_PAT), refusing mutating"; return 1 ;;
  esac
}

preflight() {
  if [ ! -x "$GCLOUD" ]; then log "PREFLIGHT FAIL: gcloud not executable: $GCLOUD"; return 1; fi
  case "$ACCOUNT" in *"<"*|"") log "PREFLIGHT FAIL: resources.conf has no TPU_ACCOUNT filled in"; return 1 ;; esac
  case "$PROJECT" in *"<"*|"") log "PREFLIGHT FAIL: resources.conf has no TPU_PROJECT filled in"; return 1 ;; esac
  local act
  act=$("$GCLOUD" auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  if [ "$act" != "$ACCOUNT" ]; then
    log "PREFLIGHT FAIL: active account=$act expected=$ACCOUNT"
    notify "TPU preflight failed" "active account $act ≠ $ACCOUNT" "wrong account, stopped"; return 1
  fi
  log "PREFLIGHT OK: account=$act project=$PROJECT owner=$OWNER_PAT"
  return 0
}

vm_state()      { "$GCLOUD" alpha compute tpus tpu-vm describe "$2" --project="$PROJECT" --zone="$1" --account="$ACCOUNT" --format="value(state)" 2>/dev/null; }
vm_health()     { "$GCLOUD" alpha compute tpus tpu-vm describe "$2" --project="$PROJECT" --zone="$1" --account="$ACCOUNT" --format="value(health)" 2>/dev/null; }
vm_createtime() { "$GCLOUD" alpha compute tpus tpu-vm describe "$2" --project="$PROJECT" --zone="$1" --account="$ACCOUNT" --format="value(createTime)" 2>/dev/null; }
qr_raw()        { "$GCLOUD" alpha compute tpus queued-resources describe "$2" --project="$PROJECT" --zone="$1" --account="$ACCOUNT" 2>/dev/null; }

vm_gone() {  # 0 if describe confirms NOT_FOUND (truly gone) / 1 otherwise (present or transient failure)
  local err="/tmp/tpu_vmerr.$$" rc gone=1
  "$GCLOUD" alpha compute tpus tpu-vm describe "$2" --project="$PROJECT" --zone="$1" --account="$ACCOUNT" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] && grep -qiE "NOT_FOUND|was not found|does not exist" "$err" 2>/dev/null && gone=0
  rm -f "$err"; return "$gone"
}

ssh_probe() { "$GCLOUD" alpha compute tpus tpu-vm ssh "$2" --project="$PROJECT" --zone="$1" --worker=0 --tunnel-through-iap --account="$ACCOUNT" --ssh-flag="-o ConnectTimeout=15" --command="true" >/dev/null 2>&1; }

# ★ Beware pgrep -f self-match: `pgrep -f 'train.py'` matches the enclosing SSH shell (cmdline contains the literal
#   "train.py") → false positive. In conf, TPU_BUSY_PATTERN should use bracket form such as `[t]rain\.py`,
#   so the command line does not contain the literal pattern and only the real job matches. (see resources.conf.template note)
vm_has_job() {  # $1=zone $2=vm → 0 if BUSY_PAT process running on worker0 (BUSY_PAT empty → always 1 = no block)
  [ -z "$BUSY_PAT" ] && return 1
  "$GCLOUD" alpha compute tpus tpu-vm ssh "$2" --project="$PROJECT" --zone="$1" --worker=0 --tunnel-through-iap --account="$ACCOUNT" --ssh-flag="-o ConnectTimeout=15" --command="pgrep -f '$BUSY_PAT' >/dev/null 2>&1" >/dev/null 2>&1
}

qr_state_classified() {  # <state> / MISSING (confirmed non-existent) / UNKNOWN (describe failed, don't touch)
  local err out rc; err="/tmp/tpu_qrerr.$$"
  out=$("$GCLOUD" alpha compute tpus queued-resources describe "$2" --project="$PROJECT" --zone="$1" --account="$ACCOUNT" --format="value(state.state)" 2>"$err"); rc=$?
  if [ "$rc" -eq 0 ]; then echo "${out:-EMPTY}"
  elif grep -qiE "NOT_FOUND|was not found|does not exist|No.*queued resource" "$err" 2>/dev/null; then echo "MISSING"
  else echo "UNKNOWN"; fi
  rm -f "$err"
}

delete_until_missing() {  # 0 deleted clean / 1 timeout still present
  local zone="$1" qr="$2" i
  assert_owned "$qr" || return 1
  for i in $(seq 1 18); do
    if ! "$GCLOUD" alpha compute tpus queued-resources describe "$qr" --project="$PROJECT" --zone="$zone" --account="$ACCOUNT" >/dev/null 2>&1; then return 0; fi
    "$GCLOUD" alpha compute tpus queued-resources delete "$qr" --project="$PROJECT" --zone="$zone" --account="$ACCOUNT" --force --quiet --async >/dev/null 2>&1 || true
    sleep 10
  done
  log "  delete_until_missing timeout still present: $zone/$qr"; return 1
}

recreate_qr() {  # 0 ok / 1 delete not completed
  local e="$1" zone qr vm accel runtime provmodel iips extra
  zone=$(f "$e" 1); qr=$(f "$e" 2); vm=$(f "$e" 3)
  accel=$(f "$e" 4); runtime=$(f "$e" 5); provmodel=$(f "$e" 7); iips=$(f "$e" 8)
  assert_owned "$qr" || return 1
  log "ACTION recreate_qr $zone/$qr"
  delete_until_missing "$zone" "$qr" || { log "  delete not completed, skipping this round's create: $zone/$qr"; return 1; }
  extra=""
  [ "$provmodel" = "SPOT" ] && extra="--provisioning-model=SPOT"
  [ "$provmodel" = "guaranteed" ] && extra="--guaranteed"
  [ "$iips" = "yes" ] && extra="$extra --internal-ips"
  [ -n "$QR_VALID_DUR" ] && extra="$extra --valid-until-duration=$QR_VALID_DUR"   # official: QR lifetime, orphans self-clean
  "$GCLOUD" alpha compute tpus queued-resources create "$qr" \
    --node-id="$vm" --project="$PROJECT" --zone="$zone" --account="$ACCOUNT" \
    --accelerator-type="$accel" --runtime-version="$runtime" $extra >>"$LOG" 2>&1
}

recreate_guarded() {  # before requeue confirm VM is not alive (prevents transient failure from mis-deleting a live resource)
  local e="$1" zone vm vs
  zone=$(f "$e" 1); vm=$(f "$e" 3)
  vs=$(vm_state "$zone" "$vm")
  if [ "$vs" = "READY" ] || [ "$vs" = "ACTIVE" ]; then
    log "  $zone VM=$vs still alive, skip recreate (prevents mis-deleting live resource)"; return 0
  fi
  recreate_qr "$e"
}

classify_failed() {  # 0=capacity / 3=project-level / 4=per-zone quota / 1=unknown
  local raw; raw=$(qr_raw "$1" "$2")
  echo "$raw" | grep -qiE "no more capacity|GCE_STOCKOUT|ZONE_RESOURCE_POOL_EXHAUSTED|capacity in the zone" && return 0
  echo "$raw" | grep -qiE "PERMISSION_DENIED|billingEnabled.{0,12}false|NO_VALID_BILLING|check billing" && return 3
  echo "$raw" | grep -qiE "Limit: 0|RESOURCE_EXHAUSTED|quota.*exceed" && return 4
  return 1
}

cancel_losers() {  # $1=winning zone
  local win="$1" i e zone qr
  i=0
  while [ "$i" -lt "${#TARGETS[@]}" ]; do
    e="${TARGETS[$i]}"; zone=$(f "$e" 1); qr=$(f "$e" 2)
    if [ "$zone" != "$win" ] && assert_owned "$qr"; then
      log "ACTION cancel_loser $zone/$qr"
      "$GCLOUD" alpha compute tpus queued-resources delete "$qr" --project="$PROJECT" --zone="$zone" --account="$ACCOUNT" --force --quiet --async >>"$LOG" 2>&1 \
        || { log "  loser $zone/$qr cannot delete, recording deferred (cleaned at startup)"; echo "$zone|$qr" >> "$DEFERRED"; }
    fi
    i=$((i+1))
  done
}

consume_deferred() {
  [ -f "$DEFERRED" ] || return 0
  local tmp="$DEFERRED.tmp" dz dq
  : > "$tmp"
  while IFS='|' read -r dz dq; do
    [ -z "${dz:-}" ] && continue
    if assert_owned "$dq"; then
      if "$GCLOUD" alpha compute tpus queued-resources delete "$dq" --project="$PROJECT" --zone="$dz" --account="$ACCOUNT" --force --quiet >>"$LOG" 2>&1; then
        log "DEFERRED cleaned $dz/$dq"
      else echo "$dz|$dq" >> "$tmp"; fi
    fi
  done < "$DEFERRED"
  if [ -s "$tmp" ]; then mv "$tmp" "$DEFERRED"; else rm -f "$tmp" "$DEFERRED"; fi
}

# provision-only: after grabbing, only do a lightweight health check (16/16 SSH + chip + NAT), **by default install no dependencies**.
# What to install is up to you: SSH in and install yourself, or set TPU_SETUP_CMD in conf to have the daemon run your install command for you.
# (Pre-installing generic jax gives "false readiness", may cause version conflicts, and spot preemption is unrelated to busy/idle — pre-install cannot prevent preemption.)
generic_setup() {  # $1=zone $2=vm $3=workers → health check + optional user hook
  local zone="$1" vm="$2" wc="$3"
  : > "$SETUP_LOG"
  log "HEALTHCHECK: all-worker SSH + chip (vfio/accel) + NAT, install no dependencies"
  # --batch-size=8: 16 concurrent handshakes hit sshd MaxStartups (default 10:30:100) → intermittent 255; keep under 10
  "$GCLOUD" alpha compute tpus tpu-vm ssh "$vm" --project="$PROJECT" --zone="$zone" --account="$ACCOUNT" \
    --worker=all --batch-size=8 --tunnel-through-iap \
    --command='echo HC_SSH_OK; ls -d /dev/vfio* /dev/accel* >/dev/null 2>&1 && echo HC_CHIP_OK || echo HC_CHIP_MISS' >>"$SETUP_LOG" 2>&1
  local nssh nvfio
  nssh=$(grep -c 'HC_SSH_OK' "$SETUP_LOG" 2>/dev/null)
  nvfio=$(grep -c 'HC_CHIP_OK' "$SETUP_LOG" 2>/dev/null)
  log "HEALTHCHECK: SSH $nssh/$wc · chip (vfio/accel) $nvfio/$wc"
  if "$GCLOUD" alpha compute tpus tpu-vm ssh "$vm" --project="$PROJECT" --zone="$zone" --account="$ACCOUNT" \
      --worker=0 --tunnel-through-iap --ssh-flag="-o ConnectTimeout=20" \
      --command="python3 -c 'import urllib.request as r; r.urlopen(\"https://pypi.org\", timeout=10); print(\"HC_PYPI_OK\")'" >>"$SETUP_LOG" 2>&1; then
    log "HEALTHCHECK: PyPI reachable (NAT OK, can pip)"
  else
    log "HEALTHCHECK: ⚠️ PyPI unreachable (NAT may not be configured → pip will fail silently)"
  fi
  # optional: user-defined install (unset by default = pure provision-only; to pre-install dependencies set TPU_SETUP_CMD in conf)
  if [ -n "${TPU_SETUP_CMD:-}" ]; then
    log "SETUP: running user TPU_SETUP_CMD (dependencies you specified yourself)"
    export ZONE="$zone" VM="$vm" WORKER_COUNT="$wc" GCLOUD PROJECT ACCOUNT
    ( eval "$TPU_SETUP_CMD" ) >>"$SETUP_LOG" 2>&1 || { log "SETUP: TPU_SETUP_CMD non-zero exit"; return 1; }
  fi
  echo "HEALTHCHECK_DONE $(date)" >> "$SETUP_LOG"
  [ "${nssh:-0}" -ge 1 ] && return 0 || return 1
}

# 0=claim+configured / 1=not ready / 2=VM has job / 3=claimed but config failed
claim_and_setup() {
  local e="$1" zone qr vm wc ct health
  zone=$(f "$e" 1); qr=$(f "$e" 2); vm=$(f "$e" 3); wc=$(f "$e" 6)
  log "VM_READY $zone/$vm — health + SSH + job liveness"
  health=$(vm_health "$zone" "$vm")
  if [ -n "$health" ] && [ "$health" != "HEALTHY" ]; then
    log "VM_UNHEALTHY $zone/$vm health=$health, not claiming"; notify "TPU health abnormal" "$vm health=$health, not claimed" ""; return 1
  fi
  if ! ssh_probe "$zone" "$vm"; then log "SSH_NOT_READY $zone/$vm, back to loop"; return 1; fi
  if vm_has_job "$zone" "$vm"; then
    log "VM_BUSY $zone/$vm process matching TPU_BUSY_PATTERN is running, not taking over, marking skip"
    notify "TPU has a job running" "$vm has $BUSY_PAT, daemon not taking over" ""; return 2
  fi
  if ! "$GCLOUD" alpha compute tpus tpu-vm ssh "$vm" --project="$PROJECT" --zone="$zone" --worker=0 --tunnel-through-iap --account="$ACCOUNT" --ssh-flag="-o ConnectTimeout=15" --command="touch /tmp/tpu_claimed_\$(date +%s)" >>"$LOG" 2>&1; then
    log "CLAIM touch failed $zone/$vm (grabbed after probe?), not writing FLAG, not cancel, back to loop"; return 1
  fi
  ct=$(vm_createtime "$zone" "$vm")
  [ -z "$ct" ] && ct=$(vm_createtime "$zone" "$vm")
  [ -z "$ct" ] && ct="unknown-$(date +%s)"
  log "CLAIMED $zone/$vm (createTime=$ct)"
  log_incident CLAIMED "$(f "$e" 4)" "$zone" ok "grabbed+SSH ready" ""
  echo "$zone|$vm|$ct|$(date)" > "$FLAG"
  cancel_losers "$zone"
  # on grab, immediately write the SSH command to a file (official queued-resources ssh, against the QR name, saves the QR→VM mapping)
  printf '%s alpha compute tpus queued-resources ssh %s --project=%s --zone=%s --worker=0 --tunnel-through-iap\n' \
    "$GCLOUD" "$qr" "$PROJECT" "$zone" > "$SSH_CMD_FILE"
  log "SSH_READY $zone/$vm — SSH command written to $SSH_CMD_FILE"
  notify "TPU grabbed" "$vm @ $zone, SSH ready (see $SSH_CMD_FILE)" "TPU grabbed, SSH ready"
  if generic_setup "$zone" "$vm" "$wc"; then
    notify "TPU grabbed+healthy" "$vm node ready, install dependencies yourself (or set TPU_SETUP_CMD)" "TPU grabbed, node healthy"
    log "COST: VM $vm billed continuously since $ct, remember to delete when done to save money"
    return 0
  fi
  notify "TPU config partly failed" "see $SETUP_LOG" ""
  log "COST: VM $vm claimed but config incomplete, billed since $ct"
  return 3
}

# ── build TARGETS from conf (only has_quota=yes, skip unfilled template rows) ──────────
TARGETS=()
i=0
while [ "$i" -lt "${#TPU_TARGETS_V5[@]}" ]; do
  e="${TPU_TARGETS_V5[$i]}"
  case "$e" in *"<"*) i=$((i+1)); continue ;; esac
  hq=$(echo "$e" | cut -d'|' -f9)
  [ "$hq" = "yes" ] && TARGETS[${#TARGETS[@]}]="$(echo "$e" | cut -d'|' -f1-8)"
  i=$((i+1))
done
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "FATAL: no valid target with has_quota=yes, check TPU_TARGETS_V5 in resources.conf" >&2; exit 1
fi

case "$OWNER_PAT" in
  ""|"*") echo "FATAL: TPU_OWNER_PATTERN too broad ('$OWNER_PAT'), would allow deleting any resource, refusing to start" >&2; exit 1 ;;
esac

if [ -f "$PIDFILE" ]; then
  oldpid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "${oldpid:-}" ] && ps -p "$oldpid" -o command= 2>/dev/null | grep -q "tpu_daemon"; then
    echo "daemon already running (pid $oldpid)" >&2; exit 1
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' INT TERM EXIT
rm -f "$STOPFILE"                      # new daemon start = clear old stop signal
echo "=== tpu_daemon start: $(date) ===" > "$LOG"

preflight || { log "=== exit: preflight failed ==="; exit 1; }
consume_deferred

if [ -f "$FLAG" ]; then
  fz=$(cut -d'|' -f1 "$FLAG"); fv=$(cut -d'|' -f2 "$FLAG"); fct=$(cut -d'|' -f3 "$FLAG")
  cur=$(vm_state "$fz" "$fv"); curct=$(vm_createtime "$fz" "$fv")
  if [ "$cur" = "READY" ] && [ -n "$fct" ] && [ "$curct" = "$fct" ]; then
    log "STARTUP: valid claim already exists ($fz/$fv), exiting"; exit 0
  elif vm_gone "$fz" "$fv"; then
    log "STALE_MARKER: flag→$fz/$fv no longer exists (NOT_FOUND), clearing flag and re-grabbing"; rm -f "$FLAG"
  elif [ -z "$cur" ] && [ -z "$curct" ]; then
    log "STARTUP: flag VM describe transient failure (not NOT_FOUND), conservatively keeping flag, exiting"; exit 0
  else
    log "STALE_MARKER: flag→$fz/$fv state=$cur createTime mismatch, clearing flag and re-grabbing"; rm -f "$FLAG"
  fi
fi

# ── main loop ────────────────────────────────────────────────────────
LAST_VM=(); LAST_QR=(); BUSY=(); DEAD=(); UNK=(); iter=0
while [ "$iter" -lt "$MAX_ITER" ]; do
  iter=$((iter+1))
  # ★ stop signal (kill-triggered): on seeing it exit, never recreate again (prevents deleting then requeuing)
  [ -f "$STOPFILE" ] && { log "received stop signal, exiting without recreate"; exit 0; }
  i=0
  while [ "$i" -lt "${#TARGETS[@]}" ]; do
    if [ "${BUSY[$i]:-0}" = "1" ] || [ "${DEAD[$i]:-0}" = "1" ]; then i=$((i+1)); continue; fi
    e="${TARGETS[$i]}"; ZONE_T=$(f "$e" 1); VM_T=$(f "$e" 3)
    S=$(vm_state "$ZONE_T" "$VM_T"); S="${S:-NONE}"
    if [ "${LAST_VM[$i]:-_}" != "$S" ]; then log "STATE_CHANGE vm $ZONE_T/$VM_T: ${LAST_VM[$i]:-?} → $S"; LAST_VM[$i]="$S"; fi
    if [ "$S" = "READY" ]; then
      claim_and_setup "$e"; crc=$?
      case "$crc" in
        0) log "=== daemon exit (grabbed+configured) $(date) ==="; exit 0 ;;
        2) BUSY[$i]=1; log "marking $VM_T busy, skip henceforth" ;;
        3) log "=== daemon exit 4 (claimed but config incomplete) $(date) ==="; exit 4 ;;
        *) : ;;
      esac
    fi
    i=$((i+1))
  done
  if [ $((iter % QR_EVERY)) -eq 1 ]; then
    i=0
    while [ "$i" -lt "${#TARGETS[@]}" ]; do
      if [ "${DEAD[$i]:-0}" = "1" ]; then i=$((i+1)); continue; fi
      e="${TARGETS[$i]}"; ZONE_T=$(f "$e" 1); QR_T=$(f "$e" 2)
      QS=$(qr_state_classified "$ZONE_T" "$QR_T")
      if [ "${LAST_QR[$i]:-_}" != "$QS" ]; then log "STATE_CHANGE qr $ZONE_T/$QR_T: ${LAST_QR[$i]:-?} → $QS"; LAST_QR[$i]="$QS"; fi
      case "$QS" in
        FAILED)
          accel=$(f "$e" 4)
          fmsg=$(qr_raw "$ZONE_T" "$QR_T" | grep -iE "message|capacity|billing|Limit|PERMISSION|EXHAUST" | head -1 | sed 's/^ *//')
          classify_failed "$ZONE_T" "$QR_T"; rc=$?
          case "$rc" in
            3) log "BLOCKED_PROJECT_STATE $ZONE_T/$QR_T (project-level, stopping)"; echo "BLOCKED $ZONE_T $QR_T $(date)" >> "$BLOCKED"
               log_incident FAILED "$accel" "$ZONE_T" billing-permission "stop-needs manual" "$fmsg"
               notify "TPU project-level block" "$QR_T billing/permission error, needs manual" "TPU project-level error"; exit 3 ;;
            4) log "QUOTA_DEAD $ZONE_T per-zone quota block, stopping this target"
               log_incident FAILED "$accel" "$ZONE_T" quota-not-granted "stop this zone-keep others" "$fmsg"
               DEAD[$i]=1; notify "TPU zone quota block" "$ZONE_T skipped" "" ;;
            0) log_incident FAILED "$accel" "$ZONE_T" capacity-stockout "delete+requeue" "$fmsg"
               recreate_guarded "$e" ;;
            *) UNK[$i]=$(( ${UNK[$i]:-0} + 1 ))
               if [ "${UNK[$i]}" -gt "$UNKNOWN_CAP" ]; then log "UNKNOWN_CAP $ZONE_T stopping this target"
                 log_incident FAILED "$accel" "$ZONE_T" unknown "stop this zone-repeated unknown" "$fmsg"
                 DEAD[$i]=1; notify "TPU repeated unknown failure" "$ZONE_T stop queuing" ""
               else log "  $ZONE_T FAILED unknown (${UNK[$i]}/${UNKNOWN_CAP}), requeue"
                 log_incident FAILED "$accel" "$ZONE_T" unknown "delete+requeue" "$fmsg"; recreate_guarded "$e"; fi ;;
          esac ;;
        SUSPENDED) log_incident SUSPENDED "$(f "$e" 4)" "$ZONE_T" spot-preemption "delete+requeue" ""
                   recreate_guarded "$e" ;;
        MISSING) recreate_guarded "$e" ;;
        UNKNOWN) log "  $ZONE_T QR describe transient failure, noop (no mis-delete)" ;;
        *) : ;;
      esac
      i=$((i+1))
    done
    alldead=1; j=0
    while [ "$j" -lt "${#TARGETS[@]}" ]; do [ "${DEAD[$j]:-0}" != "1" ] && alldead=0; j=$((j+1)); done
    [ "$alldead" = "1" ] && { log "=== daemon exit: all targets blocked ==="; notify "TPU all blocked" "needs manual" ""; exit 3; }
  fi
  sleep "$POLL_SEC"
done
log "=== daemon exit (6h timeout) $(date) ==="
notify "TPU daemon exit" "6h without a grab" ""
exit 2
