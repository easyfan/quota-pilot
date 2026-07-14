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

QB="$TMP/g3"; mkdir -p "$QB"
seed_state "$QB" 74 "$NOW" $((NOW+3600))
printf '{"ts":%s,"five_hour":30.0,"seven_day":10.0,"five_hour_resets_at":%s}\n{"ts":%s,"five_hour":52.0,"seven_day":10.0,"five_hour_resets_at":%s}\n{"ts":%s,"five_hour":74.0,"seven_day":10.0,"five_hour_resets_at":%s}\n' \
  $((NOW-239)) $((NOW+3600)) $((NOW-120)) $((NOW+3600)) $((NOW-1)) $((NOW+3600)) > "$QB/history.jsonl"
OUT=$(gate "$QB")
echo "$OUT" | grep -q "CRITICAL" && echo "$OUT" | grep -q "projected exhaustion"
check "sustained fast burn (11%/min over 4 min at 74%): projected-burnout escalates to critical" $?
echo "$OUT" | python3 -c "
import json,sys;d=json.load(sys.stdin)
assert 'VERY FIRST action' in d['reason'] and d['reason'].index('alarm') < d['reason'].index('checkpoint')" 2>/dev/null
check "critical reason: alarm-first ordering" $?

QB2="$TMP/g4"; mkdir -p "$QB2"
seed_state "$QB2" 75 "$NOW" $((NOW+3600))
printf '{"ts":%s,"five_hour":73.0,"seven_day":10.0,"five_hour_resets_at":%s}\n{"ts":%s,"five_hour":75.0,"seven_day":10.0,"five_hour_resets_at":%s}\n' \
  $((NOW-300)) $((NOW+3600)) $((NOW-1)) $((NOW+3600)) > "$QB2/history.jsonl"
OUT=$(gate "$QB2")
[ -z "$OUT" ]; check "slow burn (0.4%/min at 75%): silent" $?

# Regression, incident 2026-07-13: a 2-sample settlement spike (36→59 in 66s)
# projected 20.9%/min and paused a session at 59% — window span below
# ttb_min_span_seconds must yield no projection at all.
QB3="$TMP/g5"; mkdir -p "$QB3"
seed_state "$QB3" 59 "$NOW" $((NOW+16000))
printf '{"ts":%s,"five_hour":36.0,"seven_day":10.0,"five_hour_resets_at":%s}\n{"ts":%s,"five_hour":59.0,"seven_day":10.0,"five_hour_resets_at":%s}\n' \
  $((NOW-66)) $((NOW+16000)) $((NOW-1)) $((NOW+16000)) > "$QB3/history.jsonl"
OUT=$(gate "$QB3")
[ -z "$OUT" ]; check "short-span spike (36→59 in 66s at 59%): silent" $?

# Same incident, 6 min later: spike still inside the 10-min window inflates
# the window rate (3.75%/min) but the trailing interval is flat (0.9%/min) —
# min(window, trailing) must reject the projection.
QB4="$TMP/g6"; mkdir -p "$QB4"
seed_state "$QB4" 65 "$NOW" $((NOW+16000))
printf '{"ts":%s,"five_hour":36.0,"seven_day":10.0,"five_hour_resets_at":%s}\n{"ts":%s,"five_hour":59.0,"seven_day":10.0,"five_hour_resets_at":%s}\n{"ts":%s,"five_hour":65.0,"seven_day":10.0,"five_hour_resets_at":%s}\n' \
  $((NOW-464)) $((NOW+16000)) $((NOW-398)) $((NOW+16000)) $((NOW-1)) $((NOW+16000)) > "$QB4/history.jsonl"
OUT=$(gate "$QB4")
[ -z "$OUT" ]; check "spike-then-flat (spike in window, trailing 0.9%/min at 65%): silent" $?

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
[ ! -f "$QA/alarm.pid" ]; check "alarm: liveness marker removed on exit (trap)" $?

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

echo "== quota_recover.sh (SessionStart recovery) =="
QPE="$TMP/qp-empty"; mkdir -p "$QPE"   # empty state dir → no live alarm marker
rec() { QUOTA_PILOT_DIR="$QPE" QUOTA_PILOT_CWD="$1" "$ROOT/hooks/quota_recover.sh"; }
QR="$TMP/proj"; mkdir -p "$QR/.claude"
cat > "$QR/.claude/quota-checkpoint.md" <<'EOF'
# Quota Checkpoint — 2026-07-13T02:26:33Z
## Task goal
Test goal.
## Next step
Run the migration on table foo.
EOF
OUT=$(rec "$QR" < /dev/null)
echo "$OUT" | python3 -c "
import json,sys;d=json.load(sys.stdin)
ctx=d['hookSpecificOutput']['additionalContext']
assert d['hookSpecificOutput']['hookEventName']=='SessionStart'
assert '.claude/quota-checkpoint.md' in ctx
assert 'Run the migration on table foo' in ctx
assert 'rm ' in ctx and 'silence' in ctx, 'escape hatch missing'" 2>/dev/null
check "recover: orphan checkpoint surfaced with Next step + escape hatch" $?

