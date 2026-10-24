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
warn() { echo -e "${YELLOW}[!!] $1${NC}" >&2; }
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
# session-model 已于 2026-09-14 随本机代理一起退役，清掉旧安装留下的链接
rm -f ~/.local/bin/session-model "$INSTALL_DIR/bin/session-model"
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

if python3 - "$VSCODE_SETTINGS" "$INSTALL_DIR/bin/claude-session" << 'PYTHON'
import json, sys, os, shutil, tempfile

settings_path = sys.argv[1]
claude_session_bin = sys.argv[2]

real_path = os.path.realpath(settings_path)   # a symlinked settings file stays a symlink
try:
    with open(real_path) as f:
        original_text = f.read()
    settings = json.loads(original_text)
except FileNotFoundError:
    original_text, settings = None, {}
except json.JSONDecodeError as exc:
    # JSONC (comments, trailing commas) is common, e.g. VS Code. Never replace a
    # file we could not read with {}: skip this step and say so.
    print(f"  ⚠ {settings_path} is not plain JSON ({exc}); skipped, nothing written", file=sys.stderr)
    sys.exit(3)
if not isinstance(settings, dict):
    print(f"  ⚠ {settings_path} is not a JSON object; skipped, nothing written", file=sys.stderr)
    sys.exit(3)
before = json.loads(original_text) if original_text else {}

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
    if settings != before:
        if original_text is not None:
            old_umask = os.umask(0o077)   # private from the first byte, like the original
            try:
                shutil.copy2(real_path, real_path + ".bak-setup")
            finally:
                os.umask(old_umask)
        with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(real_path), delete=False, suffix=".tmp") as tf:
            json.dump(settings, tf, indent=2, ensure_ascii=False)
        if original_text is not None:
            shutil.copymode(real_path, tf.name)
        os.replace(tf.name, real_path)
    print("  VS Code settings updated")
else:
    print("  VS Code settings already configured")
PYTHON
then
  ok "VS Code configured"
else
  rc=$?
  # 3 = the file is not plain JSON / not an object (left untouched); anything
  # else is a real failure (permissions, disk) and must stop the installer.
  [ "$rc" -eq 3 ] || exit "$rc"
  warn "settings file left unchanged (not plain JSON or not an object): fix it and re-run setup"
fi

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

# ── Step 7: Remove the retired task-loop Stop hook ──────────────────────────
# hooks/loop.sh (block Stop while tasks.md has unchecked items) was taken out of
# service on 2026-10-19; re-running the installer must not bring it back.
info "Removing the retired task-loop Stop hook (if present)..."
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
if python3 - "$CLAUDE_SETTINGS" << 'PYTHON'
import json, sys, os, shutil, tempfile
path = sys.argv[1]
real_path = os.path.realpath(path)   # a symlinked settings file stays a symlink
try:
    with open(real_path) as f:
        original_text = f.read()
    settings = json.loads(original_text)
except FileNotFoundError:
    original_text, settings = None, {}
except json.JSONDecodeError as exc:
    # JSONC (comments, trailing commas) is common, e.g. VS Code. Never replace a
    # file we could not read with {}: skip this step and say so.
    print(f"  ⚠ {path} is not plain JSON ({exc}); skipped, nothing written", file=sys.stderr)
    sys.exit(3)
if not isinstance(settings, dict):
    print(f"  ⚠ {path} is not a JSON object; skipped, nothing written", file=sys.stderr)
    sys.exit(3)
before = json.loads(original_text) if original_text else {}
groups = settings.get("hooks", {}).get("Stop", [])
for group in groups:
    group["hooks"] = [h for h in group.get("hooks", []) if not h.get("command", "").rstrip().endswith("hooks/loop.sh")]
groups[:] = [g for g in groups if g.get("hooks")]
if settings != before:
    if original_text is not None:
        old_umask = os.umask(0o077)   # private from the first byte, like the original
        try:
            shutil.copy2(real_path, real_path + ".bak-setup")
        finally:
            os.umask(old_umask)
    with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(real_path), delete=False, suffix=".tmp") as tf:
        json.dump(settings, tf, indent=2, ensure_ascii=False)
    if original_text is not None:
        shutil.copymode(real_path, tf.name)
    os.replace(tf.name, real_path)
PYTHON
then
  ok "Task-loop Stop hook not installed"
else
  rc=$?
  # 3 = the file is not plain JSON / not an object (left untouched); anything
  # else is a real failure (permissions, disk) and must stop the installer.
  [ "$rc" -eq 3 ] || exit "$rc"
  warn "settings file left unchanged (not plain JSON or not an object): fix it and re-run setup"
