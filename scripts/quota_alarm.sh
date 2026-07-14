#!/usr/bin/env bash
# quota-pilot wake-up alarm. Run via Bash run_in_background; when it exits,
# Claude Code auto-wakes the idle session (verified: wake ~9s after exit).
#
# Usage: quota_alarm.sh <resets_at_epoch>
#
# Wall-clock loop, deliberately NOT a single long sleep: macOS's monotonic
# clock does not advance during system sleep, so `sleep 4h` on a closed laptop
# oversleeps by hours. A 60s tick re-checks wall time and detects a passed
# deadline within one tick of machine wake-up.
#
# Exit messages (the waking model reads these):
#   QUOTA-RESET-WAKE       quota window has reset — resume work
#   QUOTA-ALARM-CANCELLED  user touched $QP_DIR/cancel to resume early
#   QUOTA-WAIT-TOO-LONG    wait exceeds max_wait_hours — do NOT idle for days;
#                          checkpoint is on disk, notify the human instead
#
# Env overrides (used by tests):
#   QUOTA_PILOT_DIR         state directory
#   QUOTA_PILOT_ALARM_TICK  loop interval seconds (default 60)

set -uo pipefail

RESETS_AT="${1:?usage: quota_alarm.sh <resets_at_epoch>}"
QP_DIR="${QUOTA_PILOT_DIR:-$HOME/.claude/quota-pilot}"
TICK="${QUOTA_PILOT_ALARM_TICK:-60}"
mkdir -p "$QP_DIR"

read_cfg() {
  python3 -c "
import json,sys
try: cfg=json.load(open('$QP_DIR/config.json'))
except Exception: cfg={}
print(cfg.get('$1', $2))" 2>/dev/null || echo "$2"
}

MAX_WAIT_H=$(read_cfg max_wait_hours 6)
JITTER_MIN=$(read_cfg wake_jitter_minutes 5)

NOW=$(date +%s)
# +120s buffer past the reset, plus random jitter so concurrent sessions
# waiting on the same account-level window don't all wake at once
JITTER=$(( RANDOM % (JITTER_MIN * 60 + 1) ))
TARGET=$(( RESETS_AT + 120 + JITTER ))

# Liveness marker for the SessionStart recovery hook (quota_recover.sh). While
# this alarm is waiting the checkpoint sits on disk, so "checkpoint exists" alone
# cannot tell a live park from an orphaned one. The marker records our PID and the
# reset time; the trap removes it on every exit, so a marker whose PID is dead (or
# whose reset is long past) is the unambiguous orphan signal. project path is left
# out on purpose — only pid+resets_at drive the decision, and this keeps the JSON
# free of paths that would need escaping.
printf '{"pid":%s,"resets_at":%s}\n' "$$" "$RESETS_AT" > "$QP_DIR/alarm.pid"
trap 'rm -f "$QP_DIR/alarm.pid"' EXIT

if [ $(( TARGET - NOW )) -gt $(( MAX_WAIT_H * 3600 )) ]; then
  osascript -e 'display notification "Wait exceeds max_wait_hours — manual resume needed" with title "quota-pilot"' 2>/dev/null || true
  echo "QUOTA-WAIT-TOO-LONG target=$TARGET now=$NOW max_wait_hours=$MAX_WAIT_H"
  exit 0
fi

while [ "$(date +%s)" -lt "$TARGET" ]; do
  if [ -f "$QP_DIR/cancel" ]; then
    rm -f "$QP_DIR/cancel"
    echo "QUOTA-ALARM-CANCELLED"
    exit 0
  fi
  sleep "$TICK"
done

echo "QUOTA-RESET-WAKE"
