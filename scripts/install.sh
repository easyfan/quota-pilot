#!/usr/bin/env bash
# install.sh — quota-pilot plugin installer
# Usage: ./install.sh [--dry-run] [--uninstall] [--statusline] [--target=<path>]
# Options:
#   --dry-run          Preview changes without writing
#   --uninstall        Remove installed files and deregister the hook
#   --statusline       Also install the statusline wrapper (TUI quota display).
#                      An existing statusLine command is preserved: it is saved
#                      as statusline_passthrough and keeps rendering through
#                      the wrapper.
#   --target=<path>    Custom Claude config directory (default: ~/.claude)
#   CLAUDE_DIR=<path>  Alternative to --target

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(dirname "$SCRIPT_DIR")"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
DRY_RUN=false
UNINSTALL=false
STATUSLINE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --uninstall)  UNINSTALL=true ;;
    --statusline) STATUSLINE=true ;;
    --target=*)   CLAUDE_DIR="${arg#*=}" ;;
  esac
done

BIN_DIR="$CLAUDE_DIR/quota-pilot/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG="$CLAUDE_DIR/quota-pilot/config.json"
HOOK_CMD="$BIN_DIR/quota_gate.sh"
RECOVER_CMD="$BIN_DIR/quota_recover.sh"
SL_CMD="$BIN_DIR/statusline.sh"

# Flat bin layout: quota_gate.sh finds sample_usage.sh next to itself
BIN_FILES=(
  "hooks/quota_gate.sh"
  "hooks/quota_recover.sh"
  "scripts/sample_usage.sh"
  "scripts/statusline.sh"
  "scripts/quota_alarm.sh"
  "scripts/quota_report.sh"
)

# ── settings.json surgery (idempotent, backed up) ─────────────────────────────
edit_settings() {  # $1 = install | uninstall
  local mode="$1"
  $DRY_RUN && { echo "[dry-run] would $mode hook/statusline entries in $SETTINGS"; return; }
  # Nothing to deregister (and no parent dir to write into) on a machine that
  # never had a settings.json — uninstall must stay a clean no-op there.
  if [ "$mode" = uninstall ] && [ ! -f "$SETTINGS" ]; then
    echo "  No $SETTINGS — nothing to deregister"
    return 0
  fi
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-quota-pilot"
  MODE="$mode" SETTINGS="$SETTINGS" HOOK_CMD="$HOOK_CMD" RECOVER_CMD="$RECOVER_CMD" \
  SL_CMD="$SL_CMD" CONFIG="$CONFIG" STATUSLINE="$STATUSLINE" python3 <<'PY'
import json, os

mode = os.environ["MODE"]
settings_path = os.environ["SETTINGS"]
hook_cmd = os.environ["HOOK_CMD"]
recover_cmd = os.environ["RECOVER_CMD"]
sl_cmd = os.environ["SL_CMD"]
config_path = os.environ["CONFIG"]
want_statusline = os.environ["STATUSLINE"] == "true"

try:
    with open(settings_path) as f:
        settings = json.load(f)
except Exception:
    settings = {}

def load_config():
    try:
        with open(config_path) as f:
            return json.load(f)
    except Exception:
        return {}

def save(obj, path):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)

post = settings.setdefault("hooks", {}).setdefault("PostToolUse", [])

if mode == "install":
    if not any(h.get("command") == hook_cmd
               for e in post for h in e.get("hooks", [])):
        post.append({"matcher": "*",
                     "hooks": [{"type": "command", "command": hook_cmd}]})
        print(f"  Registered PostToolUse hook: {hook_cmd}")
    else:
        print("  PostToolUse hook already registered")

    ss = settings["hooks"].setdefault("SessionStart", [])
    if not any(h.get("command") == recover_cmd
               for e in ss for h in e.get("hooks", [])):
        ss.append({"hooks": [{"type": "command", "command": recover_cmd}]})
        print(f"  Registered SessionStart hook: {recover_cmd}")
    else:
        print("  SessionStart hook already registered")

    if want_statusline:
        cur = settings.get("statusLine", {})
        cur_cmd = cur.get("command", "")
        if cur_cmd and cur_cmd != sl_cmd:
            cfg = load_config()
            cfg["statusline_passthrough"] = cur_cmd
            os.makedirs(os.path.dirname(config_path), exist_ok=True)
            save(cfg, config_path)
            print(f"  Preserved existing statusline as passthrough: {cur_cmd}")
        settings["statusLine"] = {"type": "command", "command": sl_cmd}
        print(f"  Installed statusline wrapper: {sl_cmd}")
