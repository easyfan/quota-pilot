#!/usr/bin/env bash
# quota-pilot decision layer: PostToolUse hook (matcher "*").
#
# Refreshes the sample (throttled inside sample_usage.sh), then decides whether
# to inject a quota alert into the conversation via {"decision":"block",...}.
# Everything that is not an injection is a silent exit 0 — this hook must never
# slow down or break normal tool flow.
#
# Injection state (last_injected per level, last 7d notice) lives in gate.json,
# NOT in state.json: the sampler rewrites state.json wholesale on every sample,
# which would wipe markers stored there.
#
# Env overrides (used by tests):
#   QUOTA_PILOT_DIR              state directory
#   QUOTA_PILOT_STALE_SECONDS    staleness cutoff (default 600)
#   QUOTA_PILOT_NOW              fake "now" epoch for deterministic tests

set -uo pipefail

cat > /dev/null  # consume hook stdin; tool payload is irrelevant to quota

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# flat install (~/.claude/quota-pilot/bin/) puts the sampler next to us;
# repo/plugin layout keeps it in ../scripts/
for c in "$SELF_DIR/sample_usage.sh" "$SELF_DIR/../scripts/sample_usage.sh"; do
  if [ -f "$c" ]; then "$c" || true; break; fi
done

QP_DIR="${QUOTA_PILOT_DIR:-$HOME/.claude/quota-pilot}"
export QP_DIR
python3 <<'PY'
import json, os, subprocess, sys, time
from datetime import datetime

qp_dir = os.environ["QP_DIR"]
now = int(os.environ.get("QUOTA_PILOT_NOW") or time.time())
stale_cutoff = int(os.environ.get("QUOTA_PILOT_STALE_SECONDS", "600"))

def load(path, default):
    try:
        with open(os.path.join(qp_dir, path)) as f:
            return json.load(f)
    except Exception:
        return default

state = load("state.json", None)
if not state or now - state.get("sampled_at", 0) > stale_cutoff:
    sys.exit(0)  # no data or sampling has been failing for a while → stay quiet

cfg = load("config.json", {})
warn_th     = float(cfg.get("warn_threshold", 88))
crit_th     = float(cfg.get("critical_threshold", 95))
reserve     = float(cfg.get("reserve", 3))
cooldown    = float(cfg.get("cooldown_minutes", 10)) * 60
sd_warn_th  = float(cfg.get("seven_day_warn", 90))

fh = state["five_hour"]["utilization"]
sd = state["seven_day"]["utilization"]
resets = state["five_hour"]["resets_at_epoch"]

gate_path = os.path.join(qp_dir, "gate.json")
gate = load("gate.json", {})

# 7d window: notify only (macOS), never triggers the archive protocol
if sd >= sd_warn_th and now - gate.get("last_7d_notice", 0) > 6 * 3600:
    gate["last_7d_notice"] = now
    try:
        subprocess.run(["osascript", "-e",
            f'display notification "7-day window at {sd:.0f}%" with title "quota-pilot"'],
            capture_output=True, timeout=5)
    except Exception:
        pass

level = "critical" if fh >= crit_th else "warn" if fh >= warn_th else None

def flush_gate():
    tmp = gate_path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(gate, f)
    os.replace(tmp, gate_path)

if level is None:
    flush_gate()
    sys.exit(0)

# per-level cooldown: an escalation warn→critical fires immediately,
# a repeat of the same level waits out the cooldown
if now - gate.get("last_injected", {}).get(level, 0) < cooldown:
    flush_gate()
    sys.exit(0)

reset_local = datetime.fromtimestamp(resets).strftime("%H:%M")
mins_left = max(0, (resets - now) // 60)

if level == "warn":
    reason = (
        f"[quota-pilot] Rate-limit alert: the 5-hour usage window is at {fh:.0f}% "
        f"(threshold {warn_th:.0f}%). It resets at {reset_local} local time "
        f"(~{mins_left} min from now, resets_at_epoch={resets}). "
        f"Assess now: can the next indivisible unit of work be completed within the "
        f"remaining budget, keeping a {reserve:.0f}% reserve for checkpointing? "
        f"If yes, continue working normally. If no, follow the quota-pilot skill's "
        f"archive protocol: write the checkpoint file, start the wake-up alarm with "
        f"quota_alarm.sh (run_in_background), then end your turn and wait. "
        f"Consult the quota-pilot skill for the exact protocol."
    )
else:
    reason = (
        f"[quota-pilot] CRITICAL: the 5-hour usage window is at {fh:.0f}% "
        f"(threshold {crit_th:.0f}%). Resets at {reset_local} local time "
        f"(~{mins_left} min from now, resets_at_epoch={resets}). "
        f"Skip the assessment step. Immediately write the checkpoint per the "
        f"quota-pilot skill, start the wake-up alarm with quota_alarm.sh "
        f"(run_in_background), then end your turn."
    )

gate.setdefault("last_injected", {})[level] = now
flush_gate()
print(json.dumps({"decision": "block", "reason": reason}))
PY

exit 0
