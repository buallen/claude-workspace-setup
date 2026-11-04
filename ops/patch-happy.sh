#!/bin/bash
# 一键应用所有 happy CLI dist patch。
# 每次 `npm install -g happy@latest` / `happy update` 之后必须跑一次。
#
# 这些 patch 都改 dist/index-*.mjs（happy 真实加载的 ESM 主入口），
# 重启 happy session 后生效。

set -u

echo "=== 1/5: PermissionHandler 跨 local/remote 切换保留模式 + BASE_SYSTEM_PROMPT 中文规则 ==="
python3 ~/bin/patch-happy-permission-mode.py

echo ""
echo "=== 2/5: Remote→Local 切换时终端重置（消除花屏）==="
python3 ~/bin/patch-happy-terminal-reset.py

echo ""
echo "=== 3/5: 剥离 slash command XML wrapper（client 不再看到 <command-*> 包装）==="
python3 ~/bin/patch-happy-strip-command-wrapper.py

echo ""
echo "=== 4/5: SESSION_SCANNER 增量读取 + 冷启动行数上限（上游 PR #1915 合并发版前需要）==="
# 2026-11-04：这一步曾因「每次重启把整份 transcript 重推进一条新建的 App 会话行」
# 停用过半天（实测 5345 条 / 5 秒，手机从最早一条开始渲染会卡住）。现在补丁自带
# 冷读上限 HAPPY_SCAN_COLD_LIMIT（默认 300 行 ≈ 100 条消息），从源头封顶，所以
# 重新启用。改上限不用重打补丁，设环境变量再重启会话即可。
python3 ~/bin/patch-happy-scanner-incremental.py

echo ""
echo "=== 5/5: 上报 Claude 模型列表到 session metadata（手机选择器用，上游 PR #1844）==="
python3 ~/bin/patch-happy-claude-model-list.py

echo ""
echo "✓ Client-side patches applied. Restart any running happy session for changes to take effect."
echo ""
echo "Note: server-side patches (e.g. disable-app-auto-prefetch) live in separate scripts and"
echo "      are applied automatically by ~/bin/happy-sync-deploy.sh during docker build."
echo "      They are NOT applied here because they require a server image rebuild."