fi

# ── Step 8: Install tab-status emoji/backend marker poller ──────────────────
info "Installing tab-status poller..."
mkdir -p ~/.claude/hooks
cp "$REPO_DIR/tab-status/tab-status-poller.py" "$REPO_DIR/tab-status/tab-status.sh" ~/.claude/hooks/
chmod +x ~/.claude/hooks/tab-status-poller.py ~/.claude/hooks/tab-status.sh

if python3 - "$CLAUDE_SETTINGS" << 'PYTHON'
import json, sys, os, shutil, tempfile

settings_path = sys.argv[1]
hook_sh = os.path.expanduser("~/.claude/hooks/tab-status.sh")

real_path = os.path.realpath(settings_path)   # a symlinked settings file stays a symlink
try:
    with open(real_path) as f:
        original_text = f.read()
    settings = json.loads(original_text)
except FileNotFoundError:
    original_text, settings = None, {}
except json.JSONDecodeError as exc:
    # JSONC (comments, trailing commas) is common, e.g. VS Code. Never replace a
    # file we could not read with {}: skip this step and say so.
    print(f"  ⚠ {settings_path} is not plain JSON ({exc}); skipped, nothing written", file=sys.stderr)
    sys.exit(3)
if not isinstance(settings, dict):
    print(f"  ⚠ {settings_path} is not a JSON object; skipped, nothing written", file=sys.stderr)
    sys.exit(3)
before = json.loads(original_text) if original_text else {}

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
    entry = {"type": "command", "command": cmd, "timeout": 2}
    if event == "SessionStart":
        entry["async"] = True   # never delay session start for an emoji
    groups = hooks.setdefault(event, [])
    existing = [h for g in groups for h in g.get("hooks", []) if "tab-status.sh" in h.get("command", "")]
    if existing == [entry]:
        continue   # already exactly right: leave the layout alone
    # otherwise drop every tab-status.sh registration (any arg / path) and add one
    for group in groups:
        group["hooks"] = [h for h in group.get("hooks", []) if "tab-status.sh" not in h.get("command", "")]
    groups[:] = [g for g in groups if g.get("hooks")]
    groups.append({"matcher": "", "hooks": [entry]})

if settings != before:
    if original_text is not None:
        old_umask = os.umask(0o077)   # private from the first byte, like the original
        try:
            shutil.copy2(real_path, real_path + ".bak-setup")
        finally:
            os.umask(old_umask)
    with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(real_path), delete=False, suffix=".tmp") as tf:
        json.dump(settings, tf, indent=2, ensure_ascii=False)
    if original_text is not None:
        shutil.copymode(real_path, tf.name)
    os.replace(tf.name, real_path)
print("  tab-status hooks wired (UserPromptSubmit/Stop/Notification/SessionStart)")
PYTHON
then
  :
else
  rc=$?
  # 3 = the file is not plain JSON / not an object (left untouched); anything
  # else is a real failure (permissions, disk) and must stop the installer.
  [ "$rc" -eq 3 ] || exit "$rc"
  warn "settings file left unchanged (not plain JSON or not an object): fix it and re-run setup"
fi

PLIST="$HOME/Library/LaunchAgents/com.kanlu.tabstatus-poller.plist"
cp "$REPO_DIR/tab-status/com.kanlu.tabstatus-poller.plist" "$PLIST"
launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
ok "tab-status poller installed and (re)started"
echo "  依赖 tmux \`set-titles\` 转发（Step 3 已配置）；标签图标需要终端把 tmux 窗口名当标题显示"
echo "  （Otty: privilege-title-shell=true 默认开；VS Code: Step 5 已设 terminal.integrated.tabs.title）"

# ── Step 9: sessionctl, conversation-marker hook, pkill guard ───────────────
info "Installing sessionctl and session hooks..."
mkdir -p ~/.local/bin
ln -sf "$INSTALL_DIR/bin/sessionctl" ~/.local/bin/sessionctl
if python3 - "$CLAUDE_SETTINGS" "$INSTALL_DIR/hooks" << 'PYTHON'
import json, sys, os, shutil, tempfile
path, hook_dir = sys.argv[1], sys.argv[2]
real_path = os.path.realpath(path)   # a symlinked settings file stays a symlink
try:
    with open(real_path) as f:
        original_text = f.read()
    settings = json.loads(original_text)
except FileNotFoundError:
    original_text, settings = None, {}
