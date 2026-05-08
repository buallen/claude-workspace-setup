# PRD: happy-session CLI
# Done when: 所有7个命令可运行，类型零错误，测试覆盖 >= 70%，COMPLETED.md 写入
# Quality: production
# Feedback loops: tsc --noEmit && vitest run --coverage && eslint src/

- [ ] T01: 初始化 TypeScript 项目 — npm init, tsconfig strict, vitest, eslint, prettier, commander, package.json binary 配置 happy-session
- [ ] T02: 定义 JSONL 类型系统 — 为所有消息类型建立 TypeScript 接口 (UserMessage, AssistantMessage, SystemMessage 等)
- [ ] T03: 实现核心 JSONL 解析器 — 逐行读取，跳过格式错误行，类型安全返回
- [ ] T04: 实现文件系统发现层 — 扫描 ~/.claude/projects/，URL 解码目录名，列举 .jsonl 文件
- [ ] T05: 创建测试 fixtures — 从真实 session 文件复制样本数据到 src/__fixtures__/
- [ ] T06: 实现 `happy-session list` — 展示项目列表、session 数量、最近日期、slug 名称
- [ ] T07: 实现 `happy-session search <query>` — 全文搜索所有 session，输出项目/日期/内容片段
- [ ] T08: 实现 `happy-session summary <session-id>` — 展示 slug、时间戳、消息数、工作目录、前3条用户消息摘要
- [ ] T09: 实现 `happy-session export <session-id>` — 输出 Markdown 格式，支持 --output <file>
- [ ] T10: 实现 `happy-session stats` — 总 session 数、每日/每周活跃度、最活跃项目、平均消息数
- [ ] T11: 实现 `happy-session rename <session-id>` — 改 session title + tmux window/tab 名（参数 --title <name> [--tab <tab>]，调 happy change_title API + tmux rename-window）
- [ ] T12: 实现 `happy-session delete <session-id>` — 从 happy unregister + kill tmux session/window；**保留 ~/.claude/projects/ 下 JSONL 文件不动**（Claude 会话历史是不可碰的存档）。带 --dry-run 和 --force 双保险
- [ ] T13: Parser 单元测试 — 覆盖正常解析、格式错误行、空文件场景
- [ ] T14: 文件系统发现层单元测试 — 覆盖目录解码、多项目场景
- [ ] T15: 每个命令的集成测试 — 使用 fixtures 数据跑所有7个命令（rename/delete 用临时 fixture 目录，不碰真实 session）
- [ ] T16: 覆盖率验证 — vitest --coverage，确认 >= 70%，不足则补测试
- [ ] T17: ESLint + Prettier 清零 — 零错误，格式统一
- [ ] T18: 验证 CLI 可用 — npm link 后测试 happy-session list 真实运行
- [ ] T19: 写入 COMPLETED.md
- [ ] T99: 运行全部 feedback loops — tsc + vitest + eslint 全部通过，无 regression
