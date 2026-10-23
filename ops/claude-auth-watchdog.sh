#!/bin/bash
# claude-auth-watchdog.sh — v2 (in-session OAuth)
#
# Scans tmux sessions every tick for Claude Code 401 / OAuth-waiting state
# and drives a full in-session OAuth refresh using happy's own /login flow.
# This is much more robust than the v1 "throwaway tmux + claude auth login"
# approach because:
#   1. happy SDK hot-reloads the new token immediately after the in-session
#      OAuth completes (no need to restart the happy process)
#   2. happy's /login UI gracefully falls back to "Browser didn't open?" and
#      prints the OAuth URL inline — no sandbox-exec needed, no browser pop
#   3. claude auth status is unreliable as a guard (it reflects the keychain,
#      not what each happy session has cached) — viewport state is ground truth
#
# Two stuck-session shapes are detected:
#   LIVE 401  — happy client alive, prompt visible (❯) → run in-session flow
#   DEAD      — happy SDK exited, "Press space to switch to local mode" screen
#               → not auto-fixable from outside, Lark-notify user to restart

LOG_FILE="$HOME/Library/Logs/claude-auth-watchdog.log"
LOCK_DIR="/tmp/claude-auth-watchdog.lock.d"
STATE_DIR="/tmp/claude-auth-watchdog-state"
MAX_LOG_SIZE=1048576  # 1MB
COOLDOWN_SECONDS=600  # 10 min between attempts per session
MAX_FAILURES=2

mkdir -p "$STATE_DIR"

# Single-instance lock
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -f "$LOCK_DIR/age" ]; then
        age=$(( $(date +%s) - $(stat -f%m "$LOCK_DIR/age" 2>/dev/null || echo 0) ))
        if [ "$age" -gt 900 ]; then
            rm -rf "$LOCK_DIR" && mkdir "$LOCK_DIR" || exit 0
        else
            exit 0
        fi
    else
        exit 0
    fi
fi
touch "$LOCK_DIR/age"
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE")" -gt "$MAX_LOG_SIZE" ]; then
    mv "$LOG_FILE" "$LOG_FILE.old"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

notify_lark() {
    /opt/homebrew/bin/lark-cli im +send --to me --text "$1" >/dev/null 2>&1 || true
}

# Patterns indicating Claude Code thinks the user needs to log in.
LIVE_NEEDLES=(
    "Please run /login"
    "Please run \`/login\`"
    "Run \`/login\` to authenticate"
    "API Error: 401"
    "Invalid authentication credentials"
)

# DEAD = happy process actually gone from the tmux pane's process tree.
# (The viewport "Press space to switch to local mode" text alone isn't
# reliable — it may be a leftover frame from a previous happy exit while
# the pane already has a fresh happy process running.)
is_happy_alive() {
    local sess="$1"
    local pane_pid=$(tmux list-panes -t "$sess:0" -F '#{pane_pid}' 2>/dev/null | head -1)
    [ -z "$pane_pid" ] && return 1
    # Look for happy node process anywhere under the pane shell
    pgrep -P "$pane_pid" 2>/dev/null | while read p; do
        ps -p "$p" -o command 2>/dev/null | grep -q "bin/happy" && return 0
        # Look one more level down
        pgrep -P "$p" 2>/dev/null | while read q; do
            ps -p "$q" -o command 2>/dev/null | grep -q "bin/happy" && return 0
        done
    done
    pgrep -af "happy.*--resume" 2>/dev/null | grep -q "$sess\|/$sess/\|claude-sessions/$sess" && return 0
    return 1
}

# Sync Chrome cookies to the path claude-reauth.py expects.
sync_cookies() {
    python3 /Users/kan.lu/bin/export-chrome-cookies.py >/dev/null 2>&1
    if [ -f /tmp/playwright-cookies.json ]; then
        cp /tmp/playwright-cookies.json /tmp/claude-cookies.json
        return 0
    fi
    return 1
}

# Drive the in-session /login flow for a LIVE 401 session. Returns 0 on success.
run_in_session_oauth() {
    local session="$1"
    local target="$session:0"

    # happy may be in some intermediate modal state (e.g. "Press space again"
    # after a stray space keystroke). Send Esc twice to dismiss any open menu
    # / mode-switch confirmation and bring focus back to the prompt before
    # we try /login.
    log "  → $session: dismiss any modal state (Esc x2)"
    tmux send-keys -t "$target" Escape
    sleep 0.5
    tmux send-keys -t "$target" Escape
    sleep 1

    log "  → $session: send '/login' to happy"
    tmux send-keys -t "$target" "/login" Enter
    sleep 4

    if ! tmux capture-pane -pt "$target" -S 0 -E - 2>/dev/null | grep -q "Select login method"; then
        log "  → $session: login menu didn't appear after /login (happy may be in a non-input state)"
        return 1
    fi

    log "  → $session: send '1' to select subscription"
    tmux send-keys -t "$target" "1" Enter
    sleep 5

    if ! tmux capture-pane -pt "$target" -S 0 -E - 2>/dev/null | grep -q "Paste code here if prompted"; then
        log "  → $session: OAuth URL prompt didn't appear"
        # Best-effort cleanup: dismiss whatever dialog is open
        tmux send-keys -t "$target" Escape
        return 1
    fi

    log "  → $session: handing off to reauth.py -t $target"
    if ! timeout 45 python3 /Users/kan.lu/bin/claude-reauth.py -t "$target" >> "$LOG_FILE" 2>&1; then
        log "  → $session: reauth.py failed"
        tmux send-keys -t "$target" Escape
        return 1
    fi

    # happy needs a few seconds to validate the code with platform.claude.com
    sleep 8

    if ! tmux capture-pane -pt "$target" -S 0 -E - 2>/dev/null | grep -q "Login successful"; then
        log "  → $session: code pasted but 'Login successful' not seen"
        tmux send-keys -t "$target" Escape
        return 1
    fi

    log "  → $session: 'Login successful' confirmed, dismissing dialog"
    tmux send-keys -t "$target" "" Enter
    sleep 2
    return 0
}

