#!/usr/bin/env python3
"""
Skill maintenance — 读取每个 category 的 AUTO-PLAYBOOKS 区块,
让 Claude 去重/合并/删除过窄条目,写回。
"""
import os, re, json, subprocess, sys
from datetime import date

COMMANDS_DIR = os.path.expanduser("~/.claude/commands")
BACKUP_DIR = os.path.expanduser(f"~/claude-sessions/playbook-backups/{date.today().isoformat()}")
CATEGORIES = ("data", "troubleshoot", "infra")
BEGIN = "<!-- BEGIN AUTO-PLAYBOOKS -->"
END = "<!-- END AUTO-PLAYBOOKS -->"


def parse_block(text):
    m = re.search(re.escape(BEGIN) + r'(.*?)' + re.escape(END), text, re.DOTALL)
    if not m:
        return None, None, None
    block = m.group(1)
    playbooks = []
    for entry in re.split(r'\n(?=### )', block.strip()):
        entry = entry.strip()
        if not entry.startswith("### "):
            continue
        slug_m = re.match(r'### ([a-z0-9-]+)', entry)
        when_m = re.search(r'\*\*When:\*\*\s*(.+)', entry)
        steps_m = re.search(r'\*\*Steps:\*\*\s*\n((?:\d+\..*\n?)+)', entry)
        example_m = re.search(r'\*\*Example:\*\*\s*(.+)', entry)
        if not (slug_m and when_m and steps_m):
            continue
        steps = [s.strip() for s in re.findall(r'\d+\.\s*(.+)', steps_m.group(1))]
        playbooks.append({
            "slug": slug_m.group(1),
            "when": [w.strip() for w in when_m.group(1).split(";") if w.strip()],
            "steps": steps,
            "example": example_m.group(1).strip() if example_m else ""
        })
    return m.start(1), m.end(1), playbooks


def render(pbs):
    parts = []
    for pb in sorted(pbs, key=lambda x: x["slug"]):
        when = "; ".join(pb["when"])
        steps = "\n".join(f"{i+1}. {s}" for i, s in enumerate(pb["steps"]))
        s = f"### {pb['slug']}\n**When:** {when}\n\n**Steps:**\n{steps}\n"
        if pb.get("example"):
            s += f"\n**Example:** {pb['example']}\n"
        parts.append(s)
    return "\n" + "\n\n".join(parts) + "\n"


def call_claude(prompt, timeout=300):
    try:
        r = subprocess.run(
            ["claude", "--print"],
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except Exception as e:
        return None, f"claude exec failed: {e}"
    text = r.stdout
    m = re.search(r'\[.*\]', text, re.DOTALL)
    if not m:
        return None, "no JSON array in output"
    try:
        return json.loads(m.group()), None
    except Exception as e:
        return None, f"JSON parse failed: {e}"


def validate(cleaned, original):
    if not isinstance(cleaned, list):
        return "not a list"
    if len(cleaned) == 0:
        return "empty output"
    if len(cleaned) < max(1, len(original) // 2):
        return f"too aggressive ({len(original)}→{len(cleaned)}), rejecting"
    for pb in cleaned:
        if not isinstance(pb, dict):
            return "entry is not dict"
        for k in ("slug", "when", "steps"):
            if k not in pb:
                return f"missing {k}"
        if not isinstance(pb["when"], list) or not pb["when"]:
            return f"bad when in {pb.get('slug')}"
        if not isinstance(pb["steps"], list) or not pb["steps"]:
            return f"bad steps in {pb.get('slug')}"
        if not re.match(r'^[a-z0-9-]+$', str(pb["slug"])):
            return f"bad slug {pb.get('slug')}"
    return None


def maintain(cat):
    path = os.path.join(COMMANDS_DIR, f"{cat}.md")
    if not os.path.exists(path):
        return None, 0, 0, "no file"
    text = open(path).read()
    start, end, playbooks = parse_block(text)
    if playbooks is None:
        return None, 0, 0, "no AUTO-PLAYBOOKS block"
    if len(playbooks) < 2:
        return None, len(playbooks), len(playbooks), f"skipped (n={len(playbooks)})"

    os.makedirs(BACKUP_DIR, exist_ok=True)
    with open(os.path.join(BACKUP_DIR, f"{cat}.md.bak"), "w") as f:
        f.write(text)

    prompt = f"""You are maintaining the /{cat} category's playbook collection for Claude Code. These playbooks are reusable procedures for data/troubleshoot/infra work.

Current playbooks:
```json
{json.dumps(playbooks, indent=2, ensure_ascii=False)}
```

Output a CLEANED-UP JSON array with the same schema. You may:
1. **Merge** near-duplicate playbooks (>60% overlapping steps) into one — combine their `when` triggers, pick the clearer slug, unify the steps.
2. **Delete** playbooks that are too narrow to be reusable (single-client names, hard-coded incident IDs, one-off investigations unlikely to recur).
3. **Rewrite** steps for clarity when they are vague, redundant, or use unexplained jargon.
4. **Preserve** everything valuable — when in doubt, keep it.

Rules:
- Output MUST be a JSON array of objects with keys: `slug` (kebab-case), `when` (list of strings), `steps` (list of strings), `example` (string, optional).
- Do NOT invent new playbooks or steps not derivable from input.
- If nothing needs changing, output the exact same list unchanged.
- Output ONLY the JSON array. No prose, no markdown fence unless necessary.
"""

    cleaned, err = call_claude(prompt)
    if err:
        return False, len(playbooks), len(playbooks), f"claude error: {err}"
    v = validate(cleaned, playbooks)
    if v:
        return False, len(playbooks), len(cleaned) if isinstance(cleaned, list) else 0, f"rejected: {v}"

    new_block = render(cleaned)
    new_text = text[:start] + new_block + text[end:]
    with open(path, "w") as f:
        f.write(new_text)
    return True, len(playbooks), len(cleaned), "ok"


def main():
    print("🧹 Playbook 梳理中...")
    for cat in CATEGORIES:
        ok, before, after, note = maintain(cat)
        tag = "✓" if ok else ("—" if ok is None else "✗")
        delta = f"{before}→{after}" if before != after else f"{before}"
        print(f"  {tag} /{cat}: {delta} ({note})")


if __name__ == "__main__":
    main()
