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

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# ── Step 3: Write claude-session.sh ──────────────────────────────────────────
info "Writing ~/.claude/claude-session.sh..."
cp "$REPO_DIR/claude-session.sh" ~/.claude/claude-session.sh
chmod +x ~/.claude/claude-session.sh
ok "claude-session.sh installed"

# ── Step 4: Write loop.sh (L4 Stop Hook) ─────────────────────────────────────
info "Writing ~/.claude/hooks/loop.sh..."
if [ -f ~/.claude/hooks/loop.sh ]; then
  ok "loop.sh already exists, skipping"
else
  cp "$REPO_DIR/loop.sh" ~/.claude/hooks/loop.sh
  chmod +x ~/.claude/hooks/loop.sh
  ok "loop.sh written"
fi

# ── Step 5: Write end-session.sh ─────────────────────────────────────────────
info "Writing ~/.claude/end-session.sh..."
cp "$REPO_DIR/end-session.sh" ~/.claude/end-session.sh
chmod +x ~/.claude/end-session.sh
ok "end-session.sh installed"

# ── Step 6: Configure tmux ───────────────────────────────────────────────────
info "Configuring tmux title forwarding..."
TMUX_CONF="$HOME/.tmux.conf"
if grep -q 'set-titles' "$TMUX_CONF" 2>/dev/null; then
  ok "tmux title config already present"
else
  cat >> "$TMUX_CONF" << 'TMUX_EOF'
# Forward session name as terminal title (for VS Code tab display)
set-option -g set-titles on
set-option -g set-titles-string "#S"
# Start login shell so ~/.zshrc aliases are available in tmux sessions
set-option -g default-command "${SHELL} -l"
# Enable mouse scrolling
set -g mouse on
TMUX_EOF
  ok "tmux title forwarding configured"
fi
if tmux list-sessions &>/dev/null; then
  tmux source "$TMUX_CONF" 2>/dev/null && ok "tmux config reloaded" || true
fi

# ── Step 7: Add shell aliases ────────────────────────────────────────────────
info "Adding shell aliases to ~/.zshrc..."
if grep -q 'alias claude-session\|alias happy-session' ~/.zshrc 2>/dev/null; then
  ok "Aliases already present in ~/.zshrc"
else
  cat >> ~/.zshrc << 'ALIAS_EOF'

# Claude Code Workspace aliases
alias claude-session="~/.claude/claude-session.sh"
alias happy-session="CLAUDE_LAUNCHER=happy ~/.claude/claude-session.sh"
alias end-session="~/.claude/end-session.sh"
ALIAS_EOF
  ok "Aliases added to ~/.zshrc"
fi

# ── Step 8: Configure VS Code ────────────────────────────────────────────────
info "Configuring VS Code settings..."
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"
mkdir -p "$(dirname "$VSCODE_SETTINGS")"

python3 - "$VSCODE_SETTINGS" << 'PYTHON'
import json, sys, os, tempfile

settings_path = sys.argv[1]

try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

changed = False

# Terminal tab title shows sequence (session name set by escape code)
if settings.get("terminal.integrated.tabs.title") != "${sequence}":
    settings["terminal.integrated.tabs.title"] = "${sequence}"
    changed = True

# Happy Session terminal profile for one-click new sessions
profiles = settings.get("terminal.integrated.profiles.osx", {})
if "Happy Session" not in profiles:
    profiles["Happy Session"] = {
        "path": "zsh",
        "args": ["-ic", "printf '\\nSession name: '; read -r name; [[ -z \"$name\" ]] && name=\"session-$(date +%H%M%S)\"; CLAUDE_LAUNCHER=happy ~/.claude/claude-session.sh \"$name\"; exec zsh -i"]
    }
    settings["terminal.integrated.profiles.osx"] = profiles
    changed = True

if changed:
    dir_ = os.path.dirname(settings_path)
    with tempfile.NamedTemporaryFile('w', dir=dir_, delete=False, suffix='.tmp') as tf:
        json.dump(settings, tf, indent=2, ensure_ascii=False)
        tmp_path = tf.name
    os.replace(tmp_path, settings_path)
    print("  VS Code settings updated")
else:
    print("  VS Code settings already configured")
PYTHON
ok "VS Code configured"

# ── Step 9: Install VS Code extensions ───────────────────────────────────────
info "Installing VS Code 'Restore Terminals' extension..."
CODE_BIN=""
if command -v code &>/dev/null; then
  CODE_BIN="code"
elif [ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]; then
  CODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
fi

if [ -n "$CODE_BIN" ]; then
  if "$CODE_BIN" --list-extensions 2>/dev/null | grep -qi 'EthanSK.restore-terminals'; then
    ok "Extension already installed: EthanSK.restore-terminals"
  else
    "$CODE_BIN" --install-extension EthanSK.restore-terminals
    ok "Extension installed: EthanSK.restore-terminals"
  fi
else
  echo "  VS Code CLI not found — install manually:"
  echo "  Cmd+Shift+P → 'Shell Command: Install code in PATH', then rerun this script"
fi

# ── Step 10: Configure L4 Stop Hook ──────────────────────────────────────────
info "Configuring L4 Stop Hook in ~/.claude/settings.json..."
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

python3 - "$CLAUDE_SETTINGS" << 'PYTHON'
import json, sys, os, tempfile

settings_path = sys.argv[1]
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    settings = {}

hook_cmd = os.path.expanduser("~/.claude/hooks/loop.sh")
hooks = settings.setdefault("hooks", {})
stop_hooks = hooks.setdefault("Stop", [])

already = any(
    h.get("command") == hook_cmd
    for group in stop_hooks
    for h in group.get("hooks", [])
)

if not already:
    stop_hooks.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": hook_cmd, "timeout": 10, "statusMessage": "Checking task list..."}]
    })
    dir_ = os.path.dirname(settings_path)
    with tempfile.NamedTemporaryFile('w', dir=dir_, delete=False, suffix='.tmp') as tf:
        json.dump(settings, tf, indent=2, ensure_ascii=False)
        tmp_path = tf.name
    os.replace(tmp_path, settings_path)
    print("  Stop Hook added")
else:
    print("  Stop Hook already configured")
PYTHON
ok "Stop Hook configured"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "====================================="
ok "Setup complete!"
echo "====================================="
echo ""
echo "Reload your shell:    source ~/.zshrc"
echo ""
echo "New happy session:    happy-session 'My Task'"
echo "New claude session:   claude-session 'My Task'"
echo "End a session:        end-session 'My Task'"
echo ""
echo "Or in VS Code: click '+' dropdown → 'Happy Session'"
echo ""
