# Nightly Distillation Prompt

You are analyzing today's Claude Code conversation logs to extract reusable **playbooks**.

A playbook is a short, named procedure that lives under one of three umbrella skills: `/data`, `/troubleshoot`, `/infra`. We do **not** create standalone skill files per task anymore. Everything gets appended to the parent category skill.

## Allowed categories (ONLY extract playbooks in these three)

### 1. `data`
BigQuery, GCP data tools, SQL queries, data pipelines, analytics, Spanner, Pub/Sub, Dataflow, CDC, MERGE, watermark/backlog.

### 2. `troubleshoot`
Incident investigation, RCA, debugging production issues, log analysis (Kibana/Grafana), alert handling, performance diagnosis, memory leaks, slowness.

### 3. `infra`
Infrastructure setup, Terraform, Kubernetes/GKE, Helm, deployment pipelines, cloud resource management, IAM, VPC, networking.

## DO NOT extract playbooks for anything else
Marketing, general coding, UI work, project management, note-taking, general CLI usage — skip entirely.
If a conversation doesn't clearly fit one of the three categories above, output nothing for it.

## What makes a playbook worth extracting

A pattern is worth extracting ONLY if ALL criteria are met:
1. **Reusable** — applies to future situations beyond this specific task
2. **Has a clear trigger** — identifiable situation that would cause someone to run it
3. **Has repeatable steps** — describable as a sequence of actions
4. **Not already covered** — check existing playbooks below, SKIP duplicates or near-duplicates

## Existing playbooks (do NOT duplicate)
{EXISTING_PLAYBOOKS}

## Output format

Output a JSON array. For each playbook:
```json
{
  "category": "data | troubleshoot | infra",
  "slug": "kebab-case-short-name",
  "when": ["trigger phrase 1", "trigger phrase 2"],
  "steps": ["Action-oriented step 1", "Action-oriented step 2"],
  "example": "Short one-line usage example"
}
```

Rules:
- `slug` is lowercase kebab-case, ≤ 5 words, NO category prefix (e.g. `audit-bigquery-merge`, not `data-audit-bigquery-merge`).
- `when` is 3–6 trigger phrases a user might actually say.
- `steps` is 3–8 actionable imperatives. Do NOT start each step with "Step N:".
- `example` is one short line in the user's voice.
- Output ONLY the JSON array.

If nothing fits the three categories, output `[]`.

## Conversations to analyze
{CONVERSATIONS}
