#!/bin/bash
# Claude Code Persistent Workspace - One-Click Setup Script
# Run this on any new Mac to get the full workspace setup

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${YELLOW}[..] $1${NC}"; }
err()  { echo -e "${RED}[!!] $1${NC}"; }

echo ""
echo "====================================="
echo " Claude Code Persistent Workspace"
echo " One-Click Setup"
echo "====================================="
echo ""

# ── Step 1: Install tmux ──────────────────────────────────────────────────────
info "Checking tmux..."
if command -v tmux &>/dev/null; then
  ok "tmux already installed: $(tmux -V)"
else
  info "Installing tmux via Homebrew..."
  if ! command -v brew &>/dev/null; then
    err "Homebrew not found. Install it first: https://brew.sh"
    exit 1
  fi
  brew install tmux
  ok "tmux installed: $(tmux -V)"
fi

# ── Step 2: Create ~/.claude directory structure ──────────────────────────────
info "Creating ~/.claude/hooks/ directory..."
mkdir -p ~/.claude/hooks
ok "Directory ready"

# ── Step 3: Write loop.sh (L4 Stop Hook) ─────────────────────────────────────
info "Writing ~/.claude/hooks/loop.sh..."
cat > ~/.claude/hooks/loop.sh << 'LOOP_EOF'
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

TASK_CONTENT=$(echo "$NEXT_TASK" | sed 's/^- \[ \] //')
CONTEXT="[Loop $count/$MAX_ITERATIONS] Execute the next pending task from tasks.md:\n\n$TASK_CONTENT\n\nWhen done, mark it as [x] in tasks.md, then end this turn."
CONTEXT_JSON=$(printf '%s' "$CONTEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

printf '{"decision":"block","reason":"Pending tasks remain","systemMessage":%s}\n' "$CONTEXT_JSON"
LOOP_EOF
chmod +x ~/.claude/hooks/loop.sh
ok "loop.sh written"

# ── Step 4: Write claude-session.sh ──────────────────────────────────────────
info "Writing ~/.claude/claude-session.sh..."
cat > ~/.claude/claude-session.sh << 'SESSION_EOF'
#!/bin/bash
# Usage: claude-session "task name"
# Creates/restores tmux session and registers it in VS Code Restore Terminals

SESSION_NAME="$1"
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"

if [ -z "$SESSION_NAME" ]; then
  echo "Usage: claude-session <task-name>"
  echo ""
  echo "Running sessions:"
  tmux list-sessions 2>/dev/null | awk -F: '{print "  " $1}' || echo "  (none)"
  exit 1
fi

echo -ne "\033]0;${SESSION_NAME}\007"

if ! tmux has-session -s "$SESSION_NAME" 2>/dev/null; then
  tmux new-session -d -s "$SESSION_NAME" -c "$HOME/Documents/GitHub"
  tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions" Enter
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
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
PYTHON

tmux attach -t "$SESSION_NAME"
SESSION_EOF
chmod +x ~/.claude/claude-session.sh
ok "claude-session.sh written"

# ── Step 5: Write end-session.sh ─────────────────────────────────────────────
info "Writing ~/.claude/end-session.sh..."
cat > ~/.claude/end-session.sh << 'END_EOF'
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

tmux kill-session -t "$SESSION_NAME" 2>/dev/null && echo "Killed session: $SESSION_NAME"

python3 - "$SESSION_NAME" "$VSCODE_SETTINGS" << 'PYTHON'
import json, sys

session_name = sys.argv[1]
settings_path = sys.argv[2]

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except:
    sys.exit(0)

terminals = settings.get("restoreTerminals.terminals", [])
settings["restoreTerminals.terminals"] = [
    t for t in terminals
    if not any(st.get("name") == session_name for st in t.get("splitTerminals", []))
]

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
PYTHON

echo "Removed from VS Code restore list: $SESSION_NAME"
END_EOF
chmod +x ~/.claude/end-session.sh
ok "end-session.sh written"

# ── Step 6: Add shell aliases ─────────────────────────────────────────────────
info "Adding shell aliases to ~/.zshrc..."
ALIAS_BLOCK='
# Claude Code Workspace aliases
alias claude-session="~/.claude/claude-session.sh"
alias end-session="~/.claude/end-session.sh"
'

if grep -q 'alias claude-session' ~/.zshrc 2>/dev/null; then
  ok "Aliases already present in ~/.zshrc"
else
  echo "$ALIAS_BLOCK" >> ~/.zshrc
  ok "Aliases added to ~/.zshrc"
fi

# ── Step 7: Update ~/.claude/settings.json with Stop Hook ────────────────────
info "Configuring L4 Stop Hook in ~/.claude/settings.json..."
SETTINGS="$HOME/.claude/settings.json"

if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

python3 - "$SETTINGS" << 'PYTHON'
import json, sys

settings_path = sys.argv[1]

with open(settings_path, 'r') as f:
    settings = json.load(f)

hook_entry = {
    "type": "command",
    "command": str(settings_path).replace("settings.json", "hooks/loop.sh"),
    "timeout": 10,
    "statusMessage": "Checking task list..."
}

# Fix the path to be absolute
import os
hook_entry["command"] = os.path.expanduser("~/.claude/hooks/loop.sh")

hooks = settings.setdefault("hooks", {})
stop_hooks = hooks.setdefault("Stop", [])

# Check if already configured
already_configured = any(
    h.get("command") == hook_entry["command"]
    for group in stop_hooks
    for h in group.get("hooks", [])
)

if not already_configured:
    stop_hooks.append({
        "matcher": "",
        "hooks": [hook_entry]
    })
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
    print("Hook added.")
else:
    print("Hook already configured.")
PYTHON
ok "Stop Hook configured"

# ── Step 8: Install VS Code extension ────────────────────────────────────────
info "Installing VS Code 'Restore Terminals' extension..."
if command -v code &>/dev/null; then
  code --install-extension EthanSK.restore-terminals --force
  ok "Extension installed: EthanSK.restore-terminals"
else
  echo ""
  echo "  VS Code CLI ('code') not found in PATH."
  echo "  To install manually:"
  echo "  1. Open VS Code"
  echo "  2. Press Cmd+Shift+X"
  echo "  3. Search: Restore Terminals"
  echo "  4. Install by EthanSK"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "====================================="
ok "Setup complete!"
echo "====================================="
echo ""
echo "Reload your shell:  source ~/.zshrc"
echo ""
echo "Start a session:    claude-session \"My Task\""
echo "End a session:      end-session \"My Task\""
echo ""
echo "VS Code will auto-restore all sessions on restart."
echo ""
