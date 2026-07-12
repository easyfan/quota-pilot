#!/bin/bash
# quota-pilot O1 验证原型：oauth/usage 端点采样（2026-07-10 实测可用）
# 用法：./sample_usage.sh  → stdout 输出 JSON
# 凭据：macOS Keychain（Linux 改读 ~/.claude/.credentials.json）
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])" 2>/dev/null)
[ -z "$TOKEN" ] && { echo '{"error":"no-token"}' >&2; exit 1; }
curl -s -m 15 "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20"
