#!/bin/bash
# 一键应用所有 happy CLI dist patch。
# 每次 `npm install -g happy@latest` / `happy update` 之后必须跑一次。
#
# 这些 patch 都改 dist/index-*.mjs（happy 真实加载的 ESM 主入口），
# 重启 happy session 后生效。

set -u

echo "=== 1/3: PermissionHandler 跨 local/remote 切换保留模式 + BASE_SYSTEM_PROMPT 中文规则 ==="
python3 ~/bin/patch-happy-permission-mode.py

echo ""
echo "=== 2/3: Remote→Local 切换时终端重置（消除花屏）==="
python3 ~/bin/patch-happy-terminal-reset.py

echo ""
echo "=== 3/3: 剥离 slash command XML wrapper（client 不再看到 <command-*> 包装）==="
python3 ~/bin/patch-happy-strip-command-wrapper.py

echo ""
echo "=== 4/4: SESSION_SCANNER 增量读取（上游 PR #1915 合并发版前需要）==="
python3 ~/bin/patch-happy-scanner-incremental.py

echo ""
echo "✓ Client-side patches applied. Restart any running happy session for changes to take effect."
echo ""
echo "Note: server-side patches (e.g. disable-app-auto-prefetch) live in separate scripts and"
echo "      are applied automatically by ~/bin/happy-sync-deploy.sh during docker build."
echo "      They are NOT applied here because they require a server image rebuild."
