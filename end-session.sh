#!/bin/bash
# 用法: end-session "任务名"
# 结束 tmux session，并从 VS Code Restore Terminals 中移除

SESSION_NAME="$1"
VSCODE_SETTINGS="$HOME/Library/Application Support/Code/User/settings.json"

if [ -z "$SESSION_NAME" ]; then
  echo "用法: end-session <任务名>"
  echo ""
  echo "当前运行中的 session:"
  tmux list-sessions 2>/dev/null | awk -F: '{print "  " $1}' || echo "  (无)"
  exit 1
fi

# 结束 tmux session
tmux kill-session -t "$SESSION_NAME" 2>/dev/null && echo "已结束 session: $SESSION_NAME"

# 从 VS Code settings.json 中移除
python3 - "$SESSION_NAME" "$VSCODE_SETTINGS" << 'PYTHON'
import json, sys

session_name = sys.argv[1]
settings_path = sys.argv[2]

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except:
    sys.exit(0)

terminals = settings.get("restoreTerminals.terminals", [])
settings["restoreTerminals.terminals"] = [
    t for t in terminals
    if not any(st.get("name") == session_name for st in t.get("splitTerminals", []))
]

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
PYTHON

echo "已从 VS Code 恢复列表中移除: $SESSION_NAME"
