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
echo "=== 4/5: SESSION_SCANNER 增量读取 —— 已于 2026-11-04 停用，不要打 ==="
echo "    回滚原因：它会让每次会话重启把整份对话历史重新上传一遍。"
echo "    实测（App 里每条会话行最新 150 条消息的时间跨度）："
echo "      10-21 补丁前 36026s · 10-22 补丁前 11521s · 10-23 打补丁当天 2s · 11-03 5s"
echo "    日志对得上：'Pre-marking 5345 existing entries as processed' 之后紧跟"
echo "    5345 次 'Sending new message'，预标记没拦住；扫描器还注册了两次。"
echo "    后果是 App 里每重启一次就多一条塞满完整历史的会话行，时间戳全是推送时刻。"
echo "    没有数据丢失，但同步量和 App 可用性都被毁了。"
echo "    上游 PR slopus/happy#1915 到 11-04 仍是 open，1.2.6 里没有；要重新启用，"
echo "    先解决预标记失效和重复注册，再用上面那个时间跨度口径验证。"
# python3 ~/bin/patch-happy-scanner-incremental.py   # 停用，见上

echo ""
echo "=== 5/5: 上报 Claude 模型列表到 session metadata（手机选择器用，上游 PR #1844）==="
python3 ~/bin/patch-happy-claude-model-list.py

echo ""
echo "✓ Client-side patches applied. Restart any running happy session for changes to take effect."
echo ""
echo "Note: server-side patches (e.g. disable-app-auto-prefetch) live in separate scripts and"
echo "      are applied automatically by ~/bin/happy-sync-deploy.sh during docker build."
echo "      They are NOT applied here because they require a server image rebuild."
