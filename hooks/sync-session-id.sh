#!/bin/bash
# Stop Hook: sync current Claude session ID back to VS Code restore command
# Runs after every Claude session ends (including after /clear)

VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"

# Read session_id from hook payload stdin
PAYLOAD=$(cat)
SESSION_ID=$(echo "$PAYLOAD" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('session_id',''))" 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0

# Get current tmux session name
TMUX_SESSION=$(tmux display-message -p '#S' 2>/dev/null)

[ -z "$TMUX_SESSION" ] && exit 0

# Update VS Code restore command for this session
python3 - "$TMUX_SESSION" "$SESSION_ID" "$VSCODE_SETTINGS" << 'PYTHON'
import json, sys, os, tempfile

session_name, session_id, settings_path = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    sys.exit(0)

terminals = settings.get("restoreTerminals.terminals", [])
safe_name = session_name.replace("'", "'\\''")

# Detect launcher (happy or claude) from existing command
launcher = "claude-session"
for t in terminals:
    for st in t.get("splitTerminals", []):
        if st.get("name") == session_name:
            existing = st.get("commands", [""])[0]
            if existing.startswith("happy-session"):
                launcher = "happy-session"
            break

new_cmd = f"{launcher} '{safe_name}' '{session_id}'"

changed = False
for t in terminals:
    for st in t.get("splitTerminals", []):
        if st.get("name") == session_name:
            if st.get("commands", [""])[0] != new_cmd:
                st["commands"] = [new_cmd]
                changed = True
            break

if changed:
    dir_ = os.path.dirname(settings_path)
    with tempfile.NamedTemporaryFile('w', dir=dir_, delete=False, suffix='.tmp') as tf:
        json.dump(settings, tf, indent=2, ensure_ascii=False)
        tmp = tf.name
    os.replace(tmp, settings_path)
    print(f"Updated session ID for '{session_name}': {session_id}")
PYTHON

exit 0