# project-root fallback — incident 2026-07-13: the model wrote the checkpoint to
# the project root, not .claude/; recovery must still find it
QR2="$TMP/proj2"; mkdir -p "$QR2"
printf '# Quota Checkpoint — 2026-07-13T10:00:00Z\n## Next step\nroot fallback\n' > "$QR2/quota-checkpoint.md"
OUT=$(rec "$QR2" < /dev/null)
echo "$OUT" | grep -q "quota-checkpoint.md"; check "recover: project-root checkpoint fallback detected" $?

# no checkpoint → dead silent (must never disturb a normal session)
OUT=$(rec "$TMP/proj-none" < /dev/null)
[ -z "$OUT" ]; check "recover: no checkpoint → silent" $?

# cwd taken from the SessionStart stdin payload when env override is absent
OUT=$(printf '{"cwd":"%s","source":"startup"}' "$QR" | QUOTA_PILOT_DIR="$QPE" "$ROOT/hooks/quota_recover.sh")
echo "$OUT" | grep -q "quota-checkpoint.md"; check "recover: reads cwd from stdin payload" $?

# source=resume → silent (in-place resume is owned by the wake-up path)
OUT=$(printf '{"cwd":"%s","source":"resume"}' "$QR" | QUOTA_PILOT_DIR="$QPE" "$ROOT/hooks/quota_recover.sh")
[ -z "$OUT" ]; check "recover: source=resume → silent" $?

# live alarm (PID alive, reset in the future) → live park, stay silent
QPL="$TMP/qp-live"; mkdir -p "$QPL"
printf '{"pid":%s,"resets_at":%s}\n' "$$" "$((NOW+3600))" > "$QPL/alarm.pid"
OUT=$(QUOTA_PILOT_DIR="$QPL" QUOTA_PILOT_CWD="$QR" "$ROOT/hooks/quota_recover.sh" < /dev/null)
[ -z "$OUT" ]; check "recover: live alarm marker → silent (not an orphan)" $?

# dead alarm (PID cannot exist) → true orphan, surface
QPD="$TMP/qp-dead"; mkdir -p "$QPD"
printf '{"pid":2147483646,"resets_at":%s}\n' "$((NOW+3600))" > "$QPD/alarm.pid"
OUT=$(QUOTA_PILOT_DIR="$QPD" QUOTA_PILOT_CWD="$QR" "$ROOT/hooks/quota_recover.sh" < /dev/null)
echo "$OUT" | grep -q "quota-checkpoint.md"; check "recover: dead alarm marker → orphan surfaced" $?

# stale live PID but reset long past → treated as orphan (guards PID reuse)
printf '{"pid":%s,"resets_at":%s}\n' "$$" "$((NOW-100000))" > "$QPL/alarm.pid"
OUT=$(QUOTA_PILOT_DIR="$QPL" QUOTA_PILOT_CWD="$QR" "$ROOT/hooks/quota_recover.sh" < /dev/null)
echo "$OUT" | grep -q "quota-checkpoint.md"; check "recover: live PID but reset long past → orphan surfaced" $?

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
ss=[h['command'] for e in s['hooks'].get('SessionStart',[]) for h in e['hooks']]
assert any('quota_recover.sh' in c for c in ss), 'SessionStart recover hook missing'
assert s['statusLine']['command'].endswith('statusline.sh')
assert s['model']=='opus'
cfg=json.load(open('$CD/quota-pilot/config.json'))
assert cfg['statusline_passthrough']=='my-old-statusline.sh'" 2>/dev/null
check "settings: gate+recover hooks registered, statusline wrapped, original preserved, unrelated keys intact" $?
[ -x "$CD/quota-pilot/bin/quota_recover.sh" ]; check "recover hook installed to bin/" $?

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
assert 'SessionStart' not in s.get('hooks',{})
assert s['statusLine']['command']=='my-old-statusline.sh'
assert s['model']=='opus'" 2>/dev/null
check "uninstall: gate+recover hooks removed, original statusline restored" $?
[ ! -f "$CD/commands/quota.md" ] && [ ! -d "$CD/skills/quota-pilot" ]
check "uninstall: files removed" $?

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
