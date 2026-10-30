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
#
#   2026-10-30  ONE narrow exception came back: a session whose directory holds
#               `.backend` = `gpt` runs Claude Code on GPT through the local
#               CLIProxyAPI (127.0.0.1:8317) → team gateway codex-lb. It is opt-in
#               per session and changes nothing for any other session, which is
#               what the 08-17 outage taught: back then EVERY session went through
#               the proxy, so one expired proxy credential took down 15 sessions.
#               A gpt session is GPT from its first message and stays GPT — the
#               proxy only serves gpt-* and rejects claude-*, so the session cannot
#               drift across models and hit the thinking-block 400 above.

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
LIB_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../lib" && pwd)"
# Project-dir rule lives in sessionlib only (it used to hard-code "-Users-kan-lu-"
# and replace spaces only, unlike Claude Code, which replaces every non [A-Za-z0-9-]).
PROJ_DIR="$(python3 "$LIB_DIR/sessionlib.py" project-dir "$SESSION_NAME")"

# Read-only. The SessionStart hook (hooks/session-marker.py) is the writer of
# .current-session. Returns the marked conversation if its transcript still
# exists (cleanupPeriodDays purges old ones, and `--resume <purged>` fails on
# every retry), else the newest transcript with a real turn that is not a
# bg-agent job, else nothing -> fresh session.
get_uuid() {
  python3 "$LIB_DIR/sessionlib.py" resume-target "$SESSION_NAME"
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

# Fork past a bg-agent lock and print the conversation to resume. The fork's
# id comes from the fork itself (--output-format json), not from "newest
# transcript", which a concurrent bg job can win. SESSION_MARKER_SKIP keeps this
# throwaway --print run from moving the marker; the hook records the fork once
# happy resumes it.
fork_session() {
  local uuid="$1" new_uuid
  echo "[smart-resume] bg-agent lock on $uuid — forking..." >&2
  new_uuid=$(cd "$SESSION_DIR" && SESSION_MARKER_SKIP=1 claude --resume "$uuid" --fork-session \
      --dangerously-skip-permissions --print "." --output-format json 2>/tmp/smart-resume-fork.log \
    | python3 -c 'import json, sys; d = json.load(sys.stdin); print("" if d.get("is_error") else d.get("session_id", ""))' 2>/dev/null)
  # A failed fork can still report a fresh id that was never written to disk.
  if [ -n "$new_uuid" ] && [ "$new_uuid" != "$uuid" ] && [ -f "$PROJ_DIR/$new_uuid.jsonl" ]; then
    echo "[smart-resume] forked → $new_uuid" >&2
    echo "$new_uuid"
  else
    echo "[smart-resume] fork produced no new UUID, continuing with $uuid" >&2
    echo "$uuid"
  fi
}

# ── Main loop ──────────────────────────────────────────────────────────────
RETRIES=0
MAX_RETRIES=5
while true; do
  # A failed lookup must not silently start a new conversation: retry it.
  if ! UUID=$(get_uuid); then
    RETRIES=$((RETRIES + 1))
    echo "[smart-resume] could not tell which conversation to resume (${RETRIES}/${MAX_RETRIES})" >&2
    if [ "$RETRIES" -ge "$MAX_RETRIES" ]; then
      echo "[smart-resume] giving up rather than starting a new conversation; check: python3 $LIB_DIR/sessionlib.py resume-target '$SESSION_NAME'" >&2
      break
    fi
    sleep 2
    continue
  fi

  if [ -n "$UUID" ] && has_active_bg_lock; then
    UUID=$(fork_session "$UUID")
  fi

  if [ "$(cat "$SESSION_DIR/.backend" 2>/dev/null)" = "gpt" ]; then
    # GPT session (see the 2026-10-30 note at the top). Refuse to start rather
    # than fall back to Anthropic: a silent fallback looks like a working GPT
    # session while it actually runs and bills Claude.
    if ! nc -z -G 3 127.0.0.1 8317 2>/dev/null; then
      echo "[smart-resume] GPT session but the local proxy (127.0.0.1:8317) is down; not starting." >&2
      echo "[smart-resume] start it: launchctl kickstart -k gui/$(id -u)/com.kanlu.cliproxyapi" >&2
      exit 1
    fi
    GPT_LOCAL_KEY=$(security find-generic-password -s claude-CLIPROXY_LOCAL_KEY -w 2>/dev/null)
    if [ -z "$GPT_LOCAL_KEY" ]; then
      echo "[smart-resume] GPT session but Keychain has no claude-CLIPROXY_LOCAL_KEY; not starting." >&2
      exit 1
    fi
    GPT_MODEL="${GPT_MODEL:-gpt-6.1-sol}"
    # ANTHROPIC_MODEL picks the model without passing --model through happy.
    # The DEFAULT_*_MODEL aliases cover Claude Code's own background calls and
    # subagents that ask for haiku/sonnet/opus — the proxy rejects claude-* names.
    # The Fable slot ("hardest, longest-running") maps to gpt-6-astra, which the
    # team gateway reserves for design and hard debugging (WH, 2026-09-22).
    #
    # CLAUDE_CODE_EFFORT_LEVEL=high: settings.json sets effortLevel=xhigh for the
    # Claude sessions, and the GPT session inherited it (seen 2026-10-30). The team
    # gateway caps effort at high and has called out xhigh by name as what drains
    # the shared pool, so pin it here instead of trusting the proxy to clamp.
    LAUNCH_ENV=(-u ANTHROPIC_API_KEY -u CLAUDE_CODE_SUBAGENT_MODEL
                ANTHROPIC_BASE_URL=http://127.0.0.1:8317
                ANTHROPIC_AUTH_TOKEN="$GPT_LOCAL_KEY"
                ANTHROPIC_MODEL="$GPT_MODEL"
                ANTHROPIC_DEFAULT_HAIKU_MODEL="$GPT_MODEL"
                ANTHROPIC_DEFAULT_SONNET_MODEL="$GPT_MODEL"
                ANTHROPIC_DEFAULT_OPUS_MODEL="$GPT_MODEL"
                ANTHROPIC_DEFAULT_FABLE_MODEL=gpt-6-astra
                CLAUDE_CODE_EFFORT_LEVEL=high)
    echo "[smart-resume] GPT session: $GPT_MODEL via local proxy → team gateway"
  else
    # The pane's fallback shell may have INHERITED ANTHROPIC_* from an older
    # proxied launch, so actively unset them (env -u) rather than merely not
    # setting them. No --model pin: /model inside the session decides.
    LAUNCH_ENV=(-u ANTHROPIC_BASE_URL -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_DEFAULT_HAIKU_MODEL
                -u ANTHROPIC_DEFAULT_SONNET_MODEL -u ANTHROPIC_DEFAULT_OPUS_MODEL
                -u ANTHROPIC_DEFAULT_FABLE_MODEL -u ANTHROPIC_MODEL
                -u CLAUDE_CODE_EFFORT_LEVEL -u CLAUDE_CODE_SUBAGENT_MODEL)
    echo "[smart-resume] direct Anthropic, no model pin"
  fi

  START=$(date +%s)

  if [ -n "$UUID" ]; then
    env "${LAUNCH_ENV[@]}" happy --yolo --permission-mode bypassPermissions \
      --resume "$UUID"
  else
    env "${LAUNCH_ENV[@]}" happy --yolo --permission-mode bypassPermissions
  fi

  EXIT_CODE=$?
  ELAPSED=$(( $(date +%s) - START ))

  # `sessionctl stop` drops this flag while it stops the session; without it a
  # stop within 10 s of a start looks like a failed launch and gets retried.
  # The flag holds the stopping sessionctl's pid; honour it only while that
  # process lives, so a flag left by a killed sessionctl cannot disable retries.
  stop_flag="$HOME/.claude/session-locks/${SESSION_NAME}.stopping"
  stop_pid="$(cut -d' ' -f1 "$stop_flag" 2>/dev/null)"
  # Only a positive pid: `kill -0 0` / `-1` succeed (process group / everything).
  if [ -e "$stop_flag" ] && [[ "$stop_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$stop_pid" 2>/dev/null; then
    break
  fi

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
