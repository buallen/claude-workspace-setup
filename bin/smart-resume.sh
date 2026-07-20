#!/bin/bash
# smart-resume.sh <SESSION_NAME>
# Auto-recovers from bg-agent lock before starting happy locally.
# Fixes two symptoms of the same root cause (phone→Mac mode switch):
#   - Scenario A: bg-agent killed mid-task → lock residue → fork to clean UUID
#   - Scenario B: happy exits to session picker → same lock → fork + resume
#
# Backend switching (session-model):
#   Every session ALWAYS routes through CLIProxyAPI (127.0.0.1:8317) when it's
#   reachable — real Claude models forward straight through to Anthropic using
#   a real Anthropic OAuth credential (~/.cli-proxy-api/claude-*.json), GPT
#   models forward to the codex provider. This is what makes gpt-5.6-sol show
#   up directly in the in-app /model picker (as a "Custom Haiku model") on
#   EVERY session, selectable without needing to switch backend first
#   (2026-07-20; previously the proxy was opt-in per session via .backend).
#   If the proxy is down, LAUNCH_ENV is left empty and happy falls straight
#   through to Anthropic directly — a dead local proxy degrades gracefully,
#   it doesn't take every session down with it.
#
#   ~/claude-sessions/<name>/.backend == "claudex" additionally makes
#   gpt-5.6-sol the PREFERRED default (launch --model + subagent model) for
#   this session, on top of the always-on proxy routing above. Absent file =
#   Anthropic's own default model set (Fable/Opus/Sonnet) is preferred, but
#   gpt-5.6-sol is still there in /model if you want to pick it manually. The
#   file is re-read every loop iteration, so exiting Claude once inside the
#   session is enough to relaunch the SAME conversation with the new default.

SESSION_NAME="$1"
SESSION_DIR="$HOME/claude-sessions/$SESSION_NAME"
CLAUDEX_CONF="/opt/homebrew/etc/cliproxyapi.conf"
CLAUDEX_URL="http://127.0.0.1:8317"
CLAUDEX_MODEL="gpt-5.6-sol"

get_uuid() {
  cat "$SESSION_DIR/.current-session" 2>/dev/null
}

# The proxy key lives only in cliproxyapi.conf (single source of truth).
claudex_key() {
  sed -n '/^api-keys:/,/^[a-z]/p' "$CLAUDEX_CONF" 2>/dev/null \
    | grep -m1 '^[[:space:]]*-' | sed -E 's/.*"([^"]+)".*/\1/'
}

# A real bg-agent lock = THIS session has a background job that is ACTIVELY
# running right now. Three guards, each fixing a former false-positive that made
# every session fork on every startup:
#   1. session-specific — the job's cwd must be THIS session (not any session)
#   2. state == 'working' only — 'done'/'blocked'/'cancelled'/… are not locks
#   3. freshness — a live job touches its state.json / output jsonl within 5min;
#      weeks-old zombie 'working' jobs that never reached a terminal state don't.
has_active_bg_lock() {
  python3 - "$SESSION_DIR" <<'PY' 2>/dev/null
import json, os, sys, time, glob
sdir = os.path.realpath(sys.argv[1])
now = time.time()
for sf in glob.glob(os.path.expanduser('~/.claude/jobs/*/state.json')):
    try:
        d = json.load(open(sf))
    except Exception:
        continue
    if d.get('template') != 'bg' or d.get('state') != 'working':
        continue
    if os.path.realpath(d.get('cwd', '') or '/nope') != sdir:
        continue
    mt = os.path.getmtime(sf)
    jp = d.get('linkScanPath', '')
    if jp and os.path.exists(jp):
        try:
            mt = max(mt, os.path.getmtime(jp))
        except OSError:
            pass
    if now - mt < 300:
        sys.exit(0)   # a fresh, working bg job for this session → real lock
sys.exit(1)
PY
}

fork_and_update() {
  local uuid="$1"
  local proj_dir

  # Build projects dir path. Claude Code encodes spaces in the cwd as dashes
  # (e.g. "Beep delivery" -> "Beep-delivery"), so convert them or the newest-
  # JSONL lookup below silently misses the fork for spaced session names.
  proj_dir="$HOME/.claude/projects/-Users-kan-lu-claude-sessions-${SESSION_NAME// /-}"

  echo "[smart-resume] bg-agent lock on $uuid — forking..."
  cd "$SESSION_DIR" || return 1

  # Fork: brief non-interactive run creates a new child JSONL
  claude --resume "$uuid" --fork-session --dangerously-skip-permissions \
    --print "." > /tmp/smart-resume-fork.log 2>&1

  # Newest JSONL in the projects dir = forked session
  local new_uuid
  new_uuid=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null \
    | head -1 | xargs -I{} basename {} .jsonl 2>/dev/null)

  if [ -n "$new_uuid" ] && [ "$new_uuid" != "$uuid" ]; then
    echo "$new_uuid" > "$SESSION_DIR/.current-session"
    echo "[smart-resume] forked → $new_uuid"
  else
    echo "[smart-resume] fork produced no new UUID, continuing with $uuid"
  fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