else:
    settings["hooks"]["PostToolUse"] = [
        e for e in post
        if not any(h.get("command") == hook_cmd for h in e.get("hooks", []))]
    if not settings["hooks"]["PostToolUse"]:
        del settings["hooks"]["PostToolUse"]
    print("  Deregistered PostToolUse hook")

    ss = settings["hooks"].get("SessionStart", [])
    settings["hooks"]["SessionStart"] = [
        e for e in ss
        if not any(h.get("command") == recover_cmd for h in e.get("hooks", []))]
    if not settings["hooks"]["SessionStart"]:
        del settings["hooks"]["SessionStart"]
    print("  Deregistered SessionStart hook")

    if not settings["hooks"]:
        del settings["hooks"]

    if settings.get("statusLine", {}).get("command") == sl_cmd:
        original = load_config().get("statusline_passthrough", "")
        if original:
            settings["statusLine"] = {"type": "command", "command": original}
            print(f"  Restored original statusline: {original}")
        else:
            del settings["statusLine"]
            print("  Removed statusline wrapper")

save(settings, settings_path)
PY
}

# ── Uninstall ──────────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = true ]; then
  echo "Uninstalling quota-pilot..."
  edit_settings uninstall
  for f in "$BIN_DIR"/*.sh "$CLAUDE_DIR/commands/quota.md"; do
    if [ -f "$f" ]; then
      $DRY_RUN && echo "[dry-run] rm $f" || rm "$f"
      echo "  Removed $f"
    fi
  done
  if [ -d "$CLAUDE_DIR/skills/quota-pilot" ]; then
    $DRY_RUN && echo "[dry-run] rm -rf $CLAUDE_DIR/skills/quota-pilot" \
             || rm -rf "$CLAUDE_DIR/skills/quota-pilot"
    echo "  Removed $CLAUDE_DIR/skills/quota-pilot"
  fi
  # state (~/.claude/quota-pilot/{state,history,config}) is left in place on
  # purpose — it is user data; delete manually if unwanted
  echo "Uninstall complete. State kept at $CLAUDE_DIR/quota-pilot/ (remove manually if unwanted)."
  exit 0
fi

# ── Install ────────────────────────────────────────────────────────────────────
echo "Installing quota-pilot..."

# Count only files whose content actually changes, so a re-install reports
# "Done! 0" (idempotency signal the deployment verifier checks). The count is
# emitted as ONE summary line — not one line per file — because the verifier
# extracts it with `grep -oE '[0-9]+ file'` and then does an integer compare;
# multiple "N file" lines become a multi-line string that breaks that compare.
MODIFIED=0

install_one() {  # $1=src  $2=dst  $3=(optional) "dir"
  local src="$1" dst="$2" isdir="${3:-}"
  if [ -n "$isdir" ]; then
    [ -d "$dst" ] && diff -rq "$src" "$dst" >/dev/null 2>&1 && return  # unchanged
  else
    cmp -s "$src" "$dst" && return  # unchanged
  fi
  MODIFIED=$((MODIFIED + 1))
  $DRY_RUN && { echo "  would modify: $dst"; return; }
  if [ -n "$isdir" ]; then
    rm -rf "$dst"; mkdir -p "$dst"; cp -r "$src/." "$dst/"
  else
    mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"; chmod +x "$dst"
  fi
}

$DRY_RUN || mkdir -p "$BIN_DIR" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/skills"

for rel in "${BIN_FILES[@]}"; do
  install_one "$PLUGIN_DIR/$rel" "$BIN_DIR/$(basename "$rel")"
done
install_one "$PLUGIN_DIR/skills/quota-pilot" "$CLAUDE_DIR/skills/quota-pilot" dir
install_one "$PLUGIN_DIR/commands/quota.md" "$CLAUDE_DIR/commands/quota.md"

edit_settings install

if $DRY_RUN; then
  echo "Dry run: $MODIFIED file(s) would be modified. No files written."
else
  echo ""
  echo "Done! $MODIFIED file(s) installed."
  echo "Restart Claude Code (or start a new session) to activate the hook."
  echo "Check quota anytime with: /quota"
  $STATUSLINE || echo "Tip: rerun with --statusline to add the TUI quota display."
fi
