#!/bin/bash
# Usage: end-session "task name"
# Kills tmux session and removes it from VS Code Restore Terminals

SESSION_NAME="$1"
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"

if [ -z "$SESSION_NAME" ]; then
  echo "Usage: end-session <task-name>"
  echo ""
  echo "Running sessions:"
  tmux list-sessions 2>/dev/null | awk -F: '{print "  " $1}' || echo "  (none)"
  exit 1
fi

tmux kill-session -t "$SESSION_NAME" 2>/dev/null && echo "Killed session: $SESSION_NAME" || echo "No running session: $SESSION_NAME"

python3 - "$SESSION_NAME" "$VSCODE_SETTINGS" << 'PYTHON'
import json, sys, os, tempfile

session_name = sys.argv[1]
settings_path = sys.argv[2]

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(0)

terminals = settings.get("restoreTerminals.terminals", [])
new_terminals = [
    t for t in terminals
    if not any(st.get("name") == session_name for st in t.get("splitTerminals", []))
]

if len(new_terminals) == len(terminals):
    print(f"Not found in VS Code restore list: {session_name}")
    sys.exit(0)

settings["restoreTerminals.terminals"] = new_terminals

dir_ = os.path.dirname(settings_path)
with tempfile.NamedTemporaryFile('w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(settings, tf, indent=2, ensure_ascii=False)
    tmp_path = tf.name
os.replace(tmp_path, settings_path)

print(f"Removed from VS Code restore list: {session_name}")
PYTHON
