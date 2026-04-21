# Nightly Distillation Prompt

You are analyzing today's Claude Code conversation logs to extract reusable skills.

## Allowed categories (ONLY extract skills in these three categories)

### 1. `data`
Skills related to: BigQuery, GCP data tools, SQL queries, data pipelines, analytics, Spanner, Pub/Sub, data export/import.
Prefix: `data-`
Example names: `data-query-bigquery`, `data-export-table`, `data-analyze-costs`

### 2. `troubleshoot`
Skills related to: incident investigation, RCA, debugging production issues, log analysis, alert handling, performance diagnosis.
Prefix: `troubleshoot-`
Example names: `troubleshoot-query-logs`, `troubleshoot-trace-request`, `troubleshoot-rca-template`

### 3. `infra`
Skills related to: infrastructure setup, Terraform, Kubernetes, GKE, deployment pipelines, cloud resource management, IAM.
Prefix: `infra-`
Example names: `infra-deploy-service`, `infra-setup-iam`, `infra-scale-cluster`

## DO NOT extract skills for anything else
Marketing, general coding, UI work, project management, note-taking, general CLI usage — skip entirely.
If a conversation doesn't clearly fit one of the three categories above, output nothing for it.

## What makes a skill worth extracting

A pattern is worth extracting ONLY if ALL criteria are met:
1. **Reusable** — applies to future situations beyond this specific task
2. **Has a clear trigger** — identifiable situation that would cause someone to need it
3. **Has repeatable steps** — describable as a sequence of actions
4. **Not already covered** — check existing skills list below

## Existing skills (do not duplicate)
{EXISTING_SKILLS}

## Output format

Output a JSON array. For each skill candidate:
```json
{
  "name": "category-kebab-case-name",
  "category": "data | troubleshoot | infra",
  "description": "One sentence starting with a verb. When to use and what it does.",
  "triggers": ["phrase that would cause someone to invoke this"],
  "steps": ["Step 1: ...", "Step 2: ..."],
  "delegates_to": ["other-skill-name-if-relevant"],
  "example_usage": "User says: '...' → invoke this skill"
}
```

If nothing fits the three categories, output `[]`.

## Conversations to analyze
{CONVERSATIONS}
