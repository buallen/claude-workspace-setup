#!/bin/bash
# L4 Ralph Wiggum Loop - Stop Hook
# Checks tasks.md in current directory; blocks exit if pending tasks remain
# Circuit Breaker: 3 consecutive quality failures → trip → send-lark + stop

TASKS_FILE="$PWD/tasks.md"
MAX_ITERATIONS=100
HASH=$(pwd | shasum | cut -c1-8)
COUNTER_FILE="/tmp/claude_loop_${HASH}"
FAIL_FILE="/tmp/claude_loop_fail_${HASH}"
MAX_CONSECUTIVE_FAILS=3

if [ ! -f "$TASKS_FILE" ]; then
  rm -f "$COUNTER_FILE" "$FAIL_FILE"
  exit 0
fi

NEXT_TASK=$(grep -m1 "^- \[ \]" "$TASKS_FILE" 2>/dev/null)

if [ -z "$NEXT_TASK" ]; then
  rm -f "$COUNTER_FILE" "$FAIL_FILE"
  printf '{"systemMessage": "All tasks completed! Loop ended."}\n'
  exit 0
fi

count=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)

if [ "$count" -ge "$MAX_ITERATIONS" ]; then
  rm -f "$COUNTER_FILE" "$FAIL_FILE"
  printf '{"systemMessage": "Max iterations (%d) reached. Loop stopped."}\n' "$MAX_ITERATIONS"
  exit 0
fi

# --- Circuit Breaker ---
fail_count=$(cat "$FAIL_FILE" 2>/dev/null || echo 0)
PREV_TASK_ID=$(echo "$NEXT_TASK" | grep -o 'T[0-9]*' | head -1)
PREV_SNAPSHOT="/tmp/claude_loop_snap_${HASH}"

if [ -f "$PREV_SNAPSHOT" ]; then
  OLD_SNAP=$(cat "$PREV_SNAPSHOT")
  NEW_SNAP=$(grep -c "^- \[ \]" "$TASKS_FILE" 2>/dev/null || echo 0)
  if [ "$OLD_SNAP" = "$NEW_SNAP" ]; then
    fail_count=$((fail_count + 1))
    echo "$fail_count" > "$FAIL_FILE"
  else
    echo 0 > "$FAIL_FILE"
    fail_count=0
  fi
fi
grep -c "^- \[ \]" "$TASKS_FILE" 2>/dev/null > "$PREV_SNAPSHOT" || echo 0 > "$PREV_SNAPSHOT"

if [ "$fail_count" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
  rm -f "$COUNTER_FILE" "$FAIL_FILE" "$PREV_SNAPSHOT"
  TRIP_MSG="Circuit breaker tripped after $MAX_CONSECUTIVE_FAILS consecutive failures on task ${PREV_TASK_ID:-unknown}. Loop stopped. Review tasks.md and retry."
  printf '{"systemMessage": "%s"}\n' "$TRIP_MSG"
  exit 0
fi

count=$((count + 1))
echo "$count" > "$COUNTER_FILE"

TASK_CONTENT=$(echo "$NEXT_TASK" | sed 's/^- \[ \] //; s/\r//')
CONTEXT="[Loop $count/$MAX_ITERATIONS | fails=$fail_count/$MAX_CONSECUTIVE_FAILS] Execute the next pending task from tasks.md:\n\n$TASK_CONTENT\n\nWhen done, mark it as [x] in tasks.md, then end this turn."
CONTEXT_JSON=$(printf '%s' "$CONTEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

printf '{"decision":"block","reason":"Pending tasks remain","systemMessage":%s}\n' "$CONTEXT_JSON"
