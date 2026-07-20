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
INSTALL_DIR="$HOME/.claude/claude-workspace"

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

# ── Step 2: Install workspace scripts ────────────────────────────────────────
info "Installing workspace scripts..."
mkdir -p "$INSTALL_DIR" ~/.claude/hooks ~/.local/bin
rm -rf "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/hooks" "$INSTALL_DIR/config"
cp -R "$REPO_DIR/bin" "$REPO_DIR/lib" "$REPO_DIR/hooks" "$REPO_DIR/config" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/"* "$INSTALL_DIR/hooks/"* "$INSTALL_DIR/lib/vscode_restore.py"
rm -f "$INSTALL_DIR/bin/happy-vibe-session"
rm -f ~/.claude/claude-session.sh ~/.claude/happy-vibe-session.sh ~/.local/bin/happy-vibe-session ~/.local/bin/session-restore-mode ~/.claude/end-session.sh ~/.claude/hooks/loop.sh ~/.claude/hooks/sync-session-id.sh
ln -sf "$INSTALL_DIR/bin/session-model" ~/.local/bin/session-model
ln -sf "$INSTALL_DIR/bin/codex-session" ~/.local/bin/codex-session
ok "Workspace scripts installed"

# ── Step 3: Configure tmux ───────────────────────────────────────────────────
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

# ── Step 4: Add shell aliases ────────────────────────────────────────────────
info "Adding shell aliases to ~/.zshrc..."
python3 - "$HOME/.zshrc" << 'PYTHON'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1]).expanduser()
text = path.read_text() if path.exists() else ""

managed = """# Claude Code Workspace aliases
alias claude-session="~/.claude/claude-workspace/bin/claude-session"
alias happy-session="CLAUDE_LAUNCHER=happy ~/.claude/claude-workspace/bin/claude-session"
alias happy-session-private='CLAUDE_LAUNCHER=happy CLAUDE_CONFIG_DIR=~/.claude-private ~/.claude/claude-workspace/bin/claude-session'
alias codex-session="~/.claude/claude-workspace/bin/codex-session"
alias session-model="~/.claude/claude-workspace/bin/session-model"
alias end-session="~/.claude/claude-workspace/bin/end-session"
"""

patterns = [
    r"\n?# Claude Code Workspace aliases\n(?:alias (?:claude-session|happy-session|happy-session-private|happy-vibe-session|codex-session|session-restore-mode|session-model|end-session)=.*\n)+",
    r"\n?# Claude private mode[^\n]*\n(?:alias claude-private=.*\n)+",
    r"\n?# Happy session private mode[^\n]*\n(?:alias happy-session-private=.*\n)+",
    r"\n?# Claude Code via VibeProxy[\s\S]*?alias claude-codex=.*\n",
]

for pattern in patterns:
    text = re.sub(pattern, "\n", text)

text = text.rstrip() + "\n\n" + managed
path.write_text(text)
print("  Claude workspace aliases updated")
PYTHON
ok "Aliases updated in ~/.zshrc"

# ── Step 5: Configure VS Code ────────────────────────────────────────────────
info "Configuring VS Code settings..."
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"
mkdir -p "$(dirname "$VSCODE_SETTINGS")"

python3 - "$VSCODE_SETTINGS" "$INSTALL_DIR/bin/claude-session" << 'PYTHON'
import json, sys, os, tempfile

settings_path = sys.argv[1]
claude_session_bin = sys.argv[2]

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

# Let Restore Terminals run the configured launch commands on window restore.
# VS Code's own terminal persistence otherwise revives old `tmux attach`
# processes and skips the happy-session launch commands.
desired_terminal_settings = {
    "terminal.integrated.enablePersistentSessions": False,
    "terminal.integrated.persistentSessionReviveProcess": "never",
}
for key, value in desired_terminal_settings.items():
    if settings.get(key) != value:
        settings[key] = value
        changed = True

# Happy Session terminal profile for one-click new sessions
profiles = settings.get("terminal.integrated.profiles.osx", {})
happy_profile = {
    "path": "zsh",
    "args": ["-ic", f"printf '\\nSession name: '; read -r name; [[ -z \"$name\" ]] && name=\"session-$(date +%H%M%S)\"; CLAUDE_LAUNCHER=happy {claude_session_bin!r} \"$name\"; exec zsh -i"]
}
if profiles.get("Happy Session") != happy_profile:
    profiles["Happy Session"] = happy_profile
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

