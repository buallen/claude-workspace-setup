#!/bin/bash
# run-overnight.sh — Ralph loop for happy-session
# Usage: ./run-overnight.sh
# Keeps running Claude until COMPLETED.md exists or max iterations reached.

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_ITERATIONS=20
ITERATION=0
WAIT_ON_FAIL=600  # 10 min wait if Claude exits unexpectedly (quota exhaustion)

cd "$PROJECT_DIR"

echo "========================================"
echo "  happy-session overnight build"
echo "  Project: $PROJECT_DIR"
echo "  Max iterations: $MAX_ITERATIONS"
echo "  Started: $(date)"
echo "========================================"

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
  ITERATION=$((ITERATION + 1))
  echo ""
  echo "--- Iteration $ITERATION / $MAX_ITERATIONS — $(date) ---"

  # Stop if already completed
  if [ -f "$PROJECT_DIR/COMPLETED.md" ]; then
    echo "COMPLETED.md found — all done!"
    cat "$PROJECT_DIR/COMPLETED.md"
    exit 0
  fi

  # Run Claude
  claude --dangerously-skip-permissions \
    "You are working on the happy-session CLI project.
Read tasks.md to find the next incomplete task (- [ ]).
Complete it following the quality standards in CLAUDE.md.
Run feedback loops (tsc --noEmit && vitest run && eslint src/) before marking done.
Commit each completed task with git.
If COMPLETED.md already exists, stop.
Work on ONE task per run, then stop so the loop can restart you."

  EXIT_CODE=$?

  if [ -f "$PROJECT_DIR/COMPLETED.md" ]; then
    echo "COMPLETED.md found after iteration $ITERATION — done!"
    cat "$PROJECT_DIR/COMPLETED.md"
    exit 0
  fi

  if [ $EXIT_CODE -ne 0 ]; then
    echo "Claude exited with code $EXIT_CODE (possibly quota exhausted)"
    echo "Waiting ${WAIT_ON_FAIL}s before retry..."
    sleep $WAIT_ON_FAIL
  else
    echo "Claude finished iteration $ITERATION normally"
    sleep 5  # brief pause between iterations
  fi
done

echo "Reached max iterations ($MAX_ITERATIONS). Check tasks.md for progress."
exit 1
