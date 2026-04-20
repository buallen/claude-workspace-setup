#!/usr/bin/env python3
"""
T12: registry 查询工具 — 按触发词/能力搜索 skill
T13: pipeline 候选追踪 — 记录哪些 skill 经常连用

Usage:
  python3 registry-query.py search "部署"
  python3 registry-query.py pipelines
  python3 registry-query.py graph
"""
import os, json, re, sys
from datetime import date

COMMANDS_DIR = os.path.expanduser("~/.claude/commands")
REGISTRY_FILE = os.path.join(COMMANDS_DIR, "_registry.md")
PIPELINE_LOG = os.path.join(COMMANDS_DIR, "_pipelines.json")


def load_registry():
    """从 _registry.md 解析 skill 列表"""
    skills = {}
    if not os.path.exists(REGISTRY_FILE):
        return skills
    with open(REGISTRY_FILE) as f:
        content = f.read()
    current = None
    for line in content.split("\n"):
        if line.startswith("## "):
            current = line[3:].strip()
            skills[current] = {"name": current, "description": "", "triggers": [], "delegates_to": [], "called_by": []}
        elif current and line.startswith("- **description**:"):
            skills[current]["description"] = line.split(":", 1)[1].strip()
        elif current and line.startswith("- **triggers**:"):
            try:
                skills[current]["triggers"] = json.loads(line.split(":", 1)[1].strip())
            except Exception:
                pass
        elif current and line.startswith("- **delegates_to**:"):
            try:
                skills[current]["delegates_to"] = json.loads(line.split(":", 1)[1].strip())
            except Exception:
                pass
        elif current and line.startswith("- **called_by**:"):
            try:
                skills[current]["called_by"] = json.loads(line.split(":", 1)[1].strip())
            except Exception:
                pass
    return skills


def search(query, skills):
    """按关键词搜索匹配的 skill"""
    query_lower = query.lower()
    results = []
    for name, s in skills.items():
        score = 0
        if query_lower in name.lower():
            score += 3
        if query_lower in s.get("description", "").lower():
            score += 2
        for t in s.get("triggers", []):
            if query_lower in t.lower():
                score += 1
        if score > 0:
            results.append((score, name, s))
    results.sort(reverse=True)
    return results


def show_pipelines(skills):
    """展示可能的 pipeline 组合（从 delegates_to 关系推导）"""
    # 找到所有链式关系
    pipelines = []
    for name, s in skills.items():
        if s.get("delegates_to"):
            chain = [name] + s["delegates_to"]
            # 扩展链（如果被委托的 skill 也有委托）
            extended = list(chain)
            last = chain[-1]
            if last in skills and skills[last].get("delegates_to"):
                extended.extend(skills[last]["delegates_to"])
            if len(extended) >= 2:
                pipelines.append(extended)

    # T13: 从 pipeline log 加载使用频率
    usage = {}
    if os.path.exists(PIPELINE_LOG):
        with open(PIPELINE_LOG) as f:
            usage = json.load(f)

    print("## 已知 Pipelines\n")
    seen = set()
    for pipeline in pipelines:
        key = " → ".join(pipeline)
        if key not in seen:
            seen.add(key)
            count = usage.get(key, 0)
            freq = f" (使用 {count} 次)" if count > 0 else ""
            print(f"  {key}{freq}")


def record_pipeline(pipeline_str):
    """T13: 记录 pipeline 使用（pipeline_str 如 'prd → l4'）"""
    usage = {}
    if os.path.exists(PIPELINE_LOG):
        with open(PIPELINE_LOG) as f:
            usage = json.load(f)
    usage[pipeline_str] = usage.get(pipeline_str, 0) + 1
    with open(PIPELINE_LOG, "w") as f:
        json.dump(usage, f, indent=2)
    print(f"已记录: {pipeline_str} (共 {usage[pipeline_str]} 次)")


def show_graph(skills):
    """T14: 文字版 skill 依赖图"""
    print("## Skill 网络依赖图\n")
    for name, s in sorted(skills.items()):
        delegates = s.get("delegates_to", [])
        called_by = s.get("called_by", [])
        if delegates or called_by:
            print(f"/{name}")
            for d in delegates:
                print(f"  → /{d}")
            for c in called_by:
                print(f"  ← /{c}")
            print()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    skills = load_registry()

    if cmd == "search" and len(sys.argv) > 2:
        query = " ".join(sys.argv[2:])
        results = search(query, skills)
        if not results:
            print(f"没有匹配 '{query}' 的 skill")
        else:
            print(f"## 搜索结果: '{query}'\n")
            for score, name, s in results:
                print(f"/{name} — {s['description']}")
                if s.get("triggers"):
                    print(f"  触发词: {', '.join(s['triggers'][:3])}")
                print()

    elif cmd == "pipelines":
        show_pipelines(skills)

    elif cmd == "record" and len(sys.argv) > 2:
        record_pipeline(" ".join(sys.argv[2:]))

    elif cmd == "graph":
        show_graph(skills)

    else:
        print("Usage:")
        print("  registry-query.py search <关键词>")
        print("  registry-query.py pipelines")
        print("  registry-query.py record 'prd → l4'")
        print("  registry-query.py graph")
