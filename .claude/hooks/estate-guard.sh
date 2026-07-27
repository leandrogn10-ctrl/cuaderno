#!/bin/bash
# Stop hook for cuaderno. When index.html changed (vs upstream):
# 1) HARD: sw.js CACHE_NAME must be bumped alongside it (clients pin the old shell).
# 2) REMINDER: deploy gate — every HARNESS: line in test-harness.html must PASS
#    (run headless) before pushing; backports from app-shell stay structurally identical.
input=$(cat)
[[ $(printf '%s' "$input" | jq -r '.stop_hook_active // false') == "true" ]] && exit 0

cd "$CLAUDE_PROJECT_DIR" || exit 0
BASE=HEAD
git rev-parse --verify -q '@{u}' >/dev/null 2>&1 && BASE='@{u}'
git diff --quiet "$BASE" -- index.html 2>/dev/null && exit 0

if ! git diff "$BASE" -- sw.js 2>/dev/null | grep -q '^[+-].*CACHE_NAME'; then
  echo "SHIP RULE: index.html changed (vs $BASE) but sw.js CACHE_NAME is unbumped — clients will pin the old shell. Bump it if you made this change; if it predates your turn (Leandro's in-progress edit), do NOT bump — flag it to him." >&2
  exit 2
fi
echo "DEPLOY GATE REMINDER (not an error): index.html changed. Before any push, every HARNESS: line in test-harness.html must PASS — run it headless, don't eyeball. If this change touches sync/SW/callClaude/settings blocks, it must stay structurally identical to app-shell/shell.html. Acknowledge to Leandro, then end the turn." >&2
exit 2
