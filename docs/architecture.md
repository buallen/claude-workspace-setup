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
- registers the terminal with VS Code Restore Terminals

`bin/happy-vibe-session`

- creates or restarts the tmux session
- points Claude Code at VibeProxy's Anthropic-compatible API
- launches Happy with `--model` and `--effort`

`bin/end-session`

- kills the tmux session
- removes the VS Code Restore Terminals entry

`bin/session-restore-mode`

- lists saved VS Code Restore Terminals commands
- switches saved commands between `happy-session` and `happy-vibe-session`
- does not affect currently running tmux sessions

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
