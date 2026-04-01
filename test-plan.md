# Claude Workspace Setup — Full Test Run

## C. Error Handling (HIGH priority first)

- [ ] C-H1: setup-workspace.sh — 无 Homebrew 时报错退出 (mock: PATH中临时移除brew，测试 exit 1 和错误信息)
- [ ] C-H3: setup-workspace.sh — ~/.claude/hooks/ 目录无写权限 (chmod 444 ~/.claude/hooks, 验证报错信息)
- [ ] C-H4: setup-workspace.sh — ~/.claude/settings.json 损坏 (写入 `{invalid` 后重跑，验证 try/except 捕获并给出友好报错)
- [ ] C-H6: claude-session.sh — settings.json 损坏时 session 仍能创建 (写入 `{bad}` 到 vscode settings，运行脚本，验证 tmux session 存在)
- [ ] C-H8: claude-session.sh — tmux new-session 失败时 exit 1 (mock: tmux 不在PATH，验证错误输出和退出码)
- [ ] C-H13: loop.sh — /tmp 无写权限模拟 (chmod 555 /tmp/claude_loop_test，验证脚本处理)

## G. Environment (HIGH priority)

- [ ] G-EN1: claude-session.sh — 在 tmux 内运行时用 switch-client (在已有tmux session内执行，验证 TMUX env var 检测)
- [ ] G-EN4: 无 claude CLI 时的行为 (临时把 claude 从 PATH 移除，运行 claude-session，检查报错)
- [ ] G-EN8: loop.sh — /tmp 不可写时的处理

## H. Reliability (HIGH priority)

- [ ] H-R2: claude-session.sh — 写 settings.json 原子性验证 (在写入过程中检查原始文件未被截断)
- [ ] H-R3: setup-workspace.sh — 脚本中途被 SIGINT 中断后状态 (Ctrl+C 模拟，检查文件完整性)
- [ ] H-R4: loop.sh — 同一 PWD 并发触发两次 (并行运行两次 hook，验证 counter 最终值正确)
- [ ] H-R8: setup-workspace.sh — 磁盘空间不足模拟

## F. Integration (end-to-end)

- [ ] F-INT1: 完整工作流 create→loop×3→end (创建 test session，触发 loop 3次，end session，验证最终状态干净)
- [ ] F-INT8: VS Code running 时 settings.json 原子写 (并发读写验证无 corruption)
- [ ] F-INT9: 3个 session 并发各跑 loop (各自 counter 文件独立，不串扰)

## B. Edge Cases (MEDIUM)

- [ ] B-E3: session 名含单引号 (claude-session "User's Task"，验证 settings.json 合法 JSON)
- [ ] B-E4: session 名超长 300 字符 (验证无 buffer overflow，settings.json 合法)
- [ ] B-E5: tasks.md 含 Unicode (中文任务名，验证 JSON 序列化正确)
- [ ] B-E6: tasks.md 单条任务超 1000 字符
- [ ] B-E7: tasks.md CRLF 行尾 (Windows 格式，验证 grep 能找到 pending task)

## E. Security (HIGH)

- [ ] E-S1: SESSION_NAME 命令注入 (claude-session "test; echo INJECTED > /tmp/inject_test"，验证 /tmp/inject_test 不存在)
- [ ] E-S3: tasks.md 命令注入 (task 内容含 $(rm -rf /tmp/inject_test2)，验证未执行)
- [ ] E-S4: tasks.md JSON 注入 (task 含 `" },"malicious":1,"x":"` ，验证输出仍是合法 JSON)
- [ ] E-S6: end-session JSON 注入 (session 名含引号，验证 settings.json 合法)

## D. Idempotency (LOW — 验证多次运行安全)

- [ ] D-I1: setup-workspace.sh 连跑两次 (第二次所有步骤应全部 skip，无重复写入)
- [ ] D-I5: end-session 连跑两次 (第二次应输出 "Not found"，不报错)
- [ ] D-I8: claude-session 注册同一 session 两次 (settings.json 只有一条记录)
