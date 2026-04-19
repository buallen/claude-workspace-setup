# claude-workspace-setup

Claude Code 工作区持久化 + 自进化 Agent 系统。

## 项目结构

| 文件 | 用途 |
|------|------|
| `claude-session.sh` | 创建/恢复命名 tmux 会话（已安装到 ~/.claude/） |
| `end-session.sh` | 结束会话并清理 VS Code 恢复列表 |
| `loop.sh` | L4 Stop Hook，驱动 tasks.md 任务循环 |
| `setup-workspace.sh` | 一键安装脚本 |
| `nightly-distill.sh` | 【待构建】夜间蒸馏器 |
| `tasks.md` | 当前任务列表（Ralph loop 驱动） |

## 当前任务：自进化 Agent 系统

三个 Phase，见 tasks.md：
- **Phase 1**：夜间蒸馏器 — 读取今日对话 → 提取 skill → 写入 ~/.claude/commands/
- **Phase 2**：Registry 系统 — skill 网络清单，记录依赖和 pipeline 关系
- **Phase 3**：Router — meta-agent，给定任务描述自动路由到合适的 skill/pipeline

## 关键路径

- 今日 JSONL 会话：`~/.claude/projects/` 下今天修改的 `.jsonl` 文件
- Skill 文件目录：`~/.claude/commands/*.md`
- Registry 文件：`~/.claude/commands/_registry.md`（待创建）
- 蒸馏脚本：`~/Documents/GitHub/claude-workspace-setup/nightly-distill.sh`（待创建）

## Skill 文件格式

现有 skill 示例（~/.claude/commands/prd.md）：
```markdown
---
description: Generate a tasks.md-compatible PRD...
---
# PRD Generator
...步骤说明...
```

新 skill 必须遵循相同格式，description 要精确（用于触发判断）。

## Registry Schema（Phase 2 目标格式）

```markdown
## skill-name
- **description**: 一句话说明
- **triggers**: ["关键词1", "关键词2"]
- **capabilities**: ["能做什么"]
- **delegates_to**: [other-skill]
- **called_by**: [router, other-skill]
- **last_updated**: 2026-04-19
- **source_session**: <session-id>
```

## 工作方式

1. 读 tasks.md，找下一个未完成任务（`- [ ]`）
2. 实现它，测试输出
3. 用 git commit 记录
4. 标记为 `- [x]`，进入下一个任务
5. 所有任务完成后写入 COMPLETED.md

## 质量标准

- 所有脚本加 `set -e`（遇错即停）
- 每个脚本有 usage 说明
- 生成的 skill 文件必须可被 Claude Code 正确读取
- 不破坏现有 claude-session / end-session / loop 功能
