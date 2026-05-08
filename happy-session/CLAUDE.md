# happy-session

A TypeScript CLI tool for managing Claude Code session history stored in `~/.claude/projects/`.

## Project Goal

Build a CLI called `happy-session` with 5 commands:
- `list` — list all projects and sessions
- `search <query>` — full-text search across sessions
- `summary <session-id>` — human-readable session summary
- `export <session-id>` — export to markdown
- `stats` — usage statistics

## Data Source

Claude Code stores sessions in `~/.claude/projects/`. Each subdirectory is a URL-encoded project path, containing `.jsonl` files (one per session). Each line in a `.jsonl` file is a JSON object.

Key JSONL fields:
- `type`: "user" | "assistant" | "system" | "file-history-snapshot" | "attachment"
- `sessionId`: UUID matching the filename
- `timestamp`: ISO 8601
- `slug`: human-readable session name (appears in system stop_hook_summary messages)
- `cwd`: working directory at time of message
- `message.content`: actual text/tool content
- `uuid`: message UUID

## Quality Bar

- TypeScript strict mode — zero type errors (`tsc --noEmit`)
- Test coverage >= 70% (`vitest run --coverage`)
- Zero ESLint errors (`eslint src/`)
- Each command must have at least one integration test using fixture data

## Working Method

Read `tasks.md` to find the next incomplete task (`- [ ]`).
Complete it, run feedback loops, commit if all pass, mark as `- [x]`.
Repeat until all tasks done, then write `COMPLETED.md`.

## Completion Signal

When all tasks are done, write `COMPLETED.md` with a summary.
