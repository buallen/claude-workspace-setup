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

# Single-instance lock (not in --reauth mode: that is our own child, run
# under the session's sessionctl lock while the parent holds this one).
if [ "${1:-}" != "--reauth" ]; then
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
fi

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

SESSIONCTL="$HOME/.claude/claude-workspace/bin/sessionctl"

# State from sessionctl (one implementation of "alive / busy"): stopped,
# busy, background, waiting, idle or missing. The old is_happy_alive returned
# from inside a pipeline subshell, so it answered "dead" for live sessions and
# the DEAD branch typed `happy --yolo --resume` into running conversations.
session_state() {
    "$SESSIONCTL" status "$1" --json 2>/dev/null \
        | python3 -c 'import json, sys; print(json.load(sys.stdin)[0]["state"])' 2>/dev/null
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
    local target="=$session:"   # "=" = exact match; names can be prefixes of others

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

# --reauth NAME: run by `sessionctl lock NAME -- $0 --reauth NAME`, i.e. while
# holding the session's lock, so a nightly restart cannot interleave with the
# keys typed below. Re-check right before typing: the snapshot may be stale.
if [ "${1:-}" = "--reauth" ]; then
    session="$2"
    state=$(session_state "$session")
    case "$state" in idle|waiting) ;; *) log "$session: now $state, not typing /login"; exit 3 ;; esac
    python3 "$HOME/.claude/claude-workspace/lib/sessionlib.py" auth-error "$session" || { log "$session: auth error gone, not typing /login"; exit 3; }
    run_in_session_oauth "$session"
    exit $?
fi

# One name per line: names contain spaces ("Product priorities"), and the old
# `for session in $SESSIONS` split them into words.
while IFS= read -r session; do
    [ -z "$session" ] && continue
    # Claude prints an auth error just above its prompt; only the last lines
    # count, so a conversation that merely talks about "401" is not a trigger.
    pane_content=$(tmux capture-pane -p -t "=$session:" -S -15 2>/dev/null)
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

    state=$(session_state "$session")
    case "$state" in
        stopped)
            # Only an auth failure is this watchdog's business; a session that
            # was stopped on purpose (sessionctl stop) stays stopped.
            if ! python3 "$HOME/.claude/claude-workspace/lib/sessionlib.py" auth-error "$session"; then
                log "$session: stopped, no auth error in its transcript — leaving it stopped"
                continue
            fi
            log "$session: happy/claude gone after an auth error — restarting via sessionctl"
            "$SESSIONCTL" start "$session" >> "$LOG_FILE" 2>&1
            rc=$?
            if [ $rc -eq 75 ]; then
                log "  $session: another sessionctl holds the lock — skip, not a failure"
                continue
            fi
            if [ $rc -eq 0 ]; then
                notify_lark "🔄 $session 的 happy 已自动重新拉起（续接原对话）。"
                date +%s > "$state_file"
                rm -f "$fail_file"
            else
                log "  $session: restart FAILED"
                current=$(cat "$fail_file" 2>/dev/null || echo 0)
                echo $((current + 1)) > "$fail_file"
                notify_lark "❌ $session happy 自动拉起失败，需手动检查（sessionctl status \"$session\"）。"
                date +%s > "$state_file"
            fi
            continue
            ;;
        idle|waiting)
            ;;  # a session stuck on an auth error sits at its prompt
        *)
            log "$session: '$matched_pattern' on screen but session is ${state:-unknown} — not touching it"
            continue
            ;;
    esac

    # The screen is only a pre-filter: a conversation that discusses 401s (or
    # shows this script) matches it too. Act only if Claude Code itself recorded
    # an unanswered authentication_failed error as the conversation's last turn.
    if ! python3 "$HOME/.claude/claude-workspace/lib/sessionlib.py" auth-error "$session"; then
        log "$session: '$matched_pattern' on screen but no pending auth error in its transcript — not touching it"
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

    "$SESSIONCTL" lock "$session" -- /bin/bash "$0" --reauth "$session"
    rc=$?
    if [ $rc -eq 75 ] || [ $rc -eq 3 ]; then
        log "$session: reauth skipped (rc=$rc: locked or no longer idle with an auth error)"
        continue
    fi
    if [ $rc -eq 0 ]; then
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
done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)
