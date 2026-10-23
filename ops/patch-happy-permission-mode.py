#!/usr/bin/env python3
"""
Patch happy's compiled dist to preserve permission mode across local/remote switches.
Re-run after every `happy update`.

Fix: https://github.com/slopus/happy/pull/1337
"""
import glob
import sys
import re

targets = (
    glob.glob("/Users/kan.lu/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.cjs")
    + glob.glob("/Users/kan.lu/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.mjs")
)
# Exclude backup files
targets = [t for t in targets if not (t.endswith(".bak") or ".bak" in t)]

if not targets:
    print("ERROR: happy dist file not found")
    sys.exit(1)

for path in targets:
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()

    original = src

    # Patch 1: PermissionHandler class fields + constructor
    src = src.replace(
        '  permissionMode = "default";\n'
        '  onPermissionRequestCallback;\n'
        '  /** Callback to change permission mode on the active query (set by claudeRemote) */\n'
        '  setPermissionModeCallback;\n'
        '  constructor(session) {\n'
        '    this.session = session;\n'
        '    this.setupClientHandler();\n'
        '  }',
        '  permissionMode = "default";\n'
        '  initialPermissionMode = "default";\n'
        '  onPermissionRequestCallback;\n'
        '  /** Callback to change permission mode on the active query (set by claudeRemote) */\n'
        '  setPermissionModeCallback;\n'
        '  constructor(session, initialPermissionMode = "default") {\n'
        '    this.session = session;\n'
        '    this.permissionMode = initialPermissionMode;\n'
        '    this.initialPermissionMode = initialPermissionMode;\n'
        '    this.setupClientHandler();\n'
        '  }',
    )

    # Patch 2: reset() method
    src = src.replace(
        '    this.responses.clear();\n'
        '    this.allowedTools.clear();\n'
        '    this.allowedBashLiterals.clear();\n'
        '    this.allowedBashPrefixes.clear();\n'
        '    this.permissionMode = "default";',
        '    this.responses.clear();\n'
        '    this.allowedTools.clear();\n'
        '    this.allowedBashLiterals.clear();\n'
        '    this.allowedBashPrefixes.clear();\n'
        '    this.permissionMode = this.initialPermissionMode;',
    )

    # Patch 3: claudeRemoteLauncher - pass initial mode to PermissionHandler
    src = src.replace(
        '  const permissionHandler = new PermissionHandler(session);\n'
        '  const messageQueue = new OutgoingMessageQueue(',
        '  const initialPermissionMode = resolveInitialClaudePermissionMode(void 0, session.claudeArgs) ?? "default";\n'
        '  const permissionHandler = new PermissionHandler(session, initialPermissionMode);\n'
        '  const messageQueue = new OutgoingMessageQueue(',
    )

    # Patch 4: BASE_SYSTEM_PROMPT - add Chinese language rule
    src = src.replace(
        'const BASE_SYSTEM_PROMPT = (() => trimIdent(`\n'
        '    ALWAYS when you start a new chat - you must call a tool "mcp__happy__change_title" to set a chat title. When you think chat title is not relevant anymore - call the tool again to change it. When chat name is too generic and you have a change to make it more specific - call the tool again to change it. This title is needed to easily find the chat in the future. Help human.\n'
        '`))();',
        'const BASE_SYSTEM_PROMPT = (() => trimIdent(`\n'
        '    ALWAYS when you start a new chat - you must call a tool "mcp__happy__change_title" to set a chat title. When you think chat title is not relevant anymore - call the tool again to change it. When chat name is too generic and you have a change to make it more specific - call the tool again to change it. This title is needed to easily find the chat in the future. Help human.\n'
        '\n'
        '    所有回复必须使用简体中文。无论任务类型、代码调试、技术讨论，均不例外。代码块内容除外，其余文字一律中文。\n'
        '`))();',
    )

    if src == original:
        print(f"SKIP (already patched or pattern not found): {path}")
        continue

    with open(path, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"PATCHED: {path}")

print("Done. Re-run after every `happy update`.")
