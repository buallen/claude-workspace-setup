# Claude Workspace Setup

Persistent Claude Code / Happy Coder sessions for VS Code.

This project installs a small set of shell commands that keep each named AI
session inside tmux, restore VS Code terminal tabs after restart, and let each
session pick its Claude backend (Anthropic, or GPT via a local proxy).

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

Switch a session's Claude backend (see "Per-session backend" below):

```bash
session-model                 # list every session's backend
session-model "GCP" claudex   # this session now talks to GPT-5.6 Sol
session-model "GCP" claude    # back to Anthropic (default)
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

## Installed Aliases

`setup-workspace.sh` manages this block in `~/.zshrc`:

```zsh
alias claude-session="~/.claude/claude-workspace/bin/claude-session"
alias happy-session="CLAUDE_LAUNCHER=happy ~/.claude/claude-workspace/bin/claude-session"
alias happy-session-private='CLAUDE_LAUNCHER=happy CLAUDE_CONFIG_DIR=~/.claude-private ~/.claude/claude-workspace/bin/claude-session'
alias codex-session="~/.claude/claude-workspace/bin/codex-session"
alias session-model="~/.claude/claude-workspace/bin/session-model"
alias end-session="~/.claude/claude-workspace/bin/end-session"
```

## Otty (optional)

Migrate the same tmux-managed sessions into [Otty](https://otty.sh) — a
native, GPU-accelerated terminal — instead of (or alongside) VS Code:

```bash
bin/otty-setup                    # install Otty + font + Claude-styled theme, then migrate
bin/otty-setup --theme claude-code  # use the dark variant
bin/otty-setup --skip-font        # keep your existing font
```

`otty-setup` is idempotent (safe to re-run) and does not touch VS Code or
`restoreTerminals` — it only installs/configures Otty and opens one Otty tab
per existing tmux session, attaching to the session already running (or
started via `happy-session`/`claude-session` above). Re-run `bin/otty-workspace`
any time to attach newly created sessions without repeating install/config.

## Per-session Backend (claudex)

Each happy session can run Claude Code against a different backend. The default
is your Anthropic login; `claudex` routes that one session through a local
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (`127.0.0.1:8317`)
to OpenAI's GPT-5.6 Sol, billed to your ChatGPT/Codex subscription — useful
when Anthropic usage runs out.

```bash
session-model                  # list all sessions and their backends
session-model "GCP" claudex    # mark GCP for the GPT backend
# then exit Claude inside that session (exit / Ctrl+D):
# smart-resume relaunches the SAME conversation on the new backend
session-model "GCP" claude     # mark it back; exit once again to apply
```

Claude Code reads its backend address only at process start, so the switch
applies on the next launch — `smart-resume.sh` re-reads the marker on every
loop iteration and relaunches immediately when it changes, which makes "one
command + one exit" the whole flow. The marker is
`~/claude-sessions/<name>/.backend`; the proxy API key is read from
`/opt/homebrew/etc/cliproxyapi.conf` and never copied elsewhere.

Setup for the `claudex` backend (one-time): install CLIProxyAPI, bind it to
`127.0.0.1:8317`, add an API key, run `cliproxyapi --codex-login`, and start it
with `brew services start cliproxyapi`.

## Personal Private Session

`Personal` is the only session with private Claude state. When
`happy-session-private Personal ...` starts, `claude-session` first runs
`claude-auth-sync` to copy the newest Claude Code OAuth credential between the
default macOS Keychain slot and `~/.claude-private`'s Keychain slot. The token
is not printed. Transcript files remain strictly separate because the Claude
process still runs with `CLAUDE_CONFIG_DIR=~/.claude-private`.

## How It Works

```text
VS Code terminal tab "GCP"
  -> shell alias happy-session "GCP"
  -> ~/.claude/claude-workspace/bin/claude-session
  -> tmux session "GCP"
  -> happy --yolo --continue or --resume <session-id>
  -> cwd ~/claude-sessions/GCP
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
- CLIProxyAPI (`brew install cliproxyapi`), only for `session-model <name> claudex`
