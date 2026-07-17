# Architecture

The project has one install entrypoint and three runtime command families.

## Install Layer

`setup-workspace.sh` installs the repo into:

```text
~/.claude/claude-workspace/
```

It then updates `~/.zshrc`, tmux settings, VS Code settings, and Claude Code
hooks. User commands point directly at installed `bin/*` files; there is no
extra wrapper layer.

## Runtime Commands

`bin/claude-session`

- creates `~/claude-sessions/<name>`
- starts or attaches to `tmux` session `<name>`
- launches either `claude` or `happy`, depending on `CLAUDE_LAUNCHER`
- syncs Claude Code OAuth credentials only for the `Personal` session when it
  runs with `CLAUDE_CONFIG_DIR=~/.claude-private`
- removes any default `~/.claude/projects/...Personal` startup shadow if it is
  only a symlink or permission-mode stub
- registers the terminal with VS Code Restore Terminals

`bin/claude-auth-sync`

- compares the default and private macOS Keychain Claude Code credential slots
- copies the newest OAuth credential to the older slot without printing the token
- syncs non-secret auth metadata in `.claude.json`
- is invoked by `claude-session` only for `Personal`

`bin/smart-resume.sh`

- wraps the `happy --yolo --resume` launch for happy-session tabs
- detects a live bg-agent lock and forks to a clean UUID before resuming
- retries bounded times on quick exits (auth failures, broken UUIDs)
- reads `~/claude-sessions/<name>/.backend` each iteration and, when it says
  `claudex`, injects the CLIProxyAPI env so the same conversation resumes on
  GPT-5.6 Sol; relaunches immediately when the marker changes mid-session

`bin/session-model`

- shows or sets a session's Claude backend (`claude` = Anthropic default,
  `claudex` = GPT-5.6 Sol via a local CLIProxyAPI on 127.0.0.1:8317)
- writes the `~/claude-sessions/<name>/.backend` marker consumed by
  `smart-resume.sh`; exiting Claude inside the session applies the switch
- reads the proxy API key from `/opt/homebrew/etc/cliproxyapi.conf` — the key
  is never copied anywhere else

`bin/end-session`

- kills the tmux session
- removes the VS Code Restore Terminals entry

`bin/codex-session`

- creates `~/codex-sessions/<name>`
- starts or attaches to tmux session `codex-<name>`
- launches `happy codex` with cwd pointed at that fixed folder
- registers the terminal with VS Code Restore Terminals as `Codex: <name>`

## Shared Helpers

`lib/session.sh` owns shell-level session mechanics:

- session directory paths
- Claude JSONL session-id lookup
- tmux attach/switch behavior
- VS Code CWD escape sequence

`lib/vscode_restore.py` owns JSON mutation for VS Code settings:

- register restore command
- remove restore command
- atomic writes

## Hooks

`hooks/loop.sh` is the installed Claude Stop hook. If the current directory has
a `tasks.md` with unchecked items, it blocks completion and asks Claude to work
the next task.

`hooks/sync-session-id.sh` is kept as an available hook helper, but it is not
enabled by default.
