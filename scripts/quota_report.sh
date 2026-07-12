#!/usr/bin/env bash
# quota-pilot status report, used by the /quota command.
# Reads state.json + history.jsonl; prints current windows, reset countdown,
# recent burn rate, and a naive time-to-threshold projection.
#
# --json: machine-readable output for integrations (loop prompts, workflow
# phase gates, pre-spawn checks). Adds suggested_defer_seconds: 0 when below
# the warn threshold, otherwise seconds until the 5h window resets (+120s
# buffer) — callers can feed it straight into their own scheduling.

set -uo pipefail

JSON=false
[ "${1:-}" = "--json" ] && JSON=true

QP_DIR="${QUOTA_PILOT_DIR:-$HOME/.claude/quota-pilot}"
export QP_DIR JSON
python3 <<'PY'
import json, os, time
from datetime import datetime

qp_dir = os.environ["QP_DIR"]
as_json = os.environ["JSON"] == "true"
now = time.time()

try:
    state = json.load(open(os.path.join(qp_dir, "state.json")))
except Exception:
    if as_json:
        print(json.dumps({"error": "no-data", "reasons": [
            "no API response in any session yet",
            "non-subscription (API key) account has no quota windows",
            "sampler has not run (PostToolUse hook not installed?)"]}))
        raise SystemExit(0)
    print("quota-pilot: no data yet.")
    print("Possible reasons: no API response in any session yet; "
          "non-subscription (API key) account has no quota windows; "
          "or the sampler has not run (is the PostToolUse hook installed?).")
    raise SystemExit(0)

if as_json:
    try:
        cfg = json.load(open(os.path.join(qp_dir, "config.json")))
    except Exception:
        cfg = {}
    warn_th = float(cfg.get("warn_threshold", 88))
    fh = state["five_hour"]
    defer = 0
    if fh["utilization"] >= warn_th:
        defer = max(0, int(fh["resets_at_epoch"] - now) + 120)
    # burn rate from the last hour of samples (None if too few)
    hist = []
    try:
        with open(os.path.join(qp_dir, "history.jsonl")) as f:
            for ln in f:
                try:
                    e = json.loads(ln)
                    if now - e["ts"] <= 3600:
                        hist.append(e)
                except Exception:
                    pass
    except Exception:
        pass
    rate = None
    if len(hist) >= 2:
        span_h = (hist[-1]["ts"] - hist[0]["ts"]) / 3600
        if span_h > 0.05:
            rate = round((hist[-1]["five_hour"] - hist[0]["five_hour"]) / span_h, 2)
    print(json.dumps({
        "five_hour": state["five_hour"],
        "seven_day": state["seven_day"],
        "sampled_at": state["sampled_at"],
        "age_seconds": int(now - state["sampled_at"]),
        "source": state.get("source"),
        "warn_threshold": warn_th,
        "burn_rate_per_hour": rate,
        "suggested_defer_seconds": defer,
    }))
    raise SystemExit(0)

age = int(now - state["sampled_at"])
fh, sd = state["five_hour"], state["seven_day"]

def line(label, win):
    reset = datetime.fromtimestamp(win["resets_at_epoch"])
    mins = max(0, int((win["resets_at_epoch"] - now) // 60))
    return (f"{label}: {win['utilization']:.0f}%  "
            f"resets {reset.strftime('%m-%d %H:%M')} (~{mins//60}h{mins%60:02d}m)")

print(line("5-hour window", fh))
print(line("7-day window ", sd))
print(f"sampled {age}s ago via {state.get('source', '?')}")

# burn rate over the last hour of samples
hist = []
try:
    with open(os.path.join(qp_dir, "history.jsonl")) as f:
        for ln in f:
            try:
                e = json.loads(ln)
                if now - e["ts"] <= 3600:
                    hist.append(e)
            except Exception:
                pass
except Exception:
    pass

if len(hist) >= 2:
    span_h = (hist[-1]["ts"] - hist[0]["ts"]) / 3600
    delta = hist[-1]["five_hour"] - hist[0]["five_hour"]
    if span_h > 0.05:
        rate = delta / span_h
        print(f"burn rate (last {span_h:.1f}h): {rate:+.1f}%/h")
        if rate > 0:
            for th in (88, 100):
                if fh["utilization"] < th:
                    eta = (th - fh["utilization"]) / rate
                    print(f"  → reaches {th}% in ~{eta:.1f}h at current pace")
else:
    print("burn rate: not enough samples in the last hour")
PY
