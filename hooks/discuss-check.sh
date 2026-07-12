#!/bin/bash
# Stop hook: if a report was just generated (flagged by detect-report.sh),
# auto-trigger /discuss. Yields to loop.sh if there are pending tasks.

FLAG_FILE="/tmp/claude-discuss-pending"

[ -f "$FLAG_FILE" ] || exit 0

# Yield to loop.sh when pending tasks exist (loop has priority)
TASKS_FILE="$PWD/tasks.md"
if [ -f "$TASKS_FILE" ]; then
  NEXT_TASK=$(grep -m1 "^- \[ \]" "$TASKS_FILE" 2>/dev/null)
  if [ -n "$NEXT_TASK" ]; then
    exit 0
  fi
fi

REPORT_PATH=$(cat "$FLAG_FILE")
rm -f "$FLAG_FILE"

MSG="一份报告刚刚生成：${REPORT_PATH}\n\n现在请执行 /discuss skill，参数为 auto-triggered:${REPORT_PATH}，对这份报告开启启发式讨论。"
MSG_JSON=$(printf '%s' "$MSG" | python3 -c 'import sys, json; print(json.dumps(sys.stdin.read()))')

printf '{"decision":"block","reason":"Report generated — starting /discuss","systemMessage":%s}\n' "$MSG_JSON"
