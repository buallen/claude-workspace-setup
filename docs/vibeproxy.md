# VibeProxy Sessions

`happy-vibe-session` runs Happy through VibeProxy so Claude Code can use Codex
models via VibeProxy's Anthropic-compatible endpoint.

Defaults:

```text
base URL: http://localhost:8317
model:    gpt-5.5
effort:   max
```

Start:

```bash
happy-vibe-session "GCP"
```

Restart and resume an existing Claude session:

```bash
happy-vibe-session --restart "GCP" <session-id>
```

If an old restored conversation keeps using a Claude model name, switch inside
Claude Code:

```text
/model gpt-5.5
/effort max
```
