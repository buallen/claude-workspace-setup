#!/bin/bash
# Isolated end-to-end test for bin/sessionctl.
#
# Runs against a private tmux server (-L), a temporary $HOME and fake
# happy/launcher/claude processes (tests/fixtures/fake-happy) that reproduce
# the real failure modes: happy exits without killing claude, the launcher
# respawns a killed claude, and claude leaves the terminal in raw mode.
# Nothing here touches real sessions.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$REPO/tests/fixtures/fake-happy"
T="$(mktemp -d /tmp/sessionctl-test.XXXXXX)"
export SESSIONLIB_TMUX_SOCKET="sessionctl-test-$$"
export HOME="$T/home"
NODE_DIR="$(dirname "$(command -v node)")"
FAKE="$T/fake"
export PATH="$FAKE/bin:$NODE_DIR:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
NAME="Test Sess"
UUID="11111111-2222-4333-8444-555555555555"
SC=(python3 "$REPO/bin/sessionctl")
PASS=0; FAIL=0

tm() { tmux -L "$SESSIONLIB_TMUX_SOCKET" -f /dev/null "$@"; }
ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

fake_pids() {  # every process started from this test's temp tree
  ps -axo pid=,command= | awk -v t="$T/" 'index($0, t) && !/awk/ {print $1}'
}
count() {  # count <regex>: live fake processes whose command matches
  ps -axo command= | awk -v t="$T/" -v re="$1" 'index($0, t) && $0 ~ re && !/awk/' | wc -l | tr -d ' '
}
pane_tty() { tm display-message -p -t "=$NAME:" '#{pane_tty}'; }
pane_cmd() { tm display-message -p -t "=$NAME:" '#{pane_current_command}'; }

