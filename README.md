# quota-pilot

**Quota-aware task scheduling for Claude Code.** Long tasks no longer crash into the 5-hour rate-limit wall: before the window is exhausted, the session assesses remaining work, writes a checkpoint, sets its own wall-clock alarm, idles at zero token cost, and resumes automatically after the reset.

[中文](README-zh.md) | [Deutsch](README-de.md) | [Français](README-fr.md) | [Русский](README-ru.md)

## Why proactive?

Existing tools (claude-auto-retry and friends) are **reactive**: they let the session die on the rate limit, then blindly type "continue" into it from tmux. That fails in three ways — the cut usually lands mid-turn (edit made, tests never run) so the resumed model misjudges what is actually done; it needs tmux keystroke injection into a dead session; and it has zero foresight about how much budget is left.

quota-pilot flips it: **the session never dies**. It gets alerted *before* exhaustion, judges for itself whether the next indivisible unit of work still fits, archives honestly (including what is half-done and unverified), and wakes itself up. No tmux, no launchd, no external babysitter — only Claude Code native primitives.

## How it works

```
┌─ sampling ────────────────┐   ┌─ decision ───────────┐   ┌─ behavior (model) ───────┐
│ primary: oauth/usage poll │   │ PostToolUse hook     │   │ quota-pilot skill        │
│ (throttled inside hook,   │ → │ reads state.json     │ → │ 1. assess next unit      │
│  works in ALL sessions)   │   │ threshold + cooldown │   │ 2. write checkpoint      │
│ aux: statusline wrapper   │   │ injects alert        │   │ 3. wall-clock alarm      │
│ (TUI display only)        │   └──────────────────────┘   │ 4. idle → wake → resume  │
└───────────────────────────┘                              └──────────────────────────┘
```

- **warn** (default 88%): the model assesses whether the next indivisible unit fits in the remaining budget (keeping a 3% checkpoint reserve). If yes, it keeps working; if no, it archives and parks.
- **critical** (default 95%): skip assessment, archive immediately.
- The checkpoint (`<project>/.claude/quota-checkpoint.md`) records *done-and-verified* vs *in-progress-unverified* separately — that distinction is what makes blind-resume bugs go away.
- The alarm is a wall-clock loop, not one long `sleep`: macOS's monotonic clock stops during system sleep, so a single `sleep 4h` on a closed laptop oversleeps by hours. The loop detects a passed deadline within 60s of machine wake.

## Install

**Option A — install script:**

```bash
git clone https://github.com/easyfan/quota-pilot.git
cd quota-pilot
./install.sh                # hook + skill + /quota command
./install.sh --statusline   # also install the TUI quota display
```

`--statusline` preserves an existing statusLine: your original command keeps rendering through the wrapper while quota data is captured on the side.

**Option B — plugin marketplace:**

```
/plugin marketplace add easyfan/quota-pilot
/plugin install quota-pilot@quota-pilot
```

Uninstall: `./install.sh --uninstall` (restores your original statusline and settings; keeps `~/.claude/quota-pilot/` state, delete manually if unwanted).

## Usage

Nothing to do — the hook watches quota on every tool call (one throttled HTTPS request per 60s max). When an alert fires you will see the model assess, checkpoint, and park itself.

- `/quota` — current 5h/7d utilization, reset countdown, burn rate, exhaustion projection
- `touch ~/.claude/quota-pilot/cancel` — wake a parked session early
- Checkpoint lives at `<project>/.claude/quota-checkpoint.md`; if the process died while parked, a fresh session can resume from it

## Configuration (`~/.claude/quota-pilot/config.json`)

| Key | Default | Meaning |
|-----|---------|---------|
| `warn_threshold` | 88 | assessment alert threshold (5h window %) |
| `critical_threshold` | 95 | immediate-archive threshold |
| `reserve` | 3 | budget kept back for checkpointing (%) |
| `cooldown_minutes` | 10 | per-level re-alert cooldown |
| `max_wait_hours` | 6 | beyond this, notify the human instead of idling |
| `wake_jitter_minutes` | 5 | random wake jitter (multi-session stampede guard) |
| `seven_day_warn` | 90 | 7-day window notification threshold (notify only) |
| `ttb_critical_minutes` | 3 | projected time-to-burnout that escalates straight to critical |
| `ttb_warn_minutes` | 10 | projected time-to-burnout that raises a warn below the % threshold |

