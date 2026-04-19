# PRD: 自进化 Agent 系统 — 夜间蒸馏 + Skill 网络
# Done when: 三个 Phase 全部完成，每晚自动运行，router 能路由真实任务
# Quality: production
# Feedback loops: 手动测试每个脚本输出；skill 文件语法检查

## Phase 1：夜间蒸馏器（读对话 → 生成 skill）

- [ ] T01: 设计蒸馏 prompt — 明确 Claude 要从对话中提取什么：触发条件、步骤、可复用性判断标准
- [ ] T02: 构建 session 读取器 — 找到今天修改的 JSONL 文件，提取 user/assistant 消息，过滤掉工具噪音
- [ ] T03: 构建去重检查器 — 读取现有 ~/.claude/commands/*.md，避免生成重复或冲突的 skill
- [ ] T04: 构建 skill 提取器 — 调用 Claude 分析对话，输出 skill 候选（名称/触发词/步骤/关联 skill）
- [ ] T05: 构建 skill 写入器 — 将提取结果写成标准 .md 格式到 ~/.claude/commands/
- [ ] T06: 构建蒸馏报告生成器 — 每晚输出：学到了什么、新增了哪些 skill、更新了哪些
- [ ] T07: 组装 nightly-distill.sh — 串联以上所有步骤，加错误处理
- [ ] T08: 用真实今日对话测试，验证输出 skill 质量

## Phase 2：Registry 系统（skill 网络清单）

- [ ] T09: 设计 _registry.md schema — 每个 skill 包含：name/triggers/capabilities/delegates_to/called_by/last_updated
- [ ] T10: 构建 registry 初始化器 — 扫描现有 ~/.claude/commands/*.md，自动填充 registry
- [ ] T11: 将 registry 更新集成进蒸馏器 — 每次写入新 skill 后自动更新 _registry.md
- [ ] T12: 构建 registry 查询工具 — 按触发词/能力搜索 skill（供 router 使用）
- [ ] T13: 构建 skill 关系追踪 — 记录哪些 skill 经常连续使用，形成 pipeline 候选
- [ ] T14: 构建网络可视化 — 输出文字版 skill 依赖图（谁调用谁）
- [ ] T15: 用现有 skill 集测试 registry，验证关系正确

## Phase 3：Router（meta-agent，任务 → pipeline）

- [ ] T16: 设计 router 逻辑 — 给定任务描述，如何匹配 registry，如何决定单个 skill 还是 pipeline
- [ ] T17: 构建 _router.md skill 文件 — 读 registry，分析任务，输出推荐 skill 或 pipeline
- [ ] T18: 构建 /dispatch skill — 用户入口：输入任务描述，router 返回行动方案
- [ ] T19: 加入 pipeline 记录 — 当一个 pipeline 被用户确认执行，记录回 registry（正向反馈）
- [ ] T20: 测试 router — 用 5 个真实任务场景验证路由准确性
- [ ] T21: 全链路集成测试 — 蒸馏 → registry 更新 → router 路由新 skill，端到端跑通

## 收尾

- [ ] T22: 更新 setup-workspace.sh — 安装 nightly-distill.sh，可选配置 cron
- [ ] T23: 更新 README — 记录整个系统的使用方式
- [ ] T99: 全系统验收 — 完整跑一个夜晚，早上检查产出质量
