#!/bin/bash
# Post-Compaction Hook — re-inject critical context after compaction
# Reads current agent-status.json and injects active pipeline summary

STATUS_FILE="$HOME/.claude/agent-status.json"

if [ ! -f "$STATUS_FILE" ]; then
  exit 0
fi

SUMMARY=$(python3 -c "
import json, sys
with open('$STATUS_FILE') as f:
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
" 2>/dev/null)

if [ -n "$SUMMARY" ]; then
  printf '%s' "$SUMMARY"
fi
