#!/usr/bin/env bash
# quota-pilot auxiliary sampling backend: statusline wrapper (TUI only).
#
# Zero network cost, event-driven (CC invokes the statusline after every API
# response), but does NOT run in happy/SDK/headless sessions — the oauth
# sampler remains the primary backend there. Both backends write the same
# normalized state.json (last-writer-wins; same underlying data, no conflict).
#
# Coexistence: if config.json has "statusline_passthrough" (saved by install.sh
# when the user already had a statusLine), the captured stdin is forwarded to
# that command and its output is emitted verbatim. Otherwise a compact built-in
# display is shown: "5h 24% ⏳21:50 | 7d 8%".

set -uo pipefail

INPUT=$(cat)
QP_DIR="${QUOTA_PILOT_DIR:-$HOME/.claude/quota-pilot}"
mkdir -p "$QP_DIR"
export QP_DIR

# ── Capture rate_limits → state.json (best effort, never blocks display) ─────
# input travels via env var: the heredoc already occupies stdin
export SL_INPUT="$INPUT"
python3 <<'PY' 2>/dev/null || true
import json, os, sys, time

qp_dir = os.environ["QP_DIR"]
try:
    rl = json.loads(os.environ["SL_INPUT"]).get("rate_limits") or {}
    state = {"sampled_at": int(time.time()), "source": "statusline"}
    for win in ("five_hour", "seven_day"):
        # statusline uses used_percentage + epoch; normalize to the oauth shape
        state[win] = {"utilization": float(rl[win]["used_percentage"]),
                      "resets_at_epoch": int(rl[win]["resets_at"])}
except Exception:
    sys.exit(0)  # field absent (non-subscriber / before first API response)

path = os.path.join(qp_dir, "state.json")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(state, f)
os.replace(tmp, path)
PY

# ── Display: passthrough to the user's original statusline, or built-in ──────
PASSTHROUGH=$(python3 -c "
import json,os
try: print(json.load(open(os.environ['QP_DIR']+'/config.json')).get('statusline_passthrough',''))
except Exception: print('')" 2>/dev/null || echo "")

if [ -n "$PASSTHROUGH" ]; then
  printf '%s' "$INPUT" | bash -c "$PASSTHROUGH"
  exit 0
fi

python3 <<'PY' 2>/dev/null || true
import json, os
from datetime import datetime

def tint(pct, text):
    # <60% green, 60-85% yellow, >85% red
    color = "32" if pct < 60 else "33" if pct <= 85 else "31"
    return f"\033[{color}m{text}\033[0m"

try:
    rl = json.loads(os.environ["SL_INPUT"]).get("rate_limits") or {}
    fh, sd = rl["five_hour"], rl["seven_day"]
    reset = datetime.fromtimestamp(int(fh["resets_at"])).strftime("%H:%M")
    fp, sp = float(fh["used_percentage"]), float(sd["used_percentage"])
    print(f'{tint(fp, f"5h {fp:.0f}%")} ⏳{reset} | {tint(sp, f"7d {sp:.0f}%")}')
except Exception:
    print("quota: n/a")  # no rate_limits yet — still render something
PY
