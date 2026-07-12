---
description: Show current quota status — 5h/7d window utilization, reset countdown, burn rate, and exhaustion projection
allowed-tools: ["Bash(*quota_report.sh*)", "Read"]
---

Run the quota-pilot status report and relay it to the user:

```bash
REPORT=""
for c in "$HOME/.claude/quota-pilot/bin/quota_report.sh" "${CLAUDE_PLUGIN_ROOT:-}/scripts/quota_report.sh"; do
  [ -n "$c" ] && [ -f "$c" ] && REPORT="$c" && break
done
[ -n "$REPORT" ] && bash "$REPORT" || echo "quota-pilot: quota_report.sh not found — is quota-pilot installed?"
```

Present the output compactly. If it reports "no data yet", explain the likely
reasons it lists (no API response yet in any session / API-key account without
quota windows / sampler hook not installed) instead of guessing. Then offer
these two diagnostic commands so the user can self-diagnose immediately:
`ls ~/.claude/quota-pilot/` (confirms installation) and
`grep -r quota ~/.claude/settings.json` (confirms hook registration). If the
directory is missing, suggest running the quota-pilot installer; if the hook
entry is absent, direct the user to add it.

If the 5-hour utilization is above the warn threshold (default 88%), remind
the user that the quota-pilot skill's archive protocol is available and ask
whether to checkpoint now.

If a background quota alarm is currently waiting, mention that touching
`~/.claude/quota-pilot/cancel` resumes the session early.
