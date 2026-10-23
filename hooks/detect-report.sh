#!/bin/bash
# PostToolUse hook: fires after every Write tool call.
# Detects report-pattern files and sets /tmp/claude-discuss-pending for auto-trigger.
# Claude Code passes tool data via stdin as JSON.

set -euo pipefail

INPUT=$(cat)

# Extract file_path from Write tool input
FILE_PATH=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('file_path', ''))
except:
    print('')
" 2>/dev/null || echo "")

[ -z "$FILE_PATH" ] && exit 0

# Expand ~ to home directory
FILE_PATH="${FILE_PATH/#\~/$HOME}"

# Match report-pattern filenames
if echo "$FILE_PATH" | grep -qE \
  "(bq-full-test|bq-debug|bq-view-opt|csv-compare-all|bq-view-optimize-all|REPORT-|report-[0-9]{8}|bq-.*report.*[0-9]{8}).*\.md$"; then

  # Only flag if file is substantial (>2KB — skip tiny stubs)
  SIZE=0
  if [ -f "$FILE_PATH" ]; then
    SIZE=$(wc -c < "$FILE_PATH" 2>/dev/null || echo 0)
  fi

  if [ "$SIZE" -gt 2000 ]; then
    CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    FLAG_FILE="/tmp/claude-discuss-pending"
    if [ "$CONFIG_DIR" = "$HOME/.claude-private" ]; then
      FLAG_FILE=$(python3 "$(dirname "${BASH_SOURCE[0]}")/../lib/personal_history.py" --context-file discuss-pending)
    elif [ "$CONFIG_DIR" != "$HOME/.claude" ]; then
      FLAG_FILE="$CONFIG_DIR/discuss-pending"
    fi
    python3 "$(dirname "${BASH_SOURCE[0]}")/../lib/report_state.py" put "$FLAG_FILE" "$FILE_PATH"
  fi
fi

exit 0  # PostToolUse hooks must not block
