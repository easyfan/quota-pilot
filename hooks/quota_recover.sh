#!/usr/bin/env bash
# quota-pilot recovery layer: SessionStart hook.
#
# The wake-up alarm is an in-process background task — it dies with the Claude
# Code process (terminal closed, machine rebooted, session abandoned). When that
# happens the parked window reset comes and goes with nothing alive to wake, and
# the checkpoint sits on disk unnoticed. Field incident 2026-07-13: a session
# parked at 10:26, its process did not survive the 4.5h idle, and the checkpoint
# was never surfaced when a new session opened 13.5h later.
#
# This hook closes that gap using only a native SessionStart event: on a fresh
# session it looks for a leftover quota-checkpoint.md in the project and, if the
# park is genuinely orphaned, surfaces it as context so the model can verify the
# window via /quota and continue from Next step.
#
# "Orphaned" is decided precisely — a checkpoint on disk is NOT enough, because a
# still-waiting alarm leaves the same file there for hours:
#   * source == "resume"  → the session is resuming in place; the normal wake-up
#                           path owns that, so stay silent (no cold-recovery noise).
#   * a live alarm marker → quota_alarm.sh writes alarm.pid while it waits; if that
#                           PID is still alive and its reset has not long passed, a
#                           real park is in progress → stay silent. (This also keeps
#                           quiet in subagents spawned during a live park.)
#   * otherwise           → the checkpoint is a true orphan → surface it.
#
# Silent (exit 0, no output) whenever there is nothing to recover — this must never
# disturb a normal session.
#
# Env overrides (tests):
#   QUOTA_PILOT_CWD   force the project dir instead of reading stdin
#   QUOTA_PILOT_DIR   state dir holding alarm.pid (default ~/.claude/quota-pilot)

set -uo pipefail

PAYLOAD="$(cat 2>/dev/null || true)"  # SessionStart stdin JSON
QP_DIR="${QUOTA_PILOT_DIR:-$HOME/.claude/quota-pilot}"

# source + cwd from the payload in one parse
META="$(printf '%s' "$PAYLOAD" | python3 -c '
import json,sys,os
try: d=json.load(sys.stdin)
except Exception: d={}
print((d.get("source") or "") + "\t" + (d.get("cwd") or os.getcwd()))' 2>/dev/null)"
SRC="${META%%$'\t'*}"
CWD="${QUOTA_PILOT_CWD:-${META#*$'\t'}}"
[ -z "$CWD" ] && CWD="$PWD"

# a resume re-runs SessionStart inside an already-live session — not a cold start
[ "$SRC" = "resume" ] && exit 0

# canonical path first (skill writes here), then project-root fallback (a model
# that skipped .claude/ still gets recovered — this happened in the 07-13 incident)
CKPT=""
for cand in "$CWD/.claude/quota-checkpoint.md" "$CWD/quota-checkpoint.md"; do
  if [ -f "$cand" ]; then CKPT="$cand"; break; fi
done
[ -z "$CKPT" ] && exit 0  # no checkpoint → stay silent

# still-waiting alarm? then this is a live park, not an orphan — stay silent.
# python exit 0 = live (suppress), 1 = dead/stale/unparseable (proceed to surface).
if [ -f "$QP_DIR/alarm.pid" ] && PF="$QP_DIR/alarm.pid" python3 -c '
import json,os,sys,time
try: d=json.load(open(os.environ["PF"]))
except Exception: sys.exit(1)          # unreadable marker → do not suppress
try: os.kill(int(d.get("pid",0)),0)    # signal 0 = liveness probe
except Exception: sys.exit(1)          # PID gone → orphan
sys.exit(0 if time.time() < float(d.get("resets_at",0))+300 else 1)  # guard PID reuse
' 2>/dev/null; then
  exit 0
fi

CKPT="$CKPT" python3 <<'PY'
import json, os, re

ckpt = os.environ["CKPT"]
try:
    text = open(ckpt, encoding="utf-8", errors="replace").read()
except Exception:
    raise SystemExit(0)

# header timestamp: "# Quota Checkpoint — {ISO}"
m = re.search(r"Quota Checkpoint\s*[—-]\s*(.+)", text)
written = m.group(1).strip() if m else "unknown time"

# pull the "Next step" section so the notice is actionable on its own
nxt = ""
nm = re.search(r"##\s*Next step\s*\n(.+?)(?:\n##\s|\Z)", text, re.S)
if nm:
    nxt = " ".join(nm.group(1).split())[:400]

# best-effort window-reset hint from the live sample
reset_hint = ""
try:
    st = json.load(open(os.path.expanduser("~/.claude/quota-pilot/state.json")))
    fh = st["five_hour"]["utilization"]
    reset_hint = (f" Current 5h utilization is {fh:.0f}% — "
                  + ("the window has likely reset, safe to resume."
                     if fh < 50 else
                     "still elevated; confirm with /quota before resuming."))
except Exception:
    reset_hint = " Run /quota to confirm the window has reset before resuming."

msg = (
    f"[quota-pilot] An orphaned quota checkpoint is present at {ckpt} "
    f"(written {written}). A prior session parked here and never resumed — most "
    f"likely its process was closed before the window reset, so the in-process "
    f"wake-up alarm died with it.{reset_hint}"
    + (f" Next step from the checkpoint: {nxt}" if nxt else "")
    + " Open the checkpoint, verify its 'In progress / unverified' items, continue"
    f" from 'Next step', and delete the checkpoint once resumed. If you do NOT intend"
    f" to resume this work, just delete it to silence this notice: rm {ckpt}"
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": msg,
    }
}))
PY

exit 0
