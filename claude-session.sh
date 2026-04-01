#!/bin/bash
# Usage: claude-session "task name"
# Creates/restores tmux session and registers it in VS Code Restore Terminals

SESSION_NAME="$1"
SESSION_ID="$2"
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"

if [ -z "$SESSION_NAME" ]; then
  echo "Usage: claude-session <task-name> [session-id]"
  echo ""
  echo "Running sessions:"
  tmux list-sessions 2>/dev/null | awk -F: '{print "  " $1}' || echo "  (none)"
  exit 1
fi

echo -ne "\033]0;${SESSION_NAME}\007"

if ! tmux has-session -s "$SESSION_NAME" 2>/dev/null; then
  if [ -n "$SESSION_ID" ]; then
    CLAUDE_CMD="claude --dangerously-skip-permissions --resume '$SESSION_ID'"
  else
    CLAUDE_CMD="claude --dangerously-skip-permissions --continue"
  fi
  tmux new-session -d -s "$SESSION_NAME" -c "$HOME/Documents/GitHub" "$CLAUDE_CMD"
  echo "New session: $SESSION_NAME"
else
  echo "Restored session: $SESSION_NAME"
fi

python3 - "$SESSION_NAME" "$VSCODE_SETTINGS" << 'PYTHON'
import json, sys

session_name = sys.argv[1]
settings_path = sys.argv[2]

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except:
    settings = {}

terminals = settings.get("restoreTerminals.terminals", [])

already_registered = any(
    st.get("name") == session_name
    for t in terminals
    for st in t.get("splitTerminals", [])
)

if not already_registered:
    terminals.append({
        "splitTerminals": [
            {"name": session_name, "commands": [f"claude-session '{session_name}'"]}
        ]
    })
    settings["restoreTerminals.terminals"] = terminals

# Ensure VS Code uses escape sequence for tab titles
settings["terminal.integrated.tabs.title"] = "${sequence}"

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
PYTHON

tmux attach -t "$SESSION_NAME"
