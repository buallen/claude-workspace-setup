#!/bin/bash
# nightly-distill.sh — 夜间蒸馏器
# 读取今日对话 → 提取 skill 候选 → 写入 ~/.claude/commands/
# Usage: bash nightly-distill.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMANDS_DIR="$HOME/.claude/commands"
REPORT_FILE="$SCRIPT_DIR/distill-report-$(date +%Y-%m-%d).md"
PROMPT_TEMPLATE="$SCRIPT_DIR/distill-prompt.md"

export PATH="$HOME/.nvm/versions/node/v22.22.0/bin:/usr/local/bin:/usr/bin:/bin"

echo "========================================"
echo "  夜间蒸馏器"
echo "  $(date '+%Y-%m-%d %H:%M')"
echo "========================================"

# T02+T03: 读取今日会话 + 现有 skills
echo ""
echo "📖 读取今日对话..."
DATA=$(python3 "$SCRIPT_DIR/distill-read.py" 2>/tmp/distill-stderr.log)
cat /tmp/distill-stderr.log

SESSION_COUNT=$(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['sessions']))")
SKILL_COUNT=$(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['existing_skills']))")

if [ "$SESSION_COUNT" -eq 0 ]; then
  echo "今天没有对话记录，跳过蒸馏。"
  exit 0
fi

echo "找到 $SESSION_COUNT 个会话，$SKILL_COUNT 个现有 skill"

# T04: 构建蒸馏 prompt
echo ""
echo "🧠 分析对话，提取 skill 候选..."
EXISTING_SKILLS=$(echo "$DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
skills = d['existing_skills']
print('\n'.join(f\"- {s['name']}: {s['description']}\" for s in skills))
")

CONVERSATIONS=$(echo "$DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
parts = []
for s in d['sessions']:
    parts.append(f\"### Session: {s['project']} ({s['message_count']} messages)\n{s['text']}\")
print('\n\n'.join(parts))
")

PROMPT=$(cat "$PROMPT_TEMPLATE" \
  | sed "s|{EXISTING_SKILLS}|$EXISTING_SKILLS|g")
FULL_PROMPT="$PROMPT

## Conversations to analyze

$CONVERSATIONS"

# T04: 调用 Claude 提取 skill
CANDIDATES=$(echo "$FULL_PROMPT" | claude --print --no-markdown 2>/dev/null \
  | python3 -c "
import sys, json, re
text = sys.stdin.read()
# 提取 JSON array
match = re.search(r'\[.*\]', text, re.DOTALL)
if match:
    try:
        candidates = json.loads(match.group())
        print(json.dumps(candidates))
    except:
        print('[]')
else:
    print('[]')
")

CANDIDATE_COUNT=$(echo "$CANDIDATES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
echo "提取到 $CANDIDATE_COUNT 个 skill 候选"

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo "今日没有值得提取的新 skill。"
  echo "# 蒸馏报告 $(date '+%Y-%m-%d')" > "$REPORT_FILE"
  echo "今日没有提取到新 skill。" >> "$REPORT_FILE"
  exit 0
fi

# T05: 写入 skill 文件
echo ""
echo "✍️  写入 skill 文件..."
NEW_SKILLS=()
UPDATED_SKILLS=()

echo "$CANDIDATES" | python3 - "$COMMANDS_DIR" << 'PYTHON'
import sys, json, os

commands_dir = sys.argv[1]
candidates = json.load(sys.stdin)
new_skills = []
updated_skills = []

for c in candidates:
    name = c.get("name", "").strip()
    if not name:
        continue

    description = c.get("description", "")
    triggers = c.get("triggers", [])
    steps = c.get("steps", [])
    delegates_to = c.get("delegates_to", [])
    example = c.get("example_usage", "")

    content = f"""---
description: {description}
---

# {name.replace('-', ' ').title()}

## When to use
{chr(10).join(f'- {t}' for t in triggers)}

## Steps

{chr(10).join(f'{i+1}. {s}' for i, s in enumerate(steps))}
"""
    if delegates_to:
        content += f"\n## Related skills\n{chr(10).join(f'- /{s}' for s in delegates_to)}\n"
    if example:
        content += f"\n## Example\n{example}\n"

    filepath = os.path.join(commands_dir, f"{name}.md")
    exists = os.path.exists(filepath)

    with open(filepath, 'w') as f:
        f.write(content)

    if exists:
        updated_skills.append(name)
        print(f"  更新: {name}")
    else:
        new_skills.append(name)
        print(f"  新增: {name}")

print(f"__SUMMARY__:{json.dumps({'new': new_skills, 'updated': updated_skills})}")
PYTHON

# T06: 生成蒸馏报告
echo ""
echo "📝 生成报告..."
cat > "$REPORT_FILE" << REPORT
# 蒸馏报告 $(date '+%Y-%m-%d')

## 概况
- 分析会话数: $SESSION_COUNT
- 现有 skill 数: $SKILL_COUNT
- 提取候选数: $CANDIDATE_COUNT

## 新增/更新的 Skills

$(echo "$CANDIDATES" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    print(f\"### /{c['name']}\")
    print(f\"{c['description']}\")
    print(f\"触发词: {', '.join(c.get('triggers', []))}\")
    print()
")

## 生成时间
$(date)
REPORT

echo ""
echo "========================================"
echo "  蒸馏完成！"
echo "  报告: $REPORT_FILE"
echo "========================================"
