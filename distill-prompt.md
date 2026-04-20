# Nightly Distillation Prompt

You are analyzing today's Claude Code conversation logs to extract reusable skills and workflows.

## What to extract

A pattern is worth extracting as a skill if it meets ALL of these criteria:
1. **Reusable** — could apply to future situations, not just this specific task
2. **Has a clear trigger** — there's an identifiable situation that would cause someone to need it
3. **Has repeatable steps** — the process can be described as a sequence of actions
4. **Provides value** — saves meaningful time or prevents mistakes

## What NOT to extract
- One-off fixes specific to a single bug or file
- Simple single-step actions (just run a command)
- Anything already covered by existing skills (listed below)

## Existing skills (do not duplicate)
{EXISTING_SKILLS}

## Output format

For each skill candidate, output a JSON object:
```json
{
  "name": "kebab-case-name",
  "description": "One sentence: when to use this skill and what it does. Start with a verb.",
  "triggers": ["phrase that would cause user to invoke this", "another trigger phrase"],
  "delegates_to": ["other-skill-name"],
  "steps": [
    "Step 1: ...",
    "Step 2: ...",
    "Step 3: ..."
  ],
  "example_usage": "User says: '...' → invoke this skill"
}
```

Output a JSON array of all candidates. If no patterns worth extracting, output `[]`.

## Conversations to analyze
{CONVERSATIONS}
