#!/usr/bin/env bash
# quota-pilot unit tests. No network, no real credentials: sampling goes
# through QUOTA_PILOT_MOCK_RESPONSE, and gate tests pre-seed a fresh
# state.json so the sampler's throttle short-circuits before any token read.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d /tmp/quota-pilot-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok  - $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check() { # $1 desc, $2 condition result (0/1)
  [ "$2" -eq 0 ] && ok "$1" || fail "$1"
}

seed_state() { # $1 qp_dir, $2 five_hour_util, $3 sampled_at, $4 resets_epoch
  python3 -c "
import json,sys
json.dump({'sampled_at':int('$3'),'source':'test',
 'five_hour':{'utilization':float('$2'),'resets_at_epoch':int('$4')},
 'seven_day':{'utilization':10.0,'resets_at_epoch':int('$4')+86400}},
 open('$1/state.json','w'))"
}

NOW=$(date +%s)

echo "== sample_usage.sh =="
QP1="$TMP/s1"; mkdir -p "$QP1"
cat > "$TMP/mock-good.json" <<EOF
{"five_hour":{"utilization":50.0,"resets_at":"2026-07-10T13:49:59+00:00"},
 "seven_day":{"utilization":11.0,"resets_at":"2026-07-16T03:00:00+00:00"},
 "limits":[]}
EOF
QUOTA_PILOT_DIR="$QP1" QUOTA_PILOT_MOCK_RESPONSE="$TMP/mock-good.json" "$ROOT/scripts/sample_usage.sh"
check "valid response writes normalized state.json" $?
python3 -c "
import json;s=json.load(open('$QP1/state.json'))
assert s['five_hour']['utilization']==50.0
assert isinstance(s['five_hour']['resets_at_epoch'],int)
assert s['source']=='oauth'" 2>/dev/null
check "state.json normalized (utilization + resets_at_epoch)" $?
[ -s "$QP1/history.jsonl" ]; check "history.jsonl appended" $?

cat > "$TMP/mock-changed.json" <<EOF
{"five_hour":{"utilization":77.0,"resets_at":"2026-07-10T13:49:59+00:00"},
 "seven_day":{"utilization":11.0,"resets_at":"2026-07-16T03:00:00+00:00"}}
EOF
QUOTA_PILOT_DIR="$QP1" QUOTA_PILOT_MOCK_RESPONSE="$TMP/mock-changed.json" "$ROOT/scripts/sample_usage.sh"
python3 -c "
import json;assert json.load(open('$QP1/state.json'))['five_hour']['utilization']==50.0" 2>/dev/null
check "throttle: fresh state not resampled" $?

QP2="$TMP/s2"; mkdir -p "$QP2"
echo '{"unexpected":"shape"}' > "$TMP/mock-bad.json"
QUOTA_PILOT_DIR="$QP2" QUOTA_PILOT_MOCK_RESPONSE="$TMP/mock-bad.json" "$ROOT/scripts/sample_usage.sh"
[ ! -f "$QP2/state.json" ]; check "schema mismatch: no state written, silent exit" $?

echo "== quota_gate.sh =="
gate() { echo '{}' | QUOTA_PILOT_DIR="$1" QUOTA_PILOT_MOCK_RESPONSE="$TMP/nonexistent" "$ROOT/hooks/quota_gate.sh"; }

QG="$TMP/g1"; mkdir -p "$QG"
seed_state "$QG" 50 "$NOW" $((NOW+3600))
OUT=$(gate "$QG")
[ -z "$OUT" ]; check "below threshold: silent" $?

seed_state "$QG" 91 "$NOW" $((NOW+3600))
OUT=$(gate "$QG")
echo "$OUT" | python3 -c "
import json,sys;d=json.load(sys.stdin)
assert d['decision']=='block' and 'resets_at_epoch=' in d['reason'] and '91%' in d['reason']" 2>/dev/null
check "warn threshold: block injection with epoch + percentage" $?

seed_state "$QG" 91 "$NOW" $((NOW+3600))
OUT=$(gate "$QG")
[ -z "$OUT" ]; check "cooldown: same level suppressed" $?

seed_state "$QG" 96 "$NOW" $((NOW+3600))
OUT=$(gate "$QG")
echo "$OUT" | grep -q "CRITICAL"; check "escalation warn→critical fires despite warn cooldown" $?

QG2="$TMP/g2"; mkdir -p "$QG2"
seed_state "$QG2" 96 $((NOW-1200)) $((NOW+3600))
OUT=$(gate "$QG2")
[ -z "$OUT" ]; check "stale state (>10min): silent" $?

echo "== statusline.sh =="
QS="$TMP/sl"; mkdir -p "$QS"
SL_INPUT='{"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":'$((NOW+7200))'},"seven_day":{"used_percentage":8,"resets_at":'$((NOW+86400))'}}}'
OUT=$(printf '%s' "$SL_INPUT" | QUOTA_PILOT_DIR="$QS" "$ROOT/scripts/statusline.sh")
echo "$OUT" | grep -q "5h 24%"; check "built-in display renders percentages" $?
python3 -c "
import json;s=json.load(open('$QS/state.json'))
assert s['source']=='statusline' and s['five_hour']['utilization']==24.0" 2>/dev/null
check "statusline capture normalized into state.json" $?

echo '{"statusline_passthrough":"sed s/.*/ORIGINAL-STATUSLINE/"}' > "$QS/config.json"
OUT=$(printf '%s' "$SL_INPUT" | QUOTA_PILOT_DIR="$QS" "$ROOT/scripts/statusline.sh")
[ "$OUT" = "ORIGINAL-STATUSLINE" ]; check "passthrough forwards stdin to original command" $?