cleanup() {
  tm kill-server 2>/dev/null
  fake_pids | xargs kill -9 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT

# ── fixtures ────────────────────────────────────────────────────────────────
mkdir -p "$FAKE/node_modules/happy/dist" "$FAKE/node_modules/happy/scripts" "$FAKE/claude" "$FAKE/bin"
cp "$FIX/happy-wrapper.mjs" "$FAKE/node_modules/happy/dist/index.mjs"
cp "$FIX/claude_local_launcher.cjs" "$FAKE/node_modules/happy/scripts/claude_local_launcher.cjs"
cp "$FIX/claude.exe" "$FAKE/claude/claude.exe"
printf '#!/bin/bash\nexec node "%s" "$@"\n' "$FAKE/node_modules/happy/dist/index.mjs" > "$FAKE/bin/happy"
chmod +x "$FAKE/bin/happy"

SD="$HOME/claude-sessions/$NAME"
mkdir -p "$SD"
PROJ="$(python3 "$REPO/lib/sessionlib.py" project-dir "$NAME")"
mkdir -p "$PROJ"
echo '{"type":"user","message":{"role":"user","content":"hello"},"timestamp":"2026-01-01T00:00:00Z"}' > "$PROJ/$UUID.jsonl"
touch -t 202601010000 "$PROJ/$UUID.jsonl"   # an old transcript: fresh writes count as "busy"
echo "$UUID" > "$SD/.current-session"
export FAKE_SESSION_HOOK="$REPO/hooks/session-marker.py" FAKE_PROJECT_DIR="$PROJ"
tm new-session -d -s "$NAME" -c "$SD" "/bin/zsh -f"
sleep 1

echo "== sessionctl lifecycle (isolated) =="

# 1. start from an idle shell, resume the marked conversation
"${SC[@]}" start "$NAME" >/dev/null; rc=$?
check "start returns 0" '[ $rc -eq 0 ]'
check "start: one happy, one launcher, one claude" '[ "$(count "happy/dist/index.mjs")" = 1 ] && [ "$(count "claude_local_launcher")" = 1 ] && [ "$(count "claude/claude.exe")" = 1 ]'
check "start: claude resumed the marked conversation" '[ "$(count "claude.exe --resume $UUID")" = 1 ]'

# 2. start again is a no-op
"${SC[@]}" start "$NAME" >/dev/null; rc=$?
check "second start is a no-op (still one happy)" '[ $rc -eq 0 ] && [ "$(count "happy/dist/index.mjs")" = 1 ]'

# 3. status reports the live conversation from happy's log
st="$("${SC[@]}" status "$NAME" --json)"
check "status: conversation $UUID from happy" 'echo "$st" | python3 -c "import json,sys; r=json.load(sys.stdin)[0]; sys.exit(0 if r[\"conversation\"]==\"$UUID\" and r[\"conversation_source\"]==\"happy\" else 1)"'

# 3b. SessionStart hook: the marker follows the main conversation only
sleep 1
check "hook: marker stays on the resumed conversation" '[ "$(cat "$SD/.current-session")" = "$UUID" ]'
cpid="$(ps -axo pid=,command= | awk -v t="$T/" 'index($0,t) && /claude\/claude.exe/ && !/awk/ {print $1}')"
kill -USR1 "$cpid"; sleep 3
NEW="$(cat "$SD/.current-session")"
check "hook: /clear moves the marker to the new conversation" '[ "$NEW" != "$UUID" ] && [ -f "$PROJ/$NEW.jsonl" ]'
(cd "$SD" && node "$FAKE/claude/claude.exe" -p x </dev/null >/dev/null 2>&1)
check "hook: a one-shot claude -p in the session dir leaves the marker alone" '[ "$(cat "$SD/.current-session")" = "$NEW" ]'
touch -t 202601010000 "$PROJ/$NEW.jsonl"   # age it, or the session counts as busy for 3 min

# 4. exact names only: "Test" must not prefix-match "Test Sess"
"${SC[@]}" stop "Test" >/dev/null; rc=$?
check "stop 'Test' -> 2 (no prefix match)" '[ $rc -eq 2 ] && [ "$(count "happy/dist/index.mjs")" = 1 ]'

# 5. stop within 10 s of start: no smart-resume retry, no orphans, sane tty
"${SC[@]}" stop "$NAME" >/dev/null; rc=$?
sleep 3
check "stop returns 0" '[ $rc -eq 0 ]'
check "stop: no happy/launcher/claude left (incl. orphans)" '[ "$(count "happy/dist/index.mjs|claude_local_launcher|claude/claude.exe")" = 0 ]'
check "stop: smart-resume did not relaunch" '[ "$(count "happy/dist/index.mjs")" = 0 ]'
check "stop: pane back at a shell" '[ "$(pane_cmd)" = zsh ]'
check "stop: terminal mode repaired (icrnl isig)" 'stty -a -f "$(pane_tty)" | grep -qw icrnl && stty -a -f "$(pane_tty)" | grep -qw isig'

# 6. start when the pane's terminal was left raw (the 2026-10-23 Support case)
stty -f "$(pane_tty)" raw -echo -icrnl -isig
"${SC[@]}" start "$NAME" >/dev/null; rc=$?
check "start on a raw terminal still comes up" '[ $rc -eq 0 ] && [ "$(count "claude/claude.exe")" = 1 ]'

# 7. busy session: refuse without --force
touch "$HOME/busy-flag"
"${SC[@]}" restart "$NAME" --force >/dev/null
sleep 2
"${SC[@]}" stop "$NAME" >/dev/null; rc=$?
check "stop refuses a busy session (tool command running) -> 3" '[ $rc -eq 3 ] && [ "$(count "claude/claude.exe")" = 1 ]'
rm -f "$HOME/busy-flag"
"${SC[@]}" stop "$NAME" --force >/dev/null; rc=$?
check "stop --force stops it" '[ $rc -eq 0 ] && [ "$(count "claude/claude.exe")" = 0 ]'

# 8. per-session lock: a second caller gets 75 and changes nothing
"${SC[@]}" start "$NAME" >/dev/null
python3 -c "
import fcntl, sys, time
f = open('$HOME/.claude/session-locks/$NAME.lock', 'w'); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(6)" &
holder=$!
sleep 1
before="$(count "claude/claude.exe")"
"${SC[@]}" restart "$NAME" >/dev/null; rc=$?
check "restart while locked -> 75, nothing restarted" '[ $rc -eq 75 ] && [ "$(count "claude/claude.exe")" = "$before" ]'
wait $holder

# 9. restart: same conversation, new processes
old_claude="$(ps -axo pid=,command= | awk -v t="$T/" 'index($0,t) && /claude\/claude.exe/ && !/awk/ {print $1}')"
"${SC[@]}" restart "$NAME" >/dev/null; rc=$?
new_claude="$(ps -axo pid=,command= | awk -v t="$T/" 'index($0,t) && /claude\/claude.exe/ && !/awk/ {print $1}')"
check "restart returns 0, new claude, resumes the post-/clear conversation" '[ $rc -eq 0 ] && [ -n "$new_claude" ] && [ "$new_claude" != "$old_claude" ] && [ "$(count "claude.exe --resume $NEW")" = 1 ]'

# 10. idle report: the transcript was last written on 2026-01-01
"${SC[@]}" idle --hours 24 --json | python3 -c "import json,sys; sys.exit(0 if [r['name'] for r in json.load(sys.stdin)]==['$NAME'] else 1)"; rc=$?
check "idle --hours 24 lists the long-idle session" '[ $rc -eq 0 ]'
"${SC[@]}" idle --hours 20000 --json | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin)==[] else 1)"; rc=$?
check "idle --hours 20000 lists nothing" '[ $rc -eq 0 ]'

# 11. nothing starts an agent by typing into a pane any more
leftover="$(grep -rnE 'send-keys.*(happy --yolo|smart-resume|personal_history|claude --dangerously)' "$REPO/bin" "$REPO/ops" "$REPO/lib" "$REPO/hooks" 2>/dev/null)"
check "no launcher typed into a pane with send-keys" '[ -z "$leftover" ]'

echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
