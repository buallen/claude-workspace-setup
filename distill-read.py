#!/usr/bin/env python3
"""
Session reader — 读取今日 JSONL，只保留三个 category 的对话
Categories: data, troubleshoot, infra
"""
import os, json, glob, sys, re
from datetime import datetime, date

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
COMMANDS_DIR = os.path.expanduser("~/.claude/commands")
MAX_CHARS_PER_SESSION = 8000
MAX_SESSIONS_PER_CATEGORY = 5

# category 判断规则：从 cwd 路径 + 对话内容关键词推断
CATEGORY_RULES = {
    "data": {
        "cwd_keywords": ["gcp", "bigquery", "bq", "data", "analytics", "spanner", "pubsub", "dataflow"],
        "content_keywords": ["bigquery", "bq.", "select ", "from `", "data pipeline", "dataset", "table schema",
                             "spanner", "pub/sub", "gcs", "cloud storage", "sql query"],
    },
    "troubleshoot": {
        "cwd_keywords": ["troubleshoot", "incident", "oncall", "debug"],
        "content_keywords": ["error", "exception", "incident", "alert", "rca", "root cause", "500",
                             "timeout", "latency", "kibana", "logs", "stack trace", "bug", "crash",
                             "production issue", "故障", "排查", "报错"],
    },
    "infra": {
        "cwd_keywords": ["infra", "terraform", "k8s", "kubernetes", "gke", "helm", "deploy"],
        "content_keywords": ["terraform", "kubernetes", "kubectl", "deployment", "pod", "service mesh",
                             "iam", "permission", "firewall", "vpc", "cluster", "node pool",
                             "helm chart", "docker", "container"],
    },
}


def detect_category(cwd: str, content_sample: str) -> str | None:
    """从 cwd 路径和对话内容推断 category，不匹配返回 None"""
    cwd_lower = cwd.lower()
    content_lower = content_sample.lower()

    scores = {}
    for cat, rules in CATEGORY_RULES.items():
        score = 0
        for kw in rules["cwd_keywords"]:
            if kw in cwd_lower:
                score += 3  # cwd 命中权重高
        for kw in rules["content_keywords"]:
            if kw in content_lower:
                score += 1
        if score > 0:
            scores[cat] = score

    if not scores:
        return None
    return max(scores, key=scores.get)


def read_today_sessions():
    today = date.today().isoformat()
    sessions_by_category = {"data": [], "troubleshoot": [], "infra": []}

    for jsonl_file in sorted(glob.glob(f"{PROJECTS_DIR}/**/*.jsonl", recursive=True),
                              key=os.path.getmtime, reverse=True):
        mtime = datetime.fromtimestamp(os.path.getmtime(jsonl_file)).date().isoformat()
        if mtime != today:
            continue

        messages = []
        cwds = []
        try:
            with open(jsonl_file, 'r', errors='ignore') as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                        if obj.get("cwd"):
                            cwds.append(obj["cwd"])
                        if obj.get("type") not in ("user", "assistant"):
                            continue
                        content = obj.get("message", {}).get("content", "")
                        if isinstance(content, list):
                            parts = [c.get("text", "") for c in content
                                     if isinstance(c, dict) and c.get("type") == "text"]
                            content = "\n".join(parts)
                        if not isinstance(content, str) or not content.strip():
                            continue
                        if content.strip().startswith("<") and "tool" in content.lower():
                            continue
                        role = obj.get("type")
                        ts = obj.get("timestamp", "")[:16]
                        messages.append(f"[{ts}] {role.upper()}: {content[:500]}")
                    except Exception:
                        continue
        except Exception:
            continue

        if not messages:
            continue

        # 用最常见的 cwd 代表这个 session
        cwd = max(set(cwds), key=cwds.count) if cwds else ""
        content_sample = " ".join(m for m in messages[:20])
        category = detect_category(cwd, content_sample)

        if category is None:
            continue  # 不属于三个 category，跳过

        cat_sessions = sessions_by_category[category]
        if len(cat_sessions) >= MAX_SESSIONS_PER_CATEGORY:
            continue

        project = os.path.basename(os.path.dirname(jsonl_file))
        session_id = os.path.basename(jsonl_file).replace(".jsonl", "")

        cat_sessions.append({
            "project": project,
            "session_id": session_id,
            "category": category,
            "cwd": cwd,
            "message_count": len(messages),
            "text": "\n".join(messages)[:MAX_CHARS_PER_SESSION],
        })

    # 展平，保留 category 标签
    all_sessions = []
    for cat, sessions in sessions_by_category.items():
        all_sessions.extend(sessions)

    return all_sessions


def read_existing_skills():
    skills = []
    for md_file in glob.glob(f"{COMMANDS_DIR}/*.md"):
        name = os.path.basename(md_file).replace(".md", "")
        if name.startswith("_"):
            continue
        try:
            with open(md_file, 'r') as f:
                content = f.read()
            desc = ""
            for line in content.split("\n"):
                if line.startswith("description:"):
                    desc = line.replace("description:", "").strip()
                    break
            skills.append({"name": name, "description": desc})
        except Exception:
            pass
    return skills


if __name__ == "__main__":
    sessions = read_today_sessions()
    skills = read_existing_skills()

    by_cat = {}
    for s in sessions:
        by_cat.setdefault(s["category"], []).append(s)

    print(f"今日相关会话: {len(sessions)} 个", file=sys.stderr)
    for cat, ss in by_cat.items():
        print(f"  [{cat}] {len(ss)} 个会话", file=sys.stderr)
    print(f"现有 skill: {len(skills)} 个", file=sys.stderr)

    print(json.dumps({"sessions": sessions, "existing_skills": skills}, ensure_ascii=False, indent=2))