OUT=$(printf '%s' '{"no_rate_limits":true}' | QUOTA_PILOT_DIR="$TMP/sl2" "$ROOT/scripts/statusline.sh")
[ -n "$OUT" ] && [ ! -f "$TMP/sl2/state.json" ]
check "missing rate_limits: still renders, no state written" $?

echo "== quota_alarm.sh =="
QA="$TMP/a1"; mkdir -p "$QA"
echo '{"wake_jitter_minutes":0}' > "$QA/config.json"
OUT=$(QUOTA_PILOT_DIR="$QA" QUOTA_PILOT_ALARM_TICK=1 "$ROOT/scripts/quota_alarm.sh" $((NOW-300)))
[ "$OUT" = "QUOTA-RESET-WAKE" ]; check "past deadline: immediate wake" $?

touch "$QA/cancel"
OUT=$(QUOTA_PILOT_DIR="$QA" QUOTA_PILOT_ALARM_TICK=1 "$ROOT/scripts/quota_alarm.sh" $((NOW+120)))
[ "$OUT" = "QUOTA-ALARM-CANCELLED" ] && [ ! -f "$QA/cancel" ]
check "cancel file: early resume + cancel consumed" $?

OUT=$(QUOTA_PILOT_DIR="$QA" "$ROOT/scripts/quota_alarm.sh" $((NOW+36000)) 2>/dev/null)
echo "$OUT" | grep -q "QUOTA-WAIT-TOO-LONG"; check "wait beyond max_wait_hours: refuses to idle" $?

echo "== quota_report.sh =="
OUT=$(QUOTA_PILOT_DIR="$TMP/empty-report" "$ROOT/scripts/quota_report.sh")
echo "$OUT" | grep -q "no data yet"; check "no data: explains reasons" $?
seed_state "$QG" 91 "$NOW" $((NOW+3600))
OUT=$(QUOTA_PILOT_DIR="$QG" "$ROOT/scripts/quota_report.sh")
echo "$OUT" | grep -q "5-hour window: 91%"; check "report renders current windows" $?

OUT=$(QUOTA_PILOT_DIR="$TMP/empty-report" "$ROOT/scripts/quota_report.sh" --json)
echo "$OUT" | python3 -c "import json,sys;d=json.load(sys.stdin);assert d['error']=='no-data' and len(d['reasons'])==3" 2>/dev/null
check "--json no-data: machine-readable error" $?
OUT=$(QUOTA_PILOT_DIR="$QG" "$ROOT/scripts/quota_report.sh" --json)
echo "$OUT" | python3 -c "
import json,sys;d=json.load(sys.stdin)
assert d['five_hour']['utilization']==91.0
assert d['suggested_defer_seconds'] > 3000, d['suggested_defer_seconds']" 2>/dev/null
check "--json above threshold: defer suggests waiting past reset" $?
QJ="$TMP/json-low"; mkdir -p "$QJ"
seed_state "$QJ" 40 "$NOW" $((NOW+3600))
OUT=$(QUOTA_PILOT_DIR="$QJ" "$ROOT/scripts/quota_report.sh" --json)
echo "$OUT" | python3 -c "
import json,sys;d=json.load(sys.stdin)
assert d['suggested_defer_seconds']==0 and d['warn_threshold']==88.0" 2>/dev/null
check "--json below threshold: defer is 0" $?

echo "== install.sh roundtrip =="
CD="$TMP/claude"; mkdir -p "$CD"
echo '{"statusLine":{"type":"command","command":"my-old-statusline.sh"},"model":"opus"}' > "$CD/settings.json"

"$ROOT/install.sh" --target="$CD" --statusline > /dev/null 2>&1
check "install exits 0" $?
[ -x "$CD/quota-pilot/bin/quota_gate.sh" ] && [ -f "$CD/skills/quota-pilot/SKILL.md" ] \
  && [ -f "$CD/commands/quota.md" ]
check "files installed (bin + skill + command)" $?
python3 -c "
import json;s=json.load(open('$CD/settings.json'))
hooks=[h['command'] for e in s['hooks']['PostToolUse'] for h in e['hooks']]
assert any('quota_gate.sh' in c for c in hooks)
assert s['statusLine']['command'].endswith('statusline.sh')
assert s['model']=='opus'
cfg=json.load(open('$CD/quota-pilot/config.json'))
assert cfg['statusline_passthrough']=='my-old-statusline.sh'" 2>/dev/null
check "settings: hook registered, statusline wrapped, original preserved, unrelated keys intact" $?

"$ROOT/install.sh" --target="$CD" > /dev/null 2>&1
python3 -c "
import json;s=json.load(open('$CD/settings.json'))
hooks=[h['command'] for e in s['hooks']['PostToolUse'] for h in e['hooks']]
assert len([c for c in hooks if 'quota_gate.sh' in c])==1" 2>/dev/null
check "reinstall idempotent: no duplicate hook entry" $?

"$ROOT/install.sh" --target="$CD" --uninstall > /dev/null 2>&1
python3 -c "
import json;s=json.load(open('$CD/settings.json'))
assert 'PostToolUse' not in s.get('hooks',{})
assert s['statusLine']['command']=='my-old-statusline.sh'
assert s['model']=='opus'" 2>/dev/null
check "uninstall: hook removed, original statusline restored" $?
[ ! -f "$CD/commands/quota.md" ] && [ ! -d "$CD/skills/quota-pilot" ]
check "uninstall: files removed" $?

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
