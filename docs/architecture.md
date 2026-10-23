# Architecture

## Layers

| Layer | Component | Owns |
|---|---|---|
| Display | Otty tab (or VS Code terminal) | nothing; one tab attaches to one tmux session |
| Persistence | tmux session `<name>`, cwd `~/claude-sessions/<name>` | keeping the agent alive when the terminal quits |
| Lifecycle | `bin/sessionctl` + `lib/sessionlib.py` | start / stop / restart / status, one lock per session |
| Resume | `bin/smart-resume.sh` | which conversation to resume, bg-lock fork, bounded retries |
| Sync | happy wrapper (`node .../happy/dist/index.mjs`) | phone sync, local ⇄ remote mode |
| Work | `claude` (via `claude_local_launcher.cjs`) | the conversation; writes `~/.claude/projects/<key>/<uuid>.jsonl` |

Process chain of a running session:

```text
tmux pane shell
└─ sh -c "stty sane; env ... bash smart-resume.sh '<name>'; exec /bin/zsh -l"
   └─ bash smart-resume.sh <name>
      └─ node bin/happy --yolo --permission-mode bypassPermissions --resume <uuid>
         └─ node happy/dist/index.mjs            ← "happy wrapper"
            └─ node happy/scripts/claude_local_launcher.cjs
               └─ claude --resume <uuid> ...     ← tool shells (zsh -c ...) run below it
```

`exec /bin/zsh -l` keeps the pane (and the Otty tab) when the agent exits.
One `happy daemon` per machine registers sessions with the server and lets the
phone start or resume sessions.

## sessionlib: one rule per decision

Before this module, five scripts each had their own copy: four "newest
conversation" algorithms, three project-directory rules, three liveness checks.

- **Paths.** `session_dir(name) = ~/claude-sessions/<name>`; config root is
  `~/.claude-private` for `Personal`, else `~/.claude`; project dir is the
  session path with every character outside `[A-Za-z0-9-]` turned into `-`
  (Claude Code's and happy's rule).
- **Processes.** Everything is found from the pane's process tree, so
  sessions started by older code are recognised too.
- **State.** `busy` (tool shell under claude, transcript written < 180 s,
  working indicator on screen), `background` (bg-agent job working < 600 s),
  `waiting` (last hook status), `idle`, `stopped`, `missing`. Same thresholds
  as the tab-status poller.
- **Live conversation.** happy's log (`[SESSION_SCANNER] New session: <uuid>`,
  which follows `/clear`, `/compact` and forks) → claude's `--resume` argument
  → the marker if its transcript exists → newest transcript with a real turn
  that is not a bg-agent job.
- **Auth error.** The live conversation's last user/assistant entry is an
  `isApiErrorMessage` with `error: "authentication_failed"`.

## The conversation marker

`~/claude-sessions/<name>/.current-session` tells `smart-resume.sh` what to
resume. Writers:

1. `hooks/session-marker.py` on `SessionStart` (payload: `session_id`,
   `transcript_path`, `cwd`, `source`; the hook's parent is the claude that
   fired it). It writes only when that claude is the session's main claude
   (its parent is the pane's launcher, or the happy wrapper in remote mode;
   a `claude -p` run from a tool shell does not count), the transcript is in
   the session's project dir, and the id is not a bg-agent job's. Forks run with
   `SESSION_MARKER_SKIP=1`.
2. `sessionctl stop` aligns it with happy's log before stopping (same source
   of truth, a safety net).
3. `claude-session NAME <uuid>`, an explicit choice, via `sessionlib write-marker`.

Readers (`smart-resume.sh`, `lib/session.sh`) never write it.

## sessionctl

| Command | Behaviour |
|---|---|
| `start` | new tmux session, or `respawn-pane -k` over an idle shell; no-op if running; refuses a pane running something else |
| `stop` | refuse if busy (unless `--force`); align marker; drop `<name>.stopping` flag; SIGTERM happy → wait 15 s (→ SIGKILL); stop orphaned launcher, then claude; wait for the pane shell; `stty -f <tty> sane` |
| `restart` | stop + start under one lock |
| `status`, `idle` | from sessionlib |

Exit codes: 0 ok, 1 error, 2 no such session, 3 busy, 4 pid identity changed,
5 a process would not stop, 75 locked. Every signal is sent only if the pid's
start time and command still match what was recorded.

## Failure modes this design answers

| Symptom | Cause | Answer |
|---|---|---|
| New Claude prints "Resume this session with" and exits; Enter does nothing in the pane | a killed Claude left the pty in raw mode (`-icrnl -isig`) | launch command runs `stty sane`; `stop` repairs the tty; no typing into panes |
| Two claudes on one conversation; daemon refuses phone resume | happy's SIGTERM handler exits without killing claude | `stop` kills the orphaned launcher, then claude |
| Killed claude comes straight back | the launcher respawns it | stop the launcher first |
| Session relaunched right after a stop | smart-resume retries exits < 10 s | `<name>.stopping` flag ends its loop |
| `happy --yolo --resume` typed into a live conversation | watchdog liveness check returned from a pipeline subshell | state from `sessionctl status` |
| "Product" acted on "Product priorities" | tmux prefix matching | exact targets `=name:` everywhere |
| Resumed the wrong conversation after `/clear` | nothing updated the marker mid-session | SessionStart hook |
| Idle sessions burn CPU and memory | happy re-read the whole transcript every 3 s | incremental scanner (ops patch, upstream PR #1915) |

## ops (launchd)

- `claude-auth-watchdog.sh`, every 10 min: restarts stopped sessions with
  `sessionctl start`; runs the in-session `/login` flow only for a real,
  unanswered `authentication_failed` in an idle session.
- `claude-nightly-upgrade.sh`, 04:00: upgrades Claude Code nightly; restarts
  idle sessions still on the old version only every 14 days (timestamp in
  `~/.claude/state/nightly-restart-last`, since launchd cannot express it).
- `log-janitor.sh`, hourly: log/disk housekeeping; daily Otty `state.db`
  backup, idle-session report (no auto-stop), happy patch check.
- Shared private settings: `~/.config/claude-workspace/local.env`.

## Personal

`Personal` uses `CLAUDE_CONFIG_DIR=~/.claude-private`. `claude-session`
refuses to start it otherwise and syncs its Keychain credential slot;
`personal_history.py` chooses its conversation by latest real message and
refuses while a private bg job is working.
