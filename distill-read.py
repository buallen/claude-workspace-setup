#!/usr/bin/env python3
"""
T02: Session reader — 读取今日 JSONL，提取 user/assistant 对话
T03: Dedup checker — 读取现有 skill 列表供 prompt 使用
"""
import os, json, glob, sys
from datetime import datetime, timezone, date

PROJECTS_DIR = os.path.expanduser("~/.claude/projects")
COMMANDS_DIR = os.path.expanduser("~/.claude/commands")
MAX_CHARS_PER_SESSION = 8000  # 避免 prompt 过长
MAX_SESSIONS = 10


def read_today_sessions():
    today = date.today().isoformat()
    sessions = []

    for jsonl_file in sorted(glob.glob(f"{PROJECTS_DIR}/**/*.jsonl", recursive=True),
                              key=os.path.getmtime, reverse=True):
        # 只取今天修改过的文件
        mtime = datetime.fromtimestamp(os.path.getmtime(jsonl_file)).date().isoformat()
        if mtime != today:
            continue

        messages = []
        try:
            with open(jsonl_file, 'r', errors='ignore') as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                        if obj.get("type") not in ("user", "assistant"):
                            continue
                        # 提取文本内容
                        content = obj.get("message", {}).get("content", "")
                        if isinstance(content, list):
                            parts = []
                            for c in content:
                                if isinstance(c, dict) and c.get("type") == "text":
                                    parts.append(c.get("text", ""))
                            content = "\n".join(parts)
                        if not isinstance(content, str) or not content.strip():
                            continue
                        # 过滤纯工具噪音
                        if content.strip().startswith("<") and "tool" in content.lower():
                            continue
                        role = obj.get("type")  # "user" or "assistant"
                        ts = obj.get("timestamp", "")[:16]
                        messages.append(f"[{ts}] {role.upper()}: {content[:500]}")
                    except Exception:
                        continue
        except Exception:
            continue

        if not messages:
            continue

        project = os.path.basename(os.path.dirname(jsonl_file))
        project_decoded = project.replace("-Users-kan-lu-", "~/").replace("-", "/")
        session_id = os.path.basename(jsonl_file).replace(".jsonl", "")
        session_text = "\n".join(messages)[:MAX_CHARS_PER_SESSION]

        sessions.append({
            "project": project_decoded,
            "session_id": session_id,
            "message_count": len(messages),
            "text": session_text
        })

        if len(sessions) >= MAX_SESSIONS:
            break

    return sessions


def read_existing_skills():
    skills = []
    for md_file in glob.glob(f"{COMMANDS_DIR}/*.md"):
        name = os.path.basename(md_file).replace(".md", "")
        if name.startswith("_"):
            continue
        try:
            with open(md_file, 'r') as f:
                content = f.read()
            # 提取 description
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

    print(f"今日会话数: {len(sessions)}", file=sys.stderr)
    print(f"现有 skill 数: {len(skills)}", file=sys.stderr)

    # 输出供 distiller 使用的 JSON
    output = {
        "sessions": sessions,
        "existing_skills": skills
    }
    print(json.dumps(output, ensure_ascii=False, indent=2))
