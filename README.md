# Claude Workspace Setup

Persistent Claude Code / Happy Coder sessions for VS Code.

This project installs a small set of shell commands that keep each named AI
session inside tmux, restore VS Code terminal tabs after restart, and optionally
run Happy through VibeProxy/Codex.

## Install

```bash
git clone https://github.com/buallen/claude-workspace-setup.git
cd claude-workspace-setup
bash setup-workspace.sh
source ~/.zshrc
```

The installer:

- installs scripts under `~/.claude/claude-workspace/`
- adds shell aliases to `~/.zshrc`
- configures tmux title forwarding
- configures VS Code terminal title + Restore Terminals
- installs the Claude stop hook for `tasks.md` loops
- adds `happy-vibe-session` to `~/.local/bin/`

## Commands

Start or attach to a Happy session:

```bash
happy-session "GCP"
```

Resume a specific Claude conversation in that named tab:

```bash
happy-session "GCP" 5432a2e4-fc63-44de-86c5-7c9d318c7829
```

Use plain Claude instead of Happy:

```bash
claude-session "GCP"
```

Use Happy through VibeProxy/Codex:

```bash
happy-vibe-session "GCP"
happy-vibe-session --restart "GCP" 5432a2e4-fc63-44de-86c5-7c9d318c7829
```

`happy-vibe-session` defaults to `gpt-5.5` and `--effort max`.

Override those defaults:

```bash
happy-vibe-session --model gpt-5.4 --effort high "GCP"
```

End a session and remove it from VS Code restore:

```bash
end-session "GCP"
```

Start or attach to a named Codex session:

```bash
codex-session "Workspace"
codex-session "Workspace" <codex-session-id>
```

Codex sessions use `~/codex-sessions/<name>` as their fixed working folder and
tmux session names like `codex-Workspace`, so they do not collide with
Claude/Happy tabs named `Workspace`. The runner is `happy codex`.

Switch saved VS Code restored tabs between normal Happy and VibeProxy:

```bash
session-restore-mode list
session-restore-mode vibe
session-restore-mode happy
```

`session-restore-mode vibe` rewrites saved Restore Terminals commands from
`happy-session ...` to `happy-vibe-session --restart ...`. This is intentional:
VS Code restore should recreate the tmux session through VibeProxy instead of only
attaching to an existing tmux session that was started with the old launcher.

## Installed Aliases

`setup-workspace.sh` manages this block in `~/.zshrc`:

```zsh
alias claude-session="~/.claude/claude-workspace/bin/claude-session"
alias happy-session="CLAUDE_LAUNCHER=happy ~/.claude/claude-workspace/bin/claude-session"
alias happy-session-private='CLAUDE_LAUNCHER=happy CLAUDE_CONFIG_DIR=~/.claude-private ~/.claude/claude-workspace/bin/claude-session'
alias happy-vibe-session="~/.claude/claude-workspace/bin/happy-vibe-session"
alias codex-session="~/.claude/claude-workspace/bin/codex-session"
alias session-restore-mode="~/.claude/claude-workspace/bin/session-restore-mode"
alias end-session="~/.claude/claude-workspace/bin/end-session"
```

## How It Works

```text
VS Code terminal tab "GCP"
  -> shell alias happy-session "GCP"
  -> ~/.claude/claude-workspace/bin/claude-session
  -> tmux session "GCP"
  -> happy --yolo --continue or --resume <session-id>
  -> cwd ~/claude-sessions/GCP
```

For VibeProxy:

```text
happy-vibe-session "GCP"
  -> tmux session "GCP"
  -> env ANTHROPIC_BASE_URL=http://localhost:8317 ...
  -> happy --yolo --model=gpt-5.5 --effort=max
```

For Codex:

```text
VS Code terminal tab "Codex: Workspace"
  -> codex-session "Workspace"
  -> tmux session "codex-Workspace"
  -> cwd ~/codex-sessions/Workspace
  -> happy codex
```

## Repository Layout

```text
bin/                 user-facing commands
lib/                 shared session and VS Code restore helpers
hooks/               Claude Code hooks
config/              default settings
docs/                architecture notes
setup-workspace.sh   one-command installer
test-plan.md         manual/regression test checklist
```

## Requirements

- macOS
- Homebrew
- tmux
- VS Code
- Claude Code CLI
- Happy Coder
- VibeProxy, only for `happy-vibe-session`