## Integrations

The hook alert is the *passive* line of defense. For loops and multi-phase
workflows, query quota proactively instead:

```bash
~/.claude/quota-pilot/bin/quota_report.sh --json
# {"five_hour":{"utilization":68.0,"resets_at_epoch":...},"seven_day":{...},
#  "burn_rate_per_hour":4.2,"suggested_defer_seconds":0,...}
```

`suggested_defer_seconds` is 0 while below the warn threshold, otherwise the
seconds until the 5h window resets (+120s buffer). On error it prints
`{"error":"no-data",...}` — treat that as "skip the gate, don't block".

**Recurring loops** (`/loop` and similar): at the top of each iteration, read
`suggested_defer_seconds`. If it is positive, skip the iteration's real work
and schedule the next wake-up past the reset instead — the loop's cadence
routes itself around the exhausted window, no checkpointing needed. Note that
self-scheduling wake-ups are often capped (e.g. 3600s); for longer waits chain
several idle wake-ups or hand off to `quota_alarm.sh` (uncapped).

**Multi-phase workflows**: check the gate at phase boundaries — the cleanest
point to park, since "in progress / unverified" is naturally empty and resume
starts exactly at phase N+1. A ready-made pattern ships in
[`patterns/quota-phase-gate.md`](patterns/quota-phase-gate.md); copy it to
`~/.claude/patterns/` and (if you use the patterns toolchain) declare its
patch-anchor in your workflow patterns to backfill the gate into already
instantiated commands via `/patterns --patch`.

**Subagents**: the hook fires in subagent sessions too, but an alarm started
inside a subagent orphans when the subagent exits. The skill instructs
subagents to wind down and report back instead of archiving — the main
session owns that decision.

## Boundaries

- **Subscription (Pro/Max) accounts only.** API-key accounts have no quota windows; the plugin detects this and stays dormant — zero overhead, zero noise.
- The primary sampler uses the undocumented `oauth/usage` endpoint; every response is schema-validated and any mismatch falls back to silence, never false alerts.
- Quota is account-level: keep concurrently parked long tasks to ≤2 (wake jitter prevents stampedes, but they still share one window).
- If the 7-day window is exhausted, a 5h reset will not help; waits longer than `max_wait_hours` notify you and stop instead of idling for days.

## Development

```bash
tests/run_tests.sh    # 31 unit tests: sampling, gating, burn-rate, statusline, alarm, --json, install roundtrip
```

## Changelog

### v0.2.1 (2026-07-13)

Field-incident fixes — a fast burn (8%/min from parallel subagents) cut a session down 35s after the critical alert; the checkpoint got written but the alarm never started:

| Item | Change |
|------|--------|
| Alarm-first ordering | archive protocol reversed: start the alarm (one cheap Bash call) *before* writing the checkpoint; hook alert text matches |
| Burn-rate escalation | the gate projects time-to-burnout from recent samples; ≤3 min → critical regardless of current %, ≤10 min → warn (`ttb_critical_minutes` / `ttb_warn_minutes`) |
| Wake-up resilience | missing/truncated checkpoint after a cut-off archive → reconstruct state from conversation context |

### v0.2.0 (2026-07-12)

Integration release — quota awareness for loops, workflows, and subagents:

| Item | Change |
|------|--------|
| `quota_report.sh --json` | machine-readable output with `suggested_defer_seconds` for scheduling decisions |
| Subagent branch | skill now instructs subagents to wind down and report back instead of starting orphan alarms |
| `patterns/quota-phase-gate.md` | ready-made phase-boundary gate pattern with patch-anchor for the patterns toolchain |
| README Integrations | loop / workflow / subagent integration guide |

### v0.1.0 (2026-07-11)

Initial release: oauth/usage + statusline sampling, PostToolUse alert hook, archive/alarm/wake skill protocol, /quota command, dual install paths.

MIT License.
