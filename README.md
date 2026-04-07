# Claude Code Persistent Workspace Setup

Keep your Claude/Happy sessions alive across VS Code crashes, and restore all named terminal tabs automatically on restart — with conversations resuming exactly where they left off.

## The Problem

When VS Code crashes, all terminal tabs and Claude/Happy processes die. You lose your tab names, your conversations, and have to restart everything manually.

## The Solution

Three components working together:

- **tmux** — keeps Claude/Happy processes alive even when VS Code closes
- **Happy Coder** — syncs sessions to the cloud and your mobile device
- **Restore Terminals** (VS Code extension) — remembers tab names and restores them on startup

Every `happy-session "My Task"`:
1. Creates a symlink `~/claude-sessions/My Task` → `~/Documents/GitHub` (so Happy shows the right tab name)
2. Creates a named tmux session running `happy --yolo` (always with full permissions)
3. Sets the VS Code terminal tab title to "My Task"
4. Auto-registers itself so VS Code restores the tab on restart
5. On re-attach, resumes your last conversation automatically

## One-Click Setup

```bash
git clone https://github.com/buallen/claude-workspace-setup.git
cd claude-workspace-setup
bash setup-workspace.sh
source ~/.zshrc
```

The script handles everything:
- Installs tmux (via Homebrew if not present)
- Installs all scripts to `~/.claude/`
- Adds shell aliases to `~/.zshrc`
- Configures VS Code: tab titles + **Happy Session** terminal profile
- Configures the L4 Loop Stop Hook in `~/.claude/settings.json`
- Installs the VS Code **Restore Terminals** extension

## Daily Usage

### Start a new Happy session (recommended)

```bash
happy-session "Task Name"
```

Or in VS Code: click the **+** dropdown → **Happy Session** (prompts for a name).

This creates a symlink, starts `happy --yolo --continue` in a tmux session, and registers the tab in VS Code.

### Resume a specific conversation

```bash
happy-session "Task Name" <conversation-id>
```

Loads a specific conversation ID into a named tab. The conversation file is automatically copied so `--resume` can find it.

### Use plain Claude instead of Happy

```bash
claude-session "Task Name"
claude-session "Task Name" <conversation-id>
```

Same flow but runs `claude --dangerously-skip-permissions` instead of Happy.

### End a session when done

```bash
end-session "Task Name"
```

Kills the tmux session and removes it from the VS Code restore list.

### List running sessions

```bash
tmux list-sessions
```

## After a VS Code Crash

VS Code automatically re-opens all registered terminal tabs. Each tab runs `happy-session "Task Name"` which re-attaches to the still-running tmux session. Conversations continue exactly where they left off — no context lost.

## VS Code Terminal Profile

After setup, clicking **+** → **Happy Session** in VS Code terminal opens a prompt:

```
Session name: █
```

Type a name and press Enter. A new Happy session starts immediately, named and cloud-synced.

## What's Included

| File | Purpose |
|------|---------|
| `setup-workspace.sh` | One-click setup script |
| `claude-session.sh` | Start/restore a named Claude or Happy session |
| `end-session.sh` | Kill a session and clean up VS Code settings |
| `loop.sh` | L4 Stop Hook — drives task list automation |

## Session Architecture

```
VS Code tab "Features"
  └─ tmux session "Features"
       └─ happy --yolo --resume <conv-id>   ← cloud-synced, mobile-accessible
            └─ ~/claude-sessions/Features   ← symlink → ~/Documents/GitHub
```

## L4 Loop (Automated Task Execution)

`loop.sh` is a Claude Code Stop Hook that enables batch task execution. Create a `tasks.md` in your project:

```markdown
- [ ] Write unit tests for auth module
- [ ] Update API documentation  
- [ ] Fix null pointer bug in payment service
```

Claude executes each task one by one, marks it `[x]` when done, and moves to the next — up to 100 iterations automatically.

## Requirements

- macOS
- [Homebrew](https://brew.sh)
- [Claude Code CLI](https://claude.ai/code)
- [Happy Coder](https://happycoder.app) (for cloud sync and mobile access)
- VS Code
