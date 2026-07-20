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
- installs the tab-status poller (emoji + backend indicator on every tab)

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
`restoreTerminals` — it only installs/configures Otty, writes the
`~/.zprofile` auto-attach block (Otty's tab shells are login shells that
apparently don't load `~/.zshrc`, so this can't live there — see the script's
header comment for the other three attach-related pitfalls it works around),
and opens one Otty tab per existing tmux session, attaching to the session
already running (or started via `happy-session`/`claude-session` above).
Re-run `bin/otty-workspace` any time to attach newly created sessions without
repeating install/config — it tells an already-attached pane apart from a
disconnected/idle one by checking tmux's own process tree, not by trusting the
(polled, can lag) tab title text.

## Per-session Backend (claudex)

Every session always routes through a local
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (`127.0.0.1:8317`)
when it's reachable — Claude model requests forward straight through to your
real Anthropic account (proxy holds its own Anthropic OAuth credential),
OpenAI's GPT-5.6 Sol requests forward through your ChatGPT/Codex subscription.
Because both live behind the same base URL, **`gpt-5.6-sol` shows up directly
in every session's `/model` picker** (as a "Custom Haiku model") — no backend
switch needed to try it once. If the proxy is down, `smart-resume.sh` falls
back to a direct Anthropic connection for that launch; a dead local proxy
degrades one launch, it doesn't take every session down with it.

`session-model` / `claudex` only sets the *preferred default* for a session —
which model launches active without you picking it from `/model` yourself,
and (for `claudex`) whether subagents also default to GPT:

```bash
session-model                  # list all sessions and their backend preference
session-model "GCP" claudex    # gpt-5.6-sol becomes GCP's preferred default
# then exit Claude inside that session (exit / Ctrl+D):
# smart-resume relaunches the SAME conversation with the new preference
session-model "GCP" claude     # back to Anthropic's own default set; exit once again to apply
```

Claude Code reads its launch environment only at process start, so a
preference change applies on the next launch — `smart-resume.sh` re-reads the
marker on every loop iteration and relaunches immediately when it changes,
which makes "one command + one exit" the whole flow. The marker is
`~/claude-sessions/<name>/.backend`; the proxy API key is read from
`/opt/homebrew/etc/cliproxyapi.conf` and never copied elsewhere.

If a session ends up on the wrong model despite the preference marker (e.g.
`/model` was confirmed with Enter instead of `s`, which sets it as the
**global** default for all sessions, not just that one), pick the right model
from `/model` again and confirm with `s` — session-scoped, not global.

Setup for `claudex` (one-time): install CLIProxyAPI, bind it to
`127.0.0.1:8317`, add an API key, then log in to both providers —
`cliproxyapi -codex-login` for GPT and `cliproxyapi -claude-login` for the
real-Anthropic passthrough — and start it with `brew services start
cliproxyapi`.

Caveat: a conversation that has grown near Claude's context limit may not fit
the GPT model's smaller window — switching models then fails with a
context-window 400. Run `/compact` on the Anthropic backend first, then switch.

## Tab Status Indicators (`tab-status/`)

A launchd-resident poller (`tab-status-poller.py`, every 5s) plus an
edge-triggered hook (`tab-status.sh`, fired on `UserPromptSubmit`/`Stop`/
`Notification`/`SessionStart`) keep each tmux window's title in sync with what
that session is actually doing, forwarded to the terminal tab via `#W` + tmux
`set-titles` — no VS Code/Otty-specific code needed, both just display the
tmux window title:

- 🔥 foreground working · 🤖 background job working · 🫵 waiting for input · 💤 idle
- Backend prefix glyph, borrowed from each CLI's own spinner: ✻ spark = Claude,
  ⠿ braille dots = GPT — animates while working, rests when idle. Ground truth
  is the model name the session's own statusline is *currently* showing (it
  self-reports via `~/.claude/statusline-model.sh`), not the `.backend`
  preference file — those can disagree (a session with no `.backend` set can
  still be actively running `gpt-5.6-sol` if that's what it resolved to).

Division of labour: the poller owns the working overlay (🔥/🤖), fixing what
edge-triggered hooks alone can't catch — sessions driven remotely (phone,
agent-sdk) or by background jobs never fire `UserPromptSubmit` locally, so a
hook-only setup would leave them stuck showing 🫵. The hook owns the resting
states (🫵/💤).

Installed by `setup-workspace.sh` Step 8: copies both files to `~/.claude/hooks/`,
wires the four hook entries into `~/.claude/settings.json` (additive — existing
hook groups for the same events are preserved), and loads
`com.kanlu.tabstatus-poller.plist` via launchd. Re-running the installer is safe
(re-copies, re-wires without duplicating, restarts the poller).

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
hooks/               Claude Code hooks (installed into ~/.claude/claude-workspace/hooks/)
tab-status/          emoji/backend tab indicator poller (installed into ~/.claude/hooks/, separate target dir)
config/              default settings
docs/                architecture notes
setup-workspace.sh   one-command installer
test-plan.md         manual/regression test checklist
```

## Requirements

- macOS
- Homebrew
- tmux
- VS Code and/or [Otty](https://otty.sh)
- Claude Code CLI
- Happy Coder
- CLIProxyAPI (`brew install cliproxyapi`) — powers `session-model <name> claudex`
  and, since every session always routes through it, is what makes `gpt-5.6-sol`
  show up in `/model` at all. If it's not installed/running, sessions just fall
  back to a direct Anthropic connection.