except json.JSONDecodeError as exc:
    # JSONC (comments, trailing commas) is common, e.g. VS Code. Never replace a
    # file we could not read with {}: skip this step and say so.
    print(f"  ⚠ {path} is not plain JSON ({exc}); skipped, nothing written", file=sys.stderr)
    sys.exit(3)
if not isinstance(settings, dict):
    print(f"  ⚠ {path} is not a JSON object; skipped, nothing written", file=sys.stderr)
    sys.exit(3)
before = json.loads(original_text) if original_text else {}
hooks = settings.setdefault("hooks", {})

def ensure(event, matcher, script, timeout):
    """Add python3 <script> once; any existing registration of that script counts."""
    groups = hooks.setdefault(event, [])
    name = os.path.basename(script)
    if any(name in h.get("command", "") for g in groups for h in g.get("hooks", [])):
        return f"  {event}: {name} already registered"
    entry = {"type": "command", "command": f"python3 {script}", "timeout": timeout}
    for g in groups:
        if g.get("matcher", "") == matcher:
            g.setdefault("hooks", []).append(entry)
            break
    else:
        groups.append({"matcher": matcher, "hooks": [entry]})
    return f"  {event}: {name} registered"

# SessionStart is the only event that sees /clear and /compact change the
# conversation id; synchronous so the marker is right before the first prompt.
print(ensure("SessionStart", "", f"{hook_dir}/session-marker.py", 5))
# GNU-style pkill on macOS turned extra arguments into match patterns and
# killed 186 processes on 2026-10-15.
print(ensure("PreToolUse", "Bash", f"{hook_dir}/guard-pkill.py", 5))
if settings != before:
    if original_text is not None:
        old_umask = os.umask(0o077)   # private from the first byte, like the original
        try:
            shutil.copy2(real_path, real_path + ".bak-setup")
        finally:
            os.umask(old_umask)
    with tempfile.NamedTemporaryFile("w", dir=os.path.dirname(real_path), delete=False, suffix=".tmp") as tf:
        json.dump(settings, tf, indent=2, ensure_ascii=False)
    if original_text is not None:
        shutil.copymode(real_path, tf.name)
    os.replace(tf.name, real_path)

PYTHON
then
  ok "sessionctl linked into ~/.local/bin; session hooks wired"
else
  rc=$?
  # 3 = the file is not plain JSON / not an object (left untouched); anything
  # else is a real failure (permissions, disk) and must stop the installer.
  [ "$rc" -eq 3 ] || exit "$rc"
  warn "settings file left unchanged (not plain JSON or not an object): fix it and re-run setup"
fi

# ── Step 11: Install nightly distiller ───────────────────────────────────────
info "Installing nightly distiller..."
cp "$REPO_DIR/nightly-distill.sh" ~/.claude/nightly-distill.sh
cp "$REPO_DIR/distill-read.py" ~/.claude/distill-read.py
cp "$REPO_DIR/distill-prompt.md" ~/.claude/distill-prompt.md
cp "$REPO_DIR/registry-init.py" ~/.claude/registry-init.py
cp "$REPO_DIR/registry-query.py" ~/.claude/registry-query.py
chmod +x ~/.claude/nightly-distill.sh

# 初始化 registry
python3 ~/.claude/registry-init.py
ok "Nightly distiller installed"

# 设置 launchd 每晚 00:25 自动运行
PLIST="$HOME/Library/LaunchAgents/com.kanlu.distiller.plist"
if [ ! -f "$PLIST" ]; then
  NODE_BIN=$(dirname $(which node 2>/dev/null || echo /usr/local/bin/node))
  cat > "$PLIST" << PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.kanlu.distiller</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>bash $HOME/.claude/nightly-distill.sh &gt;&gt; $HOME/claude-sessions/distiller.log 2&gt;&amp;1</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>0</integer><key>Minute</key><integer>25</integer></dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>$NODE_BIN:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key><string>$HOME</string>
    </dict>
    <key>StandardOutPath</key><string>$HOME/claude-sessions/distiller.log</string>
    <key>StandardErrorPath</key><string>$HOME/claude-sessions/distiller.log</string>
</dict>
</plist>
PLIST_EOF
  launchctl load "$PLIST" 2>/dev/null && ok "Distiller launchd agent loaded (runs nightly at 00:25)"
else
  ok "Distiller launchd agent already configured"
fi

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
echo "Session control:      sessionctl status | restart 'My Task' | idle"
echo ""
echo ""
echo "Nightly distiller:    runs automatically at 00:25"
echo "Manual run:           bash ~/.claude/nightly-distill.sh"
echo "Route a task:         /dispatch 'what you want to do'"
echo ""
