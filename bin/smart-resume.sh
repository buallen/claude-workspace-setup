#!/bin/bash
# smart-resume.sh <SESSION_NAME>
# Auto-recovers from bg-agent lock before starting happy locally.
# Fixes two symptoms of the same root cause (phone→Mac mode switch):
#   - Scenario A: bg-agent killed mid-task → lock residue → fork to clean UUID
#   - Scenario B: happy exits to session picker → same lock → fork + resume

SESSION_NAME="$1"
SESSION_DIR="$HOME/claude-sessions/$SESSION_NAME"

get_uuid() {
  cat "$SESSION_DIR/.current-session" 2>/dev/null
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

  START=$(date +%s)

  if [ -n "$UUID" ]; then
    happy --yolo --resume "$UUID"
  else
    happy --yolo
  fi

  EXIT_CODE=$?
  ELAPSED=$(( $(date +%s) - START ))

  # If happy ran for more than 10s, assume user exited deliberately → stop
  [ "$ELAPSED" -ge 10 ] && break

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
