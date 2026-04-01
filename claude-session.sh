#!/bin/bash
# Usage: claude-session "task name" [session-id]
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

SESSION_EXISTS=false
tmux has-session -t "$SESSION_NAME" 2>/dev/null && SESSION_EXISTS=true

if [ -n "$SESSION_ID" ] && [ "$SESSION_EXISTS" = "true" ]; then
  tmux kill-session -t "$SESSION_NAME"
  SESSION_EXISTS=false
  echo "Killed existing session to load session ID: $SESSION_ID"
fi

if [ "$SESSION_EXISTS" = "false" ]; then
  if [ -n "$SESSION_ID" ]; then
    CLAUDE_CMD="claude --dangerously-skip-permissions --resume '$SESSION_ID'"
  else
    CLAUDE_CMD="claude --dangerously-skip-permissions --continue"
  fi
  if ! tmux new-session -d -s "$SESSION_NAME" -c "$HOME/Documents/GitHub" "$CLAUDE_CMD"; then
    echo "Error: failed to create tmux session '$SESSION_NAME'" >&2
    exit 1
  fi
  echo "New session: $SESSION_NAME"
else
  echo "Restored session: $SESSION_NAME"
fi

python3 - "$SESSION_NAME" "$VSCODE_SETTINGS" << 'PYTHON'
import json, sys, os, tempfile

session_name = sys.argv[1]
settings_path = sys.argv[2]

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    settings = {}

terminals = settings.get("restoreTerminals.terminals", [])

already_registered = any(
    st.get("name") == session_name
    for t in terminals
    for st in t.get("splitTerminals", [])
)

changed = False

if not already_registered:
    safe_name = session_name.replace("'", "'\\''")
    terminals.append({
        "splitTerminals": [
            {"name": session_name, "commands": [f"claude-session '{safe_name}'"]}
        ]
    })
    settings["restoreTerminals.terminals"] = terminals
    changed = True

if settings.get("terminal.integrated.tabs.title") != "${sequence}":
    settings["terminal.integrated.tabs.title"] = "${sequence}"
    changed = True

if changed:
    dir_ = os.path.dirname(settings_path)
    with tempfile.NamedTemporaryFile('w', dir=dir_, delete=False, suffix='.tmp') as tf:
        json.dump(settings, tf, indent=2, ensure_ascii=False)
        tmp_path = tf.name
    os.replace(tmp_path, settings_path)
PYTHON

if [ -n "$TMUX" ]; then
  tmux switch-client -t "$SESSION_NAME"
else
  tmux attach -t "$SESSION_NAME"
fi