SESSIONS=$(tmux ls -F '#{session_name}' 2>/dev/null)
[ -z "$SESSIONS" ] && exit 0

for session in $SESSIONS; do
    pane_content=$(tmux capture-pane -pt "$session:0" -S 0 -E - 2>/dev/null)
    [ -z "$pane_content" ] && continue

    matched_pattern=""
    for needle in "${LIVE_NEEDLES[@]}"; do
        if echo "$pane_content" | grep -qF "$needle"; then
            matched_pattern="$needle"
            break
        fi
    done
    [ -z "$matched_pattern" ] && continue

    state_file="$STATE_DIR/$session"
    fail_file="$STATE_DIR/$session.fail"

    # Cooldown check
    last_attempt=""
    age=99999
    if [ -f "$state_file" ]; then
        last_attempt=$(cat "$state_file" 2>/dev/null)
        if [ -n "$last_attempt" ]; then
            age=$(( $(date +%s) - last_attempt ))
            if [ "$age" -lt "$COOLDOWN_SECONDS" ]; then
                log "$session: '$matched_pattern' but reauth attempted ${age}s ago, cooldown ${COOLDOWN_SECONDS}s — skip"
                continue
            fi
        fi
    fi

    # Failure circuit-breaker
    if [ -f "$fail_file" ]; then
        fail_count=$(cat "$fail_file" 2>/dev/null || echo 0)
        if [ "$fail_count" -ge "$MAX_FAILURES" ]; then
            log "$session: circuit open after $fail_count failures — won't retry. Clear $fail_file to re-enable."
            if [ "$age" -gt "$COOLDOWN_SECONDS" ]; then
                notify_lark "🚨 $session reauth 已连续失败 $fail_count 次，已停止自动重试。清 $fail_file 重启自动流程。"
                date +%s > "$state_file"
            fi
            continue
        fi
    fi

    # Classify: LIVE (happy process alive) vs DEAD (process gone, only screen leftover)
    if ! is_happy_alive "$session"; then
        log "$session: happy process gone — attempting auto-restart"
        uuid_file="$HOME/claude-sessions/$session/.current-session"
        if [ "$session" != "Personal" ] && [ ! -f "$uuid_file" ]; then
            log "  $session: no .current-session file, can't restart"
            if [ "$age" -gt "$COOLDOWN_SECONDS" ]; then
                notify_lark "💀 $session 已退出 happy 进程且找不到 uuid。需手动 attach + restart。"
                date +%s > "$state_file"
            fi
            continue
        fi
        uuid=""
        if [ "$session" != "Personal" ]; then
            uuid=$(cat "$uuid_file")
        fi
        # Send Enter to flush any leftover modal state from old happy frame
        tmux send-keys -t "$session:0" Enter
        sleep 1
        # Personal session needs CLAUDE_CONFIG_DIR=~/.claude-private
        if [ "$session" = "Personal" ]; then
            private_command=$(printf '%q ' env "CLAUDE_CONFIG_DIR=$HOME/.claude-private" python3 "$HOME/.claude/claude-workspace/lib/personal_history.py" --launch happy)
            tmux send-keys -t "$session:0" "$private_command" Enter
        else
            tmux send-keys -t "$session:0" "happy --yolo --resume $uuid" Enter
        fi
        sleep 20
        if is_happy_alive "$session"; then
            log "  $session: happy process up after restart"
            notify_lark "🔄 $session happy 已自动 restart（uuid: ${uuid:0:8}...）。下次该 session 触发 API 调用即可恢复。"
            date +%s > "$state_file"
            rm -f "$fail_file"
        else
            log "  $session: restart FAILED — happy process didn't come up"
            if [ -f "$fail_file" ]; then
                current=$(cat "$fail_file" 2>/dev/null || echo 0)
                echo $((current + 1)) > "$fail_file"
            else
                echo 1 > "$fail_file"
            fi
            notify_lark "❌ $session happy restart 失败。需手动检查。"
            date +%s > "$state_file"
        fi
        continue
    fi

    log "$session: LIVE 401 ('$matched_pattern') — initiating in-session /login flow"
    notify_lark "🔐 $session session 401，自动 in-session reauth 进行中..."
    date +%s > "$state_file"

    if ! sync_cookies; then
        log "  $session: sync_cookies failed — Chrome may not be signed in to claude.ai"
        notify_lark "⚠️ $session reauth 失败：无法从 Chrome 取 claude.ai cookies。请确认 Chrome 已登录 claude.ai。"
        continue
    fi

    if run_in_session_oauth "$session"; then
        log "$session: in-session reauth SUCCESS"
        notify_lark "✅ $session session 已自动 reauth 完成。可以继续用了。"
        rm -f "$fail_file"
    else
        log "$session: in-session reauth FAILED"
        if [ -f "$fail_file" ]; then
            current=$(cat "$fail_file" 2>/dev/null || echo 0)
            echo $((current + 1)) > "$fail_file"
        else
            echo 1 > "$fail_file"
        fi
        new_fail=$(cat "$fail_file")
        notify_lark "❌ $session in-session reauth 失败（累计 ${new_fail}/${MAX_FAILURES} 次）。日志: $LOG_FILE"
    fi
done
