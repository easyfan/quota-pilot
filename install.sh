#!/usr/bin/env bash
# install.sh — quota-pilot plugin installer (entry point)
# Delegates to scripts/install.sh
# Usage: ./install.sh [--dry-run] [--uninstall] [--statusline] [--target=<path>]
#   --dry-run          Preview changes without writing
#   --uninstall        Remove installed files and deregister the hook
#   --statusline       Also install the statusline wrapper (TUI quota display)
#   --target=<path>    Custom Claude config directory (default: ~/.claude)
#   CLAUDE_DIR=<path>  Alternative to --target

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for arg in "$@"; do
  case "$arg" in
    --target=*) export CLAUDE_DIR="${arg#--target=}" ;;
  esac
done

exec bash "$SCRIPT_DIR/scripts/install.sh" "$@"
