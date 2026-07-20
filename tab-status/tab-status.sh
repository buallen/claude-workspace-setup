#!/bin/bash
# tab-status.sh — update Claude agent status in multiple places:
#   1. ~/.claude/tab-status file (VSCode extension reads this → status bar)
#   2. tmux window name (visible in tmux tab bar inside VSCode terminal)
#   3. OSC 2 via client_tty (best-effort, works if terminal supports it)
#
# Args: $1 = status keyword (idle | working | waiting | thinking)

set -u

STATUS="${1:-idle}"

# Resolve session display name
NAME=""
if [ -n "${HAPPY_SESSION_NAME:-}" ]; then
    NAME="$HAPPY_SESSION_NAME"
elif [ -n "${TMUX:-}" ]; then
    NAME=$(tmux display-message -p '#S' 2>/dev/null)
fi
if [ -z "${NAME:-}" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    NAME=$(basename "$CLAUDE_PROJECT_DIR")
fi
if [ -z "${NAME:-}" ]; then
    NAME=$(basename "$PWD")
fi

# Treat the session as "working" when a background job/agent/workflow is still
# running for it, even though the main loop has Stopped (idle/waiting). The
# daemon records live background work in ~/.claude/jobs/<id>/state.json with the
# owning cwd; a freshness guard skips crashed "working" jobs that never updated.
session_has_active_bg() {
    python3 - "$HOME/claude-sessions/${1}" <<'PY' 2>/dev/null
import json, os, sys, time, glob
sdir = os.path.realpath(sys.argv[1])
now, FRESH = time.time(), 600  # seconds; a live bg job touches state/jsonl well within this
for base in (os.path.expanduser('~/.claude/jobs'),
             os.path.expanduser('~/.claude-private/jobs')):
    for sf in glob.glob(base + '/*/state.json'):
        try:
            st = json.load(open(sf))
        except Exception:
            continue
        if st.get('state') != 'working':
            continue
        if os.path.realpath(st.get('cwd', '') or '/nope') != sdir:
            continue
        mt = os.path.getmtime(sf)
        jp = st.get('linkScanPath', '')
        if jp and os.path.exists(jp):
            mt = max(mt, os.path.getmtime(jp))
        if now - mt < FRESH:
            sys.exit(0)   # active background work for this session
sys.exit(1)
PY
}

# Status → icon mapping
case "$STATUS" in
    working)  ICON="🔥" ;;
    waiting)  ICON="🫵" ;;
    thinking) ICON="🫵" ;;
    idle|*)   ICON="💤" ;;
esac

# Override: if a background task is still running for this session, keep it
# "working" (🔥) instead of falsely showing idle/waiting.
if [ "$STATUS" != "working" ] && session_has_active_bg "$NAME"; then
    ICON="🔥"
fi

# Backend marker: ✻ = Claude (CC's spark glyph), ⠿ = GPT via claudex (Codex CLI braille dots)
# Poller animates these while the session is working.
PREFIX="✻ "
if [ "$(cat "$HOME/claude-sessions/${NAME}/.backend" 2>/dev/null | tr -d '[:space:]')" = "claudex" ]; then
    PREFIX="⠿ "
fi

TITLE="${PREFIX}${NAME} ${ICON}"

# 1. Write to status file — VSCode extension watches this for status bar update
echo "$STATUS" > "${HOME}/.claude/tab-status" 2>/dev/null || true
# 1b. Per-session status — the poller (tab-status-poller.py) reads this to pick
#     between 🫵 (waiting) and 💤 (idle) when the session isn't actively working.
echo "$STATUS" > "${HOME}/.claude/tab-status-${NAME}" 2>/dev/null || true

# 2. Rename the tmux window — shows up in tmux's own tab bar at bottom of terminal
if [ -n "${TMUX:-}" ]; then
    tmux rename-window "$TITLE" 2>/dev/null || true
fi

# 3. Try OSC 2 via the tmux CLIENT tty (outer terminal = VSCode terminal)
#    Works if VSCode processes OSC from this path; harmless if not.
if [ -n "${TMUX:-}" ]; then
    CLIENT_TTY=$(tmux display-message -p '#{client_tty}' 2>/dev/null)
    if [ -n "$CLIENT_TTY" ] && [ -w "$CLIENT_TTY" ]; then
        printf '\033]2;%s\007' "$TITLE" > "$CLIENT_TTY" 2>/dev/null || true
    fi
fi

exit 0
