#!/bin/bash
# Usage: claude-session "task name" [session-id]
# Set CLAUDE_LAUNCHER=happy to use Happy Coder instead of claude
# Creates/restores tmux session and registers it in VS Code Restore Terminals

SESSION_NAME="$1"
SESSION_ID="$2"
LAUNCHER="${CLAUDE_LAUNCHER:-claude}"  # default: claude, set to "happy" for Happy Coder
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

# Only kill if session exists but was started with a DIFFERENT session ID
# (detect via the restore command that would have been used)
if [ -n "$SESSION_ID" ] && [ "$SESSION_EXISTS" = "true" ]; then
  RUNNING_CMD=$(tmux display-message -t "$SESSION_NAME" -p '#{pane_start_command}' 2>/dev/null || true)
  if echo "$RUNNING_CMD" | grep -qF "$SESSION_ID"; then
    echo "Attached session: $SESSION_NAME (session ID unchanged)"
  else
    tmux kill-session -t "$SESSION_NAME"
    SESSION_EXISTS=false
    echo "Killed existing session to load new session ID: $SESSION_ID"
  fi
fi

if [ "$SESSION_EXISTS" = "false" ]; then
  if [ "$LAUNCHER" = "happy" ] && [ -n "$SESSION_ID" ]; then
    CLAUDE_CMD="happy --yolo --resume '$SESSION_ID'"
  elif [ "$LAUNCHER" = "happy" ]; then
    CLAUDE_CMD="happy --yolo --continue"
  elif [ -n "$SESSION_ID" ]; then
    CLAUDE_CMD="claude --dangerously-skip-permissions --resume '$SESSION_ID'"
  else
    CLAUDE_CMD="claude --dangerously-skip-permissions --continue"
  fi

  # Create a symlink ~/claude-sessions/<SESSION_NAME> -> ~/Documents/GitHub
  # so Happy shows the session name instead of "GitHub"
  SESSION_DIR="$HOME/claude-sessions/$SESSION_NAME"
  mkdir -p "$HOME/claude-sessions"
  if [ ! -e "$SESSION_DIR" ]; then
    ln -s "$HOME/Documents/GitHub" "$SESSION_DIR"
  fi

  if ! tmux new-session -d -s "$SESSION_NAME" -c "$SESSION_DIR" "$CLAUDE_CMD"; then
    echo "Error: failed to create tmux session '$SESSION_NAME'" >&2
    exit 1
  fi
  echo "New session: $SESSION_NAME"
else
  echo "Restored session: $SESSION_NAME"
fi

python3 - "$SESSION_NAME" "${SESSION_ID}" "$VSCODE_SETTINGS" "$LAUNCHER" << 'PYTHON'
import json, sys, os, tempfile

session_name = sys.argv[1]
session_id   = sys.argv[2]  # may be empty string
settings_path = sys.argv[3]
launcher      = sys.argv[4]  # "claude" or "happy"

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    settings = {}

terminals = settings.get("restoreTerminals.terminals", [])

safe_name = session_name.replace("'", "'\\''")
cmd_prefix = "happy-session" if launcher == "happy" else "claude-session"
restore_cmd = f"{cmd_prefix} '{safe_name}' '{session_id}'" if session_id else f"{cmd_prefix} '{safe_name}'"

# Find existing entry for this session name
existing_entry = None
for t in terminals:
    for st in t.get("splitTerminals", []):
        if st.get("name") == session_name:
            existing_entry = st
            break

changed = False

if existing_entry is None:
    # Not registered yet — add it
    terminals.append({
        "splitTerminals": [
            {"name": session_name, "commands": [restore_cmd]}
        ]
    })
    settings["restoreTerminals.terminals"] = terminals
    changed = True
elif existing_entry.get("commands", [""]) [0] != restore_cmd:
    # Already registered but restore command changed (e.g. new session ID)
    existing_entry["commands"] = [restore_cmd]
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
