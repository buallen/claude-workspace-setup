# Claude Code Persistent Workspace Setup

Keep your Claude Code sessions alive across VS Code crashes, and restore all named terminal tabs automatically on restart — with conversations resuming exactly where they left off.

## The Problem

When VS Code crashes, all terminal tabs and Claude Code processes die. You lose your tab names, your Claude conversations, and have to restart everything manually.

## The Solution

Two components working together:

- **tmux** — keeps Claude processes alive even when VS Code closes
- **Restore Terminals** (VS Code extension) — remembers tab names and restores them on startup

Every time you run `claude-session "My Task"`, it:
1. Creates a named tmux session running Claude
2. Sets the VS Code terminal tab title
3. Auto-registers itself in VS Code settings so it restores on restart
4. On re-attach, resumes your last Claude conversation automatically (`--continue`)

## One-Click Setup

```bash
bash setup-workspace.sh
source ~/.zshrc
```

That's it. The script handles everything:
- Installs tmux (via Homebrew if not present)
- Writes all scripts to `~/.claude/`
- Adds shell aliases to `~/.zshrc`
- Configures the L4 Loop Stop Hook in `~/.claude/settings.json`
- Installs the VS Code **Restore Terminals** extension (`EthanSK.restore-terminals`)

## Manual Setup

If you prefer to understand each step:

### Step 1: Install tmux

```bash
brew install tmux
tmux -V
```

### Step 2: Copy scripts

```bash
mkdir -p ~/.claude/hooks

cp loop.sh           ~/.claude/hooks/loop.sh
cp claude-session.sh ~/.claude/claude-session.sh
cp end-session.sh    ~/.claude/end-session.sh

chmod +x ~/.claude/hooks/loop.sh
chmod +x ~/.claude/claude-session.sh
chmod +x ~/.claude/end-session.sh
```

### Step 3: Add shell aliases

Add to `~/.zshrc`:

```bash
alias claude-session="~/.claude/claude-session.sh"
alias end-session="~/.claude/end-session.sh"
```

Then:
```bash
source ~/.zshrc
```

### Step 4: Configure the L4 Stop Hook

Add to `~/.claude/settings.json` under `"hooks"`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/YOUR_USERNAME/.claude/hooks/loop.sh",
            "timeout": 10,
            "statusMessage": "Checking task list..."
          }
        ]
      }
    ]
  }
}
```

### Step 5: Install VS Code extension

```bash
code --install-extension EthanSK.restore-terminals
```

Or manually: VS Code → Extensions → search **Restore Terminals** by EthanSK → Install.

## Daily Usage

### Start a new Claude session

```bash
claude-session "Task Name"
```

This opens (or re-attaches to) a tmux session named "Task Name", starts Claude inside it, and registers the tab so VS Code restores it on restart.

**New sessions** start Claude fresh. **Existing sessions** re-attach and Claude resumes the last conversation automatically via `--continue`.

### Resume a specific conversation

If you have a Claude session ID and want to load it into a named tab:

```bash
claude-session "Task Name" <session-id>
```

This creates a new tmux session that runs `claude --resume <session-id>`, loading that specific conversation. Useful when you want to assign an existing conversation to a named workspace tab.

### End a session when done

```bash
end-session "Task Name"
```

Kills the tmux session and removes it from the VS Code restore list.

### List running sessions

```bash
tmux list-sessions
```

### Re-attach to a detached session

```bash
claude-session "Task Name"
```

Same command — if the session already exists, it just re-attaches and Claude picks up right where it left off.

## After a VS Code Crash

VS Code will automatically re-open all registered terminal tabs on startup. Each tab runs `claude-session "Task Name"` which re-attaches to the still-running tmux session. Your Claude conversations continue **exactly where they left off** — no context lost, no re-explaining the task.

## What's Included

| File | Purpose |
|------|---------|
| `setup-workspace.sh` | One-click setup script |
| `claude-session.sh` | Start/restore a named Claude session (auto-resumes conversation) |
| `end-session.sh` | Kill a session and clean up VS Code settings |
| `loop.sh` | L4 Stop Hook — drives task list automation |

## L4 Loop (Bonus: Automated Task Execution)

`loop.sh` is a Claude Code Stop Hook that enables batch task execution. Create a `tasks.md` in your project:

```markdown
- [ ] Write unit tests for auth module
- [ ] Update API documentation
- [ ] Fix null pointer bug in payment service
```

Claude will automatically execute each task one by one, mark it `[x]` when done, and move to the next — up to 100 iterations.

## Requirements

- macOS
- [Homebrew](https://brew.sh)
- [Claude Code CLI](https://claude.ai/code)
- VS Code
