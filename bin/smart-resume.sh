#!/bin/bash
# smart-resume.sh <SESSION_NAME>
# Auto-recovers from bg-agent lock before starting happy locally.
# Fixes two symptoms of the same root cause (phone→Mac mode switch):
#   - Scenario A: bg-agent killed mid-task → lock residue → fork to clean UUID
#   - Scenario B: happy exits to session picker → same lock → fork + resume
#
# Backend: direct to Anthropic, no local proxy. (simplified 2026-09-14)
#   Every session uses the Keychain OAuth credential straight against Anthropic,
#   with no --model pin — /model inside the session is the only thing that
#   decides which model runs.
#
#   History, so nobody re-adds any of this:
#     2026-08-05  the GPT path was removed. gpt-5.6-sol was dropped from the
#                 gateway, so every pin to it resolved to a dead model ("It may
#                 not exist or you may not have access to it"), and sessions that
#                 round-tripped between Anthropic and codex died on
#                 `400 Invalid signature in thinking block`.
#     2026-08-17  CLIProxyAPI (127.0.0.1:8317) was retired and uninstalled.
#     2026-09-14  claude-code-router (127.0.0.1:3456) was removed; it had also
#                 written a broken // comment into ~/.claude/settings.json, which
#                 silently disabled every global hook/env until it was fixed.
#   The proxy-selection branches and the ~/claude-sessions/<name>/.backend marker
#   were dead code after that (cliproxyapi.conf no longer exists, so the proxy
#   branch could never be entered) and have been deleted.

SESSION_NAME="$1"
if [ "$SESSION_NAME" = "Personal" ]; then
  # 先解析软链：经 ~/.happy/smart-resume.sh 调用时，dirname 会落在 ~/.happy，
  # cd -P 只解析目录不解析文件本身，../lib 就找不到了（2026-10-23 重启 Personal 时踩到）。
  SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  export CLAUDE_CONFIG_DIR="$HOME/.claude-private"
  # Personal 没有活跃会话，token 只能靠外部镜像；6h 定时器最坏会留下一个
  # 比 token 寿命还长的过期窗口，所以启动这一刻再同步一次才能封住。
  python3 "$HOME/bin/claude-token-refresh.py" --sync-only >/dev/null 2>&1 || true
  exec python3 "$SCRIPT_DIR/../lib/personal_history.py" --launch happy
fi
SESSION_DIR="$HOME/claude-sessions/$SESSION_NAME"
PROJ_DIR="$HOME/.claude/projects/-Users-kan-lu-claude-sessions-${SESSION_NAME// /-}"

# .current-session can outlive its transcript: cleanupPeriodDays (14) purges old
# JSONLs, and `--resume <purged uuid>` fails with "No conversation found" on
# every retry. Only return a uuid whose JSONL still exists; otherwise fall back
# to the newest surviving JSONL (and record it), or nothing → fresh session.
get_uuid() {
  local uuid newest
  uuid=$(cat "$SESSION_DIR/.current-session" 2>/dev/null)
  if [ -n "$uuid" ] && [ -f "$PROJ_DIR/$uuid.jsonl" ]; then
    echo "$uuid"
    return
  fi
  newest=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$newest" ]; then
    newest=$(basename "$newest" .jsonl)
    echo "[smart-resume] stale uuid ${uuid:-<none>}, using newest transcript $newest" >&2
    echo "$newest" > "$SESSION_DIR/.current-session"
    echo "$newest"
  elif [ -n "$uuid" ]; then
    echo "[smart-resume] transcript for $uuid was purged, starting a fresh session" >&2
    rm -f "$SESSION_DIR/.current-session"
  fi
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

  # The pane's fallback shell may have INHERITED ANTHROPIC_* from an older
  # proxied launch, so actively unset them (env -u) rather than merely not
  # setting them. No --model pin: /model inside the session decides.
  LAUNCH_ENV=(-u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_DEFAULT_HAIKU_MODEL -u CLAUDE_CODE_SUBAGENT_MODEL)
  echo "[smart-resume] direct Anthropic, no model pin"

  START=$(date +%s)

  if [ -n "$UUID" ]; then
    env "${LAUNCH_ENV[@]}" happy --yolo --permission-mode bypassPermissions \
      --resume "$UUID"
  else
    env "${LAUNCH_ENV[@]}" happy --yolo --permission-mode bypassPermissions
  fi

  EXIT_CODE=$?
  ELAPSED=$(( $(date +%s) - START ))

  # If happy ran for more than 10s, assume the user exited deliberately → stop.
  # NOTE: an external `kill` of a long-lived session also lands here and ends the
  # loop; relaunch that pane with `happy-session '<name>'`.
  if [ "$ELAPSED" -ge 10 ]; then
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
