#!/usr/bin/env bash
# quota-pilot primary sampling backend: polls the oauth/usage endpoint.
#
# Called by hooks/quota_gate.sh on every PostToolUse event, throttled to one
# real request per 60s (cache hits cost ~ms). Writes normalized state.json and
# appends to history.jsonl. The endpoint is NOT publicly documented, so every
# response goes through schema validation — on any mismatch we keep the old
# state and exit 0 silently rather than feeding garbage to the decision layer.
#
# Env overrides (used by tests):
#   QUOTA_PILOT_DIR                state directory (default ~/.claude/quota-pilot)
#   QUOTA_PILOT_THROTTLE_SECONDS   sampling throttle (default 60)
#   QUOTA_PILOT_MOCK_RESPONSE      path to a canned response file; skips network+token

set -uo pipefail

QP_DIR="${QUOTA_PILOT_DIR:-$HOME/.claude/quota-pilot}"
STATE="$QP_DIR/state.json"
HISTORY="$QP_DIR/history.jsonl"
THROTTLE="${QUOTA_PILOT_THROTTLE_SECONDS:-60}"
mkdir -p "$QP_DIR"

# ── Throttle: reuse cached state if fresh ─────────────────────────────────────
if [ -f "$STATE" ]; then
  last=$(python3 -c "import json,sys;print(int(json.load(open(sys.argv[1])).get('sampled_at',0)))" "$STATE" 2>/dev/null || echo 0)
  now=$(date +%s)
  if [ $((now - last)) -lt "$THROTTLE" ]; then
    exit 0
  fi
fi

# ── Credentials ───────────────────────────────────────────────────────────────
# CC refreshes the OAuth token itself; on 401 we simply re-read the credential
# store once and retry. Non-subscription (API key) users have no claudeAiOauth
# entry — we exit silently and the plugin stays dormant.
read_token() {
  if [ "$(uname)" = "Darwin" ]; then
    security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null
  else
    cat "$HOME/.claude/.credentials.json" 2>/dev/null
  fi | python3 -c "import json,sys;print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null
}

BODY=""
if [ -n "${QUOTA_PILOT_MOCK_RESPONSE:-}" ]; then
  BODY=$(cat "$QUOTA_PILOT_MOCK_RESPONSE" 2>/dev/null) || exit 0
else
  TOKEN=$(read_token)
  [ -z "$TOKEN" ] && exit 0

  fetch() {
    curl -s -m 15 -w '\n%{http_code}' "https://api.anthropic.com/api/oauth/usage" \
      -H "Authorization: Bearer $1" \
      -H "anthropic-beta: oauth-2025-04-20" 2>/dev/null
  }

  RAW=$(fetch "$TOKEN") || exit 0
  CODE="${RAW##*$'\n'}"
  BODY="${RAW%$'\n'*}"
  if [ "$CODE" = "401" ]; then
    TOKEN=$(read_token)
    [ -z "$TOKEN" ] && exit 0
    RAW=$(fetch "$TOKEN") || exit 0
    CODE="${RAW##*$'\n'}"
    BODY="${RAW%$'\n'*}"
  fi
  [ "$CODE" != "200" ] && exit 0
fi

# ── Validate, normalize, persist ──────────────────────────────────────────────
# body travels via env var: the heredoc already occupies stdin
BODY="$BODY" STATE="$STATE" HISTORY="$HISTORY" python3 <<'PY'
import json, os, sys, time
from datetime import datetime

state_path, history_path = os.environ["STATE"], os.environ["HISTORY"]

def to_epoch(v):
    # oauth returns ISO 8601; tolerate epoch numbers in case the field evolves
    if isinstance(v, (int, float)):
        return int(v)
    # tolerate a Z suffix: pre-3.11 fromisoformat rejects it
    return int(datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp())

try:
    data = json.loads(os.environ["BODY"])
    state = {"sampled_at": int(time.time()), "source": "oauth"}
    for win in ("five_hour", "seven_day"):
        util = float(data[win]["utilization"])
        if not 0 <= util <= 100:
            raise ValueError(f"{win}.utilization out of range: {util}")
        state[win] = {"utilization": util,
                      "resets_at_epoch": to_epoch(data[win]["resets_at"])}
except Exception:
    sys.exit(0)  # schema mismatch → keep old state, stay silent

tmp = state_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(state, f)
os.replace(tmp, state_path)

with open(history_path, "a") as f:
    f.write(json.dumps({
        "ts": state["sampled_at"],
        "five_hour": state["five_hour"]["utilization"],
        "seven_day": state["seven_day"]["utilization"],
        "five_hour_resets_at": state["five_hour"]["resets_at_epoch"],
    }) + "\n")

# size-based rotation: keep the newest half once the file grows past ~1MB
if os.path.getsize(history_path) > 1_000_000:
    with open(history_path) as f:
        lines = f.readlines()
    with open(tmp, "w") as f:
        f.writelines(lines[len(lines)//2:])
    os.replace(tmp, history_path)
PY

exit 0
