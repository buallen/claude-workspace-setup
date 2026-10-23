#!/usr/bin/env python3
"""
Patch happy 的 dist/index-*.mjs，让所有 user message 在推送到 server 前
剥离掉 `<command-message>...</command-message><command-name>...</command-name><command-args>...</command-args>`
这种 slash command XML wrapper，只保留 `${command-name} ${args}` 形式。

效果：手机/桌面 client 不再看到 Claude Code 内部 slash command 的 XML 包装，
只看到用户实际意图（"/fix-session ..." 或 "/go 部署 ..."）。

Re-run after every `happy update`.
"""
import glob
import os
import sys

# 注入到 dist 顶部的辅助函数。const + arrow function 在 ESM 顶层声明，全局可用。
HELPER = '''const __stripCommandWrapper = (m) => {
  try {
    if (!m || m.type !== "user" || !m.message) return m;
    const c = m.message.content;
    if (typeof c !== "string") return m;
    const re = /^<command-message>([^<]*)<\\/command-message>\\s*<command-name>([^<]*)<\\/command-name>(?:\\s*<command-args>([\\s\\S]*?)<\\/command-args>)?/;
    const match = c.match(re);
    if (!match) return m;
    const name = match[2].trim();
    const args = (match[3] || "").trim();
    const clean = args ? `${name} ${args}` : name;
    return { ...m, message: { ...m.message, content: clean } };
  } catch { return m; }
};

'''

# 两个 push 入口的 pattern → 改写后版本
PATCHES = [
    # 1) claudeLocalLauncher 的 scanner.onMessage（local 模式）
    (
        '      if (message.type !== "summary") {\n'
        '        session.client.sendClaudeSessionMessage(message);\n'
        '      }',
        '      if (message.type !== "summary") {\n'
        '        session.client.sendClaudeSessionMessage(__stripCommandWrapper(message));\n'
        '      }',
    ),
    # 2) remoteScanner.onMessage（remote 模式）
    (
        '      if (consumeAppPrompt(content)) return;\n'
        '      session.sendClaudeSessionMessage(raw);',
        '      if (consumeAppPrompt(content)) return;\n'
        '      session.sendClaudeSessionMessage(__stripCommandWrapper(raw));',
    ),
]

HELPER_MARKER = "const __stripCommandWrapper"

targets = (
    glob.glob(os.path.expanduser("~/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.cjs"))
    + glob.glob(os.path.expanduser("~/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.mjs"))
)
targets = [
    f for f in targets
    if not (f.endswith("index.cjs") or f.endswith("index.mjs") or ".bak" in f)
]

if not targets:
    print("ERROR: no happy dist file found")
    sys.exit(1)

for path in targets:
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    if HELPER_MARKER in src:
        print(f"SKIP (already patched): {path}")
        continue

    patched_count = 0
    new_src = src
    for old, new in PATCHES:
        if old in new_src:
            new_src = new_src.replace(old, new, 1)
            patched_count += 1

    if patched_count == 0:
        print(f"SKIP (no push pattern found): {path}")
        continue

    # Inject helper near the top of the file (after any 'use strict' / shebang / first imports)
    # ESM-safe: insert after the first non-import line or right at top
    new_src = HELPER + new_src

    with open(path, "w", encoding="utf-8") as f:
        f.write(new_src)
    print(f"PATCHED ({patched_count}/{len(PATCHES)} hooks): {path}")

print("Done. Re-run after every `happy update`.")
