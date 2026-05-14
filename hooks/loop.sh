#!/bin/bash
# L4 Ralph Wiggum Loop - Stop Hook
# Checks tasks.md in current directory; blocks exit if pending tasks remain

TASKS_FILE="$PWD/tasks.md"
MAX_ITERATIONS=100
COUNTER_FILE="/tmp/claude_loop_$(pwd | shasum | cut -c1-8)"

if [ ! -f "$TASKS_FILE" ]; then
  rm -f "$COUNTER_FILE"
  exit 0
fi

NEXT_TASK=$(grep -m1 "^- \[ \]" "$TASKS_FILE" 2>/dev/null)

if [ -z "$NEXT_TASK" ]; then
  rm -f "$COUNTER_FILE"
  printf '{"systemMessage": "All tasks completed! Loop ended."}\n'
  exit 0
fi

count=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)

if [ "$count" -ge "$MAX_ITERATIONS" ]; then
  rm -f "$COUNTER_FILE"
  printf '{"systemMessage": "Max iterations (%d) reached. Loop stopped."}\n' "$MAX_ITERATIONS"
  exit 0
fi

count=$((count + 1))
echo "$count" > "$COUNTER_FILE"

TASK_CONTENT=$(echo "$NEXT_TASK" | sed 's/^- \[ \] //; s/\r//')
CONTEXT="[Loop $count/$MAX_ITERATIONS] Execute the next pending task from tasks.md:\n\n$TASK_CONTENT\n\nWhen done, mark it as [x] in tasks.md, then end this turn."
CONTEXT_JSON=$(printf '%s' "$CONTEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

printf '{"decision":"block","reason":"Pending tasks remain","systemMessage":%s}\n' "$CONTEXT_JSON"
