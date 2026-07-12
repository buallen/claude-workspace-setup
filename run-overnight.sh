#!/bin/bash
# run-overnight.sh — Ralph loop for claude-workspace-setup
# 今晚只跑 Phase 1（T01-T08）
#
# 启动方式：
#   1. happy-session "Distiller"        ← 创建独立 session（VS Code 集成 + 云同步）
#   2. cd ~/Documents/GitHub/claude-workspace-setup
#   3. caffeinate -i ./run-overnight.sh ← 防止 Mac 睡眠，盖子开着跑

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAX_ITERATIONS=30
ITERATION=0
WAIT_ON_FAIL=600  # 额度耗尽时等 10 分钟

cd "$PROJECT_DIR"

echo "========================================"
echo "  自进化 Agent 系统 — Phase 1 构建"
echo "  项目: $PROJECT_DIR"
echo "  最大迭代: $MAX_ITERATIONS"
echo "  开始时间: $(date)"
echo "========================================"

while [ $ITERATION -lt $MAX_ITERATIONS ]; do
  ITERATION=$((ITERATION + 1))
  echo ""
  echo "--- 第 $ITERATION 轮 / $MAX_ITERATIONS — $(date) ---"

  # 检查 Phase 1 是否全部完成
  PENDING=$(grep -c "^- \[ \] T0" tasks.md 2>/dev/null || echo 0)
  if [ "$PENDING" -eq 0 ]; then
    echo "Phase 1 所有任务完成！"
    grep "^- \[x\]" tasks.md | head -20
    exit 0
  fi

  echo "剩余 Phase 1 任务: $PENDING 个"

  # 运行 Claude
  claude --dangerously-skip-permissions \
    "你正在构建一个自进化 Agent 系统的 Phase 1：夜间蒸馏器。
读取 tasks.md，找到下一个未完成的 T0x 任务（Phase 1，T01-T08）。
按照 CLAUDE.md 的说明完成它。
完成后 git commit，把任务标记为 [x]，然后停止。
不要一次做多个任务。"

  EXIT_CODE=$?

  if [ $EXIT_CODE -ne 0 ]; then
    echo "Claude 异常退出（可能额度耗尽），等待 ${WAIT_ON_FAIL}s..."
    sleep $WAIT_ON_FAIL
  else
    sleep 5
  fi
done

echo "达到最大迭代数，检查 tasks.md 查看进度。"
exit 1
