---
name: quota-pilot
description: Quota-aware task scheduling protocol — assess remaining work against subscription rate limits, checkpoint gracefully before the window is exhausted, set a wall-clock alarm, and auto-resume after reset. Use this skill whenever a [quota-pilot] rate-limit alert is injected into the conversation, whenever a background alarm prints QUOTA-RESET-WAKE / QUOTA-ALARM-CANCELLED / QUOTA-WAIT-TOO-LONG, whenever the user asks about remaining quota, rate limits, or "how much budget is left", or whenever a long-running task risks hitting the 5-hour usage window. Also use it when resuming work after a quota pause or when a quota-checkpoint.md file is present in the project.
---

# quota-pilot — quota-aware scheduling protocol

You are running under a subscription quota (5-hour and 7-day windows). This
skill defines what to do when a `[quota-pilot]` alert arrives, so the task
survives the quota window instead of dying mid-turn. The session never
crashes into the limit: it assesses, archives, sets its own alarm, idles at
zero token cost, and resumes when the window resets.

Paths used below:
- State directory: `~/.claude/quota-pilot/` (state.json, config.json, cancel)
- Alarm script: `~/.claude/quota-pilot/bin/quota_alarm.sh` (manual install) or
  `${CLAUDE_PLUGIN_ROOT}/scripts/quota_alarm.sh` (plugin install). If neither
  exists, use the inline fallback in "Alarm protocol" below.
- Checkpoint file: `<project>/.claude/quota-checkpoint.md`

## On a `warn` alert (assessment protocol)

The alert gives you: current utilization, the threshold, reset time, and
`resets_at_epoch`. Do the assessment **now**, in your head, before starting
anything new:

1. Remaining budget = 100 − current utilization − reserve (default 3%,
   kept back so the checkpoint itself never gets cut off).
2. Estimate the cost of the **next indivisible unit of work** — the smallest
   piece that is useless if half-done (one edit+test cycle, one committee
   round, one file migration). Heuristic baselines: a tool-dense turn burns
   roughly 1–2% of the 5h window; a multi-subagent committee round 5–15%.
   Prefer overestimating — an unnecessary pause costs minutes, a mid-unit
   cutoff costs correctness.
3. If the unit fits in the remaining budget: continue working normally. Do
   not checkpoint yet; you will be alerted again (10-minute cooldown).
4. If it does not fit: run the archive protocol below, then stop.

## On a `critical` alert

Skip the assessment. Run the archive protocol immediately, then end your
turn. At this level the reserve is nearly gone — every extra tool call risks
dying mid-write.

## If you are a subagent

The quota hook fires in subagent sessions too, but the archive protocol is
**not for you**: an alarm started inside a subagent dies with the subagent's
process and becomes an orphan — it will never wake anyone. Do NOT write a
checkpoint, do NOT start an alarm. Instead: finish or wind down the current
smallest unit, then return to your caller a summary that separates
*done-and-verified* from *in-progress-unverified*. The main session receives
the same alerts and owns the archive decision.

## Archive protocol

Two independent decisions, deliberately decoupled: the checkpoint is an
unconditional insurance policy (if this process dies — terminal closed,
machine rebooted — the alarm dies with it and the checkpoint is the only
recovery artifact). Resuming in *this* session is merely the default path.

1. **Write the checkpoint** to `<project>/.claude/quota-checkpoint.md`,
   exactly this structure:

   ```markdown
   # Quota Checkpoint — {ISO timestamp}
   ## Task goal
   The original request, one paragraph.
   ## Done and verified
   Only what was actually verified (tests run, output checked).
   ## In progress / unverified
   Honest half-done state: which edits are made but untested, which
   commands were never run. This section prevents the classic blind-resume
   bug: believing an unverified change is done.
   ## Next step
   The first thing to do on wake-up, concrete to the command/file level.
   ## Key context
   File paths, decisions made, dead ends already explored.
   ## Recovery
   Default: this session auto-resumes via the alarm. If the process died:
   a fresh session should read this file and continue from "Next step".
   ```

2. **Start the alarm** with the `resets_at_epoch` from the alert, as a
   background task (`run_in_background: true`). Extract the epoch integer by
   matching the pattern `resets_at_epoch=(\d+)` in the alert text; use the
   captured integer as the argument.

   ```bash
   ~/.claude/quota-pilot/bin/quota_alarm.sh <resets_at_epoch>
   ```

   If the script is missing, run this inline instead (same semantics —
   **wall-clock loop, never one long sleep**: macOS's monotonic clock stops
   during system sleep, so a single `sleep 4h` on a closed laptop oversleeps
   by hours; a 60s loop detects a passed deadline within a minute of the
   machine waking):

   ```bash
   TARGET=$(( <resets_at_epoch> + 120 + RANDOM % 300 ))
   while [ "$(date +%s)" -lt "$TARGET" ]; do
     [ -f ~/.claude/quota-pilot/cancel ] && { rm -f ~/.claude/quota-pilot/cancel; echo QUOTA-ALARM-CANCELLED; exit 0; }
     sleep 60
   done
   echo QUOTA-RESET-WAKE
   ```

3. **End your turn.** Tell the user in one short paragraph: current
   utilization, where the checkpoint is, when the alarm will fire, and how to
   cancel early (`touch ~/.claude/quota-pilot/cancel`). Then stop — an idle
   session costs zero tokens, and the alarm's exit auto-wakes it.

## Wake-up protocol

The background task's completion wakes the session. Read its output:

- `QUOTA-RESET-WAKE` — the window has reset. Open the checkpoint, go straight
  to **In progress / unverified** and *verify* those items first (rerun the
  tests, re-check the half-made edits) before trusting them. Then continue
  from **Next step**.
- `QUOTA-ALARM-CANCELLED` — the user resumed you early by touching
  `~/.claude/quota-pilot/cancel`. Same procedure, but be aware quota may
  still be tight; keep units small.
- `QUOTA-WAIT-TOO-LONG` — the reset is further away than `max_wait_hours`
  (typically the 7-day window is exhausted; a 5-hour reset won't help).
  Do NOT start another alarm. The checkpoint is on disk; summarize the
  situation for the user and end. A human decides what happens next.

## Notes

- Quota is account-level. If several sessions archive at once they all wait
  on the same window; the alarm adds random jitter so they do not stampede.
  Keep concurrent long-running parked sessions to ≤2.
- If context is near the auto-compact threshold when the alert arrives,
  that is one more reason to checkpoint now: writing the archive from a
  full context beats a lossy automatic compaction.
- To check quota anytime, run the `/quota` command (or
  `~/.claude/quota-pilot/bin/quota_report.sh`; add `--json` for
  machine-readable output with `suggested_defer_seconds` — useful before
  spawning expensive multi-subagent work or inside loop iterations).
