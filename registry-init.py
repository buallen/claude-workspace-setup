#!/usr/bin/env python3
"""
T09+T10: Registry 初始化器
扫描 ~/.claude/commands/*.md，生成 _registry.md
"""
import os, json, glob, re, sys
from datetime import date

COMMANDS_DIR = os.path.expanduser("~/.claude/commands")
REGISTRY_FILE = os.path.join(COMMANDS_DIR, "_registry.md")


def parse_skill(filepath):
    name = os.path.basename(filepath).replace(".md", "")
    if name.startswith("_"):
        return None
    try:
        with open(filepath) as f:
            content = f.read()
    except Exception:
        return None

    # 提取 description（frontmatter 或首行）
    desc = ""
    m = re.search(r'^description:\s*(.+)$', content, re.MULTILINE)
    if m:
        desc = m.group(1).strip()

    # 提取触发词（from ## When to use 或 triggers:）
    triggers = []
    m = re.search(r'## When to use\n(.*?)(?=\n##|\Z)', content, re.DOTALL)
    if m:
        triggers = [line.lstrip("- ").strip() for line in m.group(1).strip().split("\n") if line.strip().startswith("-")]

    # 提取 delegates_to（Related skills 里的 /skill-name）
    delegates = []
    m = re.search(r'## Related skills\n(.*?)(?=\n##|\Z)', content, re.DOTALL)
    if m:
        delegates = re.findall(r'/(\w[\w-]+)', m.group(1))

    return {
        "name": name,
        "description": desc,
        "triggers": triggers,
        "delegates_to": delegates,
        "called_by": [],
        "last_updated": date.today().isoformat(),
    }


def build_registry():
    skills = {}
    for md_file in sorted(glob.glob(f"{COMMANDS_DIR}/*.md")):
        skill = parse_skill(md_file)
        if skill:
            skills[skill["name"]] = skill

    # 填充 called_by（反向索引）
    for name, skill in skills.items():
        for dep in skill["delegates_to"]:
            if dep in skills:
                if name not in skills[dep]["called_by"]:
                    skills[dep]["called_by"].append(name)

    return skills


def write_registry(skills):
    lines = [
        "# Skill Registry",
        f"_Auto-generated on {date.today().isoformat()}. Do not edit manually._",
        "",
    ]
    for name, s in sorted(skills.items()):
        lines.append(f"## {name}")
        lines.append(f"- **description**: {s['description']}")
        if s["triggers"]:
            lines.append(f"- **triggers**: {json.dumps(s['triggers'], ensure_ascii=False)}")
        if s["delegates_to"]:
            lines.append(f"- **delegates_to**: {json.dumps(s['delegates_to'])}")
        if s["called_by"]:
            lines.append(f"- **called_by**: {json.dumps(s['called_by'])}")
        lines.append(f"- **last_updated**: {s['last_updated']}")
        lines.append("")

    with open(REGISTRY_FILE, "w") as f:
        f.write("\n".join(lines))

    return skills


if __name__ == "__main__":
    skills = build_registry()
    write_registry(skills)
    print(f"Registry 生成完毕: {len(skills)} 个 skill → {REGISTRY_FILE}")
    if "--json" in sys.argv:
        print(json.dumps(skills, ensure_ascii=False, indent=2))
