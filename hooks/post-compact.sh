#!/bin/bash
# Post-Compaction Hook — re-inject critical context after compaction
# Reads current agent-status.json and injects active pipeline summary

CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
STATUS_FILE="$CONFIG_DIR/agent-status.json"
if [ "$CONFIG_DIR" = "$HOME/.claude-private" ]; then
  STATUS_FILE=$(python3 "$(dirname "${BASH_SOURCE[0]}")/../lib/personal_history.py" --context-file agent-status.json) || exit 1
fi

if [ ! -f "$STATUS_FILE" ]; then
  exit 0
fi

SUMMARY=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
pipelines = data.get('pipelines', {})
active = {k: v for k, v in pipelines.items() if v.get('stage') not in ('done', 'failed', 'cancelled', 'idle')}
if not active:
    sys.exit(0)
lines = ['Active pipelines after compaction:']
for ref, p in active.items():
    goal = p.get('original_goal', p.get('summary', ''))
    lines.append(f'  - {ref}: stage={p[\"stage\"]}, goal={goal[:80]}')
print('\n'.join(lines))
" "$STATUS_FILE" 2>/dev/null)

if [ -n "$SUMMARY" ]; then
  printf '%s' "$SUMMARY"
fi