RETRIES=0
MAX_RETRIES=5
while true; do
  UUID=$(get_uuid)

  if [ -n "$UUID" ] && has_active_bg_lock; then
    fork_and_update "$UUID"
    UUID=$(get_uuid)  # re-read after potential update
  fi

  # Backend selection — re-read every iteration so `session-model <name> claudex`
  # + one exit inside the session hot-swaps the default for the same conversation.
  BACKEND=$(cat "$SESSION_DIR/.backend" 2>/dev/null | tr -d '[:space:]')
  LAUNCH_ENV=()
  MODEL_ARGS=()
  CKEY=$(claudex_key)
  if [ -n "$CKEY" ] && curl -s -m 2 -o /dev/null "$CLAUDEX_URL/v1/models" 2>/dev/null; then
    # Proxy reachable → always route through it (Claude models forward to real
    # Anthropic, gpt-5.6-sol forwards to codex) so both are always in /model.
    LAUNCH_ENV=(
      "ANTHROPIC_BASE_URL=$CLAUDEX_URL"
      "ANTHROPIC_AUTH_TOKEN=$CKEY"
      "ANTHROPIC_DEFAULT_HAIKU_MODEL=$CLAUDEX_MODEL"
    )
    if [ "$BACKEND" = "claudex" ]; then
      LAUNCH_ENV+=(
        "CLAUDE_CODE_SUBAGENT_MODEL=$CLAUDEX_MODEL"
        "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1"
        "CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY=3"
        "ENABLE_TOOL_SEARCH=false"
      )
      MODEL_ARGS=(--model "$CLAUDEX_MODEL")
      echo "[smart-resume] proxy routed, default: $CLAUDEX_MODEL (claudex preferred)"
    else
      echo "[smart-resume] proxy routed, default: Anthropic (gpt-5.6-sol also selectable via /model)"
    fi
  else
    echo "[smart-resume] ⚠ CLIProxyAPI unreachable on $CLAUDEX_URL — falling back to direct Anthropic, gpt-5.6-sol won't be in /model this launch (brew services start cliproxyapi)"
  fi

  START=$(date +%s)

  if [ -n "$UUID" ]; then
    env "${LAUNCH_ENV[@]}" happy --yolo "${MODEL_ARGS[@]}" --resume "$UUID"
  else
    env "${LAUNCH_ENV[@]}" happy --yolo "${MODEL_ARGS[@]}"
  fi

  EXIT_CODE=$?
  ELAPSED=$(( $(date +%s) - START ))

  # If happy ran for more than 10s, assume user exited deliberately → stop…
  # …unless the backend marker changed vs what we just ran with: that exit was
  # a backend hot-swap, so relaunch immediately on the new backend.
  NEW_BACKEND=$(cat "$SESSION_DIR/.backend" 2>/dev/null | tr -d '[:space:]')
  if [ "$ELAPSED" -ge 10 ]; then
    if [ "$NEW_BACKEND" != "$BACKEND" ]; then
      echo "[smart-resume] backend changed: '${BACKEND:-claude}' → '${NEW_BACKEND:-claude}', relaunching..."
      RETRIES=0
      continue
    fi
    break
  fi

  # Quick exit (< 10s) = resume failed / went to picker. Retry a bounded number
  # of times, then STOP — an unbounded loop on a persistent failure (e.g. auth
  # 403 "Please run /login") spams the pane and dumps the resume command into it.
  RETRIES=$((RETRIES + 1))
  if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
    echo "[smart-resume] happy kept exiting quickly (${RETRIES}×, last code $EXIT_CODE)."
    echo "[smart-resume] Giving up. Likely auth (run: happy, then /login) or a broken UUID."
    echo "[smart-resume] Fix the cause, then re-run: happy-session '$SESSION_NAME'"
    break
  fi
  echo "[smart-resume] happy exited in ${ELAPSED}s (code $EXIT_CODE), retry ${RETRIES}/${MAX_RETRIES}..."
  sleep 2
done
