#!/bin/bash
# nightly-distill.sh — 夜间蒸馏器
# 读取今日对话 → 提取 playbook → 追加到 ~/.claude/commands/{data,troubleshoot,infra}.md
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

# 读取今日会话
echo ""
echo "📖 读取今日对话..."
DATA=$(python3 "$SCRIPT_DIR/distill-read.py" 2>/tmp/distill-stderr.log)
cat /tmp/distill-stderr.log

SESSION_COUNT=$(echo "$DATA" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['sessions']))")

if [ "$SESSION_COUNT" -eq 0 ]; then
  echo "今天没有对话记录，跳过蒸馏。"
  exit 0
fi

echo "找到 $SESSION_COUNT 个会话"

# 读取现有 playbook（从 data/troubleshoot/infra.md 的 AUTO-PLAYBOOKS 区块解析）
EXISTING_PLAYBOOKS=$(python3 - "$COMMANDS_DIR" << 'PY'
import sys, os, re
commands_dir = sys.argv[1]
out = []
for cat in ("data", "troubleshoot", "infra"):
    p = os.path.join(commands_dir, f"{cat}.md")
    if not os.path.exists(p):
        continue
    text = open(p).read()
    m = re.search(r'<!-- BEGIN AUTO-PLAYBOOKS -->(.*?)<!-- END AUTO-PLAYBOOKS -->', text, re.DOTALL)
    if not m:
        continue
    for entry in re.findall(r'^### ([a-z0-9-]+)\s*\n\*\*When:\*\*\s*(.+?)(?=\n\n)', m.group(1), re.DOTALL | re.MULTILINE):
        slug, when = entry
        out.append(f"- [{cat}] {slug}: {when.strip()[:120]}")
print("\n".join(out) if out else "(none)")
PY
)

# 构建 prompt
echo ""
echo "🧠 分析对话，提取 playbook 候选..."
TMPDATA=$(mktemp)
echo "$DATA" > "$TMPDATA"
TMPEXIST=$(mktemp)
printf '%s\n' "$EXISTING_PLAYBOOKS" > "$TMPEXIST"
FULL_PROMPT=$(python3 - "$TMPDATA" "$PROMPT_TEMPLATE" "$TMPEXIST" << 'PYTEMPLATE'
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
with open(sys.argv[2]) as f:
    template = f.read()
with open(sys.argv[3]) as f:
    existing = f.read().strip()
conversations = "\n\n".join(
    f"### Session: {s['project']} (category={s['category']}, {s['message_count']} messages)\n{s['text']}"
    for s in data['sessions']
)
print(template.replace("{EXISTING_PLAYBOOKS}", existing)
              .replace("{CONVERSATIONS}", conversations))
PYTEMPLATE
)
rm -f "$TMPDATA" "$TMPEXIST"

# 调用 Claude 提取 playbook
CANDIDATES=$(echo "$FULL_PROMPT" | claude --print 2>/tmp/distill-claude.err \
  | python3 -c "
import sys, json, re
text = sys.stdin.read()
match = re.search(r'\[.*\]', text, re.DOTALL)
if match:
    try:
        print(json.dumps(json.loads(match.group())))
    except:
        print('[]')
else:
    print('[]')
")

CANDIDATE_COUNT=$(echo "$CANDIDATES" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
echo "提取到 $CANDIDATE_COUNT 个 playbook 候选"

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo "今日没有值得提取的新 playbook（维护步骤仍会跑）。"
fi

# 追加 playbook 到对应 category 文件
if [ "$CANDIDATE_COUNT" -gt 0 ]; then
echo ""
echo "✍️  追加 playbook 到 category 文件..."
TMPCAND=$(mktemp)
echo "$CANDIDATES" > "$TMPCAND"
python3 - "$COMMANDS_DIR" "$TMPCAND" << 'PYTHON'
import sys, json, os, re

commands_dir = sys.argv[1]
with open(sys.argv[2]) as f:
    candidates = json.load(f)

VALID = {"data", "troubleshoot", "infra"}
BEGIN = "<!-- BEGIN AUTO-PLAYBOOKS -->"
END = "<!-- END AUTO-PLAYBOOKS -->"

def render_playbook(pb):
    when = "; ".join(pb.get("when", []))
    steps = "\n".join(f"{i+1}. {s}" for i, s in enumerate(pb.get("steps", [])))
    example = pb.get("example", "").strip()
    out = f"### {pb['slug']}\n**When:** {when}\n\n**Steps:**\n{steps}\n"
    if example:
        out += f"\n**Example:** {example}\n"
    return out

def parse_existing(block_text):
    # returns dict slug -> rendered entry text
    entries = {}
    # split on '### '
    parts = re.split(r'\n(?=### )', block_text.strip())
    for p in parts:
        p = p.strip()
        if not p.startswith("### "):
            continue
        m = re.match(r'### ([a-z0-9-]+)', p)
        if m:
            entries[m.group(1)] = p
    return entries

# Group candidates by category
by_cat = {}
for c in candidates:
    cat = c.get("category", "").strip()
    slug = c.get("slug", "").strip()
    if cat not in VALID or not slug:
        continue
    by_cat.setdefault(cat, []).append(c)

new_entries = []
updated_entries = []

for cat, pbs in by_cat.items():
    path = os.path.join(commands_dir, f"{cat}.md")
    if not os.path.exists(path):
        print(f"  跳过 {cat}: {path} 不存在")
        continue
    text = open(path).read()
    m = re.search(re.escape(BEGIN) + r'(.*?)' + re.escape(END), text, re.DOTALL)
    if not m:
        print(f"  跳过 {cat}: 没找到 AUTO-PLAYBOOKS 标记")
        continue
    existing = parse_existing(m.group(1))

    for pb in pbs:
        slug = pb["slug"]
        rendered = render_playbook(pb)
        if slug in existing:
            existing[slug] = rendered
            updated_entries.append(f"{cat}/{slug}")
            print(f"  更新: {cat}/{slug}")
        else:
            existing[slug] = rendered
            new_entries.append(f"{cat}/{slug}")
            print(f"  新增: {cat}/{slug}")

    # rebuild block in alphabetical order by slug for stability
    new_block = "\n\n".join(existing[k] for k in sorted(existing.keys()))
    new_text = text[:m.start(1)] + "\n" + new_block + "\n" + text[m.end(1):]
    with open(path, "w") as f:
        f.write(new_text)

print(f"__SUMMARY__:{json.dumps({'new': new_entries, 'updated': updated_entries})}")
PYTHON
rm -f "$TMPCAND"
fi  # end if CANDIDATE_COUNT > 0

# 梳理 playbook: 去重/合并/删除过窄条目
echo ""
python3 "$SCRIPT_DIR/distill-maintain.py"

# 更新 registry
echo ""
echo "📋 更新 skill registry..."
python3 "$SCRIPT_DIR/registry-init.py"

# 生成蒸馏报告
echo ""
echo "📝 生成报告..."
cat > "$REPORT_FILE" << REPORT
# 蒸馏报告 $(date +%Y-%m-%d)

## 概况
- 分析会话数: $SESSION_COUNT
- 提取候选数: $CANDIDATE_COUNT

## 追加的 Playbooks

$(echo "$CANDIDATES" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    print(f\"### /{c.get('category','?')} → {c.get('slug','?')}\")
    print(f\"触发词: {'; '.join(c.get('when', []))}\")
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
