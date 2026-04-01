#!/bin/bash
# 用法: claude-session "任务名"
# 创建/恢复 tmux session，并自动注册到 VS Code Restore Terminals

SESSION_NAME="$1"
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"

if [ -z "$SESSION_NAME" ]; then
  echo "用法: claude-session <任务名>"
  echo ""
  echo "当前运行中的 session:"
  tmux list-sessions 2>/dev/null | awk -F: '{print "  " $1}' || echo "  (无)"
  exit 1
fi

# 设置 VS Code 终端标签页标题
echo -ne "\033]0;${SESSION_NAME}\007"

# 创建 tmux session（如果不存在），并启动 Claude
if ! tmux has-session -s "$SESSION_NAME" 2>/dev/null; then
  tmux new-session -d -s "$SESSION_NAME" -c /Users/kan.lu/Documents/GitHub
  tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions" Enter
  echo "新建 session: $SESSION_NAME"
else
  echo "恢复 session: $SESSION_NAME"
fi

# 动态注册到 VS Code settings.json
python3 - "$SESSION_NAME" "$VSCODE_SETTINGS" << 'PYTHON'
import json, sys

session_name = sys.argv[1]
settings_path = sys.argv[2]

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except:
    settings = {}

terminals = settings.get("restoreTerminals.terminals", [])

# 检查是否已注册
already_registered = any(
    st.get("name") == session_name
    for t in terminals
    for st in t.get("splitTerminals", [])
)

if not already_registered:
    terminals.append({
        "splitTerminals": [
            {"name": session_name, "commands": [f"claude-session '{session_name}'"]}
        ]
    })
    settings["restoreTerminals.terminals"] = terminals
    with open(settings_path, 'w') as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
PYTHON

# 进入 tmux session
tmux attach -t "$SESSION_NAME"