# ── Step 6: Install VS Code extensions ───────────────────────────────────────
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

# ── Step 7: Configure L4 Stop Hook ──────────────────────────────────────────
info "Configuring L4 Stop Hook in ~/.claude/settings.json..."
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"

python3 - "$CLAUDE_SETTINGS" "$INSTALL_DIR/hooks/loop.sh" << 'PYTHON'
import json, sys, os, tempfile

settings_path = sys.argv[1]
hook_cmd = sys.argv[2]
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    settings = {}

hooks = settings.setdefault("hooks", {})
stop_hooks = hooks.setdefault("Stop", [])

for group in stop_hooks:
    group["hooks"] = [
        h for h in group.get("hooks", [])
        if h.get("command") not in {
            os.path.expanduser("~/.claude/hooks/loop.sh"),
            hook_cmd,
        }
    ]

stop_hooks[:] = [group for group in stop_hooks if group.get("hooks")]
stop_hooks.append({
    "matcher": "",
    "hooks": [{"type": "command", "command": hook_cmd, "timeout": 10, "statusMessage": "Checking task list..."}]
})

dir_ = os.path.dirname(settings_path)
with tempfile.NamedTemporaryFile('w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(settings, tf, indent=2, ensure_ascii=False)
    tmp_path = tf.name
os.replace(tmp_path, settings_path)
print("  Stop Hook configured")
PYTHON
ok "Stop Hook configured"

# ── Step 8: Install tab-status emoji/backend marker poller ──────────────────
info "Installing tab-status poller..."
mkdir -p ~/.claude/hooks
cp "$REPO_DIR/tab-status/tab-status-poller.py" "$REPO_DIR/tab-status/tab-status.sh" ~/.claude/hooks/
chmod +x ~/.claude/hooks/tab-status-poller.py ~/.claude/hooks/tab-status.sh

python3 - "$CLAUDE_SETTINGS" << 'PYTHON'
import json, sys, os, tempfile

settings_path = sys.argv[1]
hook_sh = os.path.expanduser("~/.claude/hooks/tab-status.sh")

try:
    with open(settings_path) as f:
        settings = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    settings = {}

hooks = settings.setdefault("hooks", {})
# event -> arg passed to tab-status.sh (see tab-status.sh for the states it sets)
wanted = {
    "UserPromptSubmit": "working",
    "Stop": "idle",
    "Notification": "waiting",
    "SessionStart": "idle",
}

for event, arg in wanted.items():
    cmd = f"{hook_sh} {arg}"
    groups = hooks.setdefault(event, [])
    # drop any pre-existing tab-status.sh registration for this event (any arg),
    # so re-running the installer after an arg/path change doesn't leave stale dupes
    for group in groups:
        group["hooks"] = [h for h in group.get("hooks", []) if "tab-status.sh" not in h.get("command", "")]
    groups[:] = [g for g in groups if g.get("hooks")]
    groups.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})

dir_ = os.path.dirname(settings_path)
with tempfile.NamedTemporaryFile('w', dir=dir_, delete=False, suffix='.tmp') as tf:
    json.dump(settings, tf, indent=2, ensure_ascii=False)
    tmp_path = tf.name
os.replace(tmp_path, settings_path)
print("  tab-status hooks wired (UserPromptSubmit/Stop/Notification/SessionStart)")
PYTHON

PLIST="$HOME/Library/LaunchAgents/com.kanlu.tabstatus-poller.plist"
cp "$REPO_DIR/tab-status/com.kanlu.tabstatus-poller.plist" "$PLIST"
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
ok "tab-status poller installed and (re)started"
echo "  依赖 tmux \`set-titles\` 转发（Step 3 已配置）；标签图标需要终端把 tmux 窗口名当标题显示"
echo "  （Otty: privilege-title-shell=true 默认开；VS Code: Step 5 已设 terminal.integrated.tabs.title）"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "====================================="
ok "Setup complete!"
echo "====================================="
echo ""
echo "Reload your shell:    source ~/.zshrc"
echo ""
echo "New happy session:    happy-session 'My Task'"
echo "New Codex session:   codex-session 'My Task'"
echo "New claude session:   claude-session 'My Task'"
echo "End a session:        end-session 'My Task'"
echo ""
echo "Or in VS Code: click '+' dropdown → 'Happy Session'"
echo ""
