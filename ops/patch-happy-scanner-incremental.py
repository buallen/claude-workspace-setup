#!/usr/bin/env python3
"""
Patch happy 的 dist，让 SESSION_SCANNER 增量读取 session JSONL。
Re-run after every `npm i -g happy@...` / `happy update`（patch-happy.sh 会调用）。

问题：sessionScanner 每 3 秒、以及每次文件变更，都把整个 JSONL readFile + 逐行
JSON.parse + zod 校验一遍，对话越长越耗；14 个会话合计常年 160~240% CPU、10G+ 内存。
上游 issue #1841 / #1902，修复 PR https://github.com/slopus/happy/pull/1915 ——
本脚本是同一实现的编译产物版，PR 合并发版后即可删掉。

做法：每个文件记 (dev, ino, 已读字节, 未完成的末行)。没变化不读；只读新增字节；
文件被替换 / 变小 / 原地改写（上次停的位置前一字节不再是换行）时从头重读。
游标在调用方处理完这批条目后才提交，回调抛错重试时不会丢消息。

每处锚点必须恰好匹配 1 次，否则该文件整个不写（打印 FAIL），已打过的直接跳过。
"""
import glob
import os
import re
import sys

MARK = "__scanCursors"

DIST = os.path.expanduser("~/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.*js")
targets = [p for p in glob.glob(DIST)
           if (p.endswith(".mjs") or p.endswith(".cjs")) and ".bak" not in p]

HEAD_RE = re.compile(
    r'async function readSessionEntries\(projectDir, sessionId\) \{\n'
    r'  const expectedSessionFile = (?P<join>[\w$.]+)\(projectDir, `\$\{sessionId\}\.jsonl`\);\n'
    r'  (?P<log>[\w$.]+)\.debug\(`\[SESSION_SCANNER\] Reading session file: \$\{expectedSessionFile\}`\);\n'
    r'  let file;\n'
    r'  try \{\n'
    r'    file = await [\w$.]+\(expectedSessionFile, "utf-8"\);\n'
    r'  \} catch \(error\) \{\n'
    r'    [\w$.]+\.debug\(`\[SESSION_SCANNER\] Session file not found: \$\{expectedSessionFile\}`\);\n'
    r'    return \[\];\n'
    r'  \}\n'
    r'  let lines = file\.split\("\\n"\);\n'
)

NEW_HEAD = '''async function readSessionEntries(projectDir, sessionId, cursors) {
  const expectedSessionFile = JOIN(projectDir, `${sessionId}.jsonl`);
  LOG.debug(`[SESSION_SCANNER] Reading session file: ${expectedSessionFile}`);
  const cursor = cursors ? cursors.get(expectedSessionFile) : void 0;
  let data;
  let next;
  let __cold = false;
  try {
    const probe = await __scanStat(expectedSessionFile);
    if (cursor && probe.dev === cursor.dev && probe.ino === cursor.ino && probe.size === cursor.offset) {
      return { entries: [], commit: () => {} };
    }
    const handle = await __scanOpen(expectedSessionFile, "r");
    try {
      const { dev, ino, size } = await handle.stat();
      let resumeFrom = cursor && cursor.dev === dev && cursor.ino === ino && cursor.offset <= size ? cursor : void 0;
      const lineStart = resumeFrom ? resumeFrom.offset - resumeFrom.tail.length : 0;
      if (resumeFrom && lineStart > 0) {
        const previous = Buffer.alloc(1);
        const { bytesRead } = await handle.read(previous, 0, 1, lineStart - 1);
        if (bytesRead !== 1 || previous[0] !== 10) {
          resumeFrom = void 0;
        }
      }
      const start = resumeFrom ? resumeFrom.offset : 0;
      __cold = start === 0;
      const fresh = Buffer.alloc(size - start);
      let filled = 0;
      while (filled < fresh.length) {
        const { bytesRead } = await handle.read(fresh, filled, fresh.length - filled, start + filled);
        if (bytesRead === 0) {
          break;
        }
        filled += bytesRead;
      }
      data = resumeFrom && resumeFrom.tail.length > 0 ? Buffer.concat([resumeFrom.tail, fresh.subarray(0, filled)]) : fresh.subarray(0, filled);
      next = { dev, ino, offset: start + filled, tail: Buffer.alloc(0) };
    } finally {
      await handle.close();
    }
  } catch (error) {
    LOG.debug(`[SESSION_SCANNER] Session file not found: ${expectedSessionFile}`);
    return { entries: [], commit: () => {} };
  }
  const completeEnd = data.lastIndexOf(10) + 1;
  next.tail = Buffer.from(data.subarray(completeEnd));
  let lines = data.toString("utf-8", 0, completeEnd).split("\\n");
  if (__cold && lines.length > __scanColdLimit) {
    LOG.debug(`[SESSION_SCANNER] cold read: keeping the last ${__scanColdLimit} of ${lines.length} lines`);
    lines = lines.slice(-__scanColdLimit);
  }
'''

# 冷启动（从文件头读）时最多取多少行。2026-11-04 加的，起因见下。
#
# 第一版没有这个上限，于是每次会话重启都把整份 transcript 推进一条新建的 App
# 会话行：TroubleShooting 实测 5345 条消息在 5 秒内灌完，手机从最早那条开始渲染
# 经常卡住，看上去像「只有陈年历史、没有最近的」。本意是靠调用方的「预标记已存在
# 条目」来压住，但扫描器会把同一个会话注册两次（日志里 `New session` /
# `Starting watcher` 各两次），第二次没有预标记，于是 `Pre-marking 5345 existing
# entries` 后面紧跟 5345 次 `Sending new message`。
#
# 这个上限不去修那个竞态，而是从源头封顶：**不管预标记失不失效、注册几次，一次
# 冷读最多产出这么多条**。增量读（有有效游标）不受影响，所以正常对话一条不少。
#
# 单位是 transcript 的行，不是 App 里的消息条数 —— 实测 14111 行约对应 5345 条
# 消息（约 0.38），所以 300 行大致是 100 条出头，正好是 Kan 要的量级。
# 想调就设环境变量 HAPPY_SCAN_COLD_LIMIT。
COLD_LIMIT_LINE = (
    "const __scanColdLimit = Math.max(1, "
    "Number(process.env.HAPPY_SCAN_COLD_LIMIT || 300) || 300);\n"
)

# (旧文本, 新文本)：调用点与游标 Map
SIMPLE = [
    ("  let deadSessions = /* @__PURE__ */ new Set();\n",
     "  let deadSessions = /* @__PURE__ */ new Set();\n  let __scanCursors = /* @__PURE__ */ new Map();\n"),
    ("    let entries = await readSessionEntries(projectDir, opts.sessionId);\n",
     "    let { entries, commit: __scanCommit0 } = await readSessionEntries(projectDir, opts.sessionId, __scanCursors);\n"),
    ("    for (let entry of entries) {\n      processedEntryKeys.add(entry.key);\n    }\n    currentSessionId = opts.sessionId;\n",
     "    for (let entry of entries) {\n      processedEntryKeys.add(entry.key);\n    }\n    __scanCommit0();\n    currentSessionId = opts.sessionId;\n"),
    ("      const sessionEntries = await readSessionEntries(projectDir, session);\n",
     "      const { entries: sessionEntries, commit: __scanCommit1 } = await readSessionEntries(projectDir, session, __scanCursors);\n"),
    ("      if (sessionEntries.length > 0) {\n",
     "      __scanCommit1();\n      if (sessionEntries.length > 0) {\n"),
    ("        const existing = await readSessionEntries(projectDir, sessionId);\n",
     "        const { entries: existing, commit: __scanCommit2 } = await readSessionEntries(projectDir, sessionId, __scanCursors);\n"),
    ("        for (const entry of existing) {\n          processedEntryKeys.add(entry.key);\n        }\n",
     "        for (const entry of existing) {\n          processedEntryKeys.add(entry.key);\n        }\n        __scanCommit2();\n"),
]

failed = False
for path in targets:
    name = os.path.basename(path)
    src = open(path, encoding="utf-8").read()
    if "SESSION_SCANNER" not in src:
        continue
    if MARK in src:
        print(f"  skip（已打过）: {name}")
        continue

    problems = []
    out = src
    for old, new in SIMPLE:
        n = out.count(old)
        if n != 1:
            problems.append(f"锚点出现 {n} 次: {old.strip()[:60]}")
            continue
        out = out.replace(old, new)

    heads = list(HEAD_RE.finditer(out))
    if len(heads) != 1:
        problems.append(f"readSessionEntries 头部匹配 {len(heads)} 次")
    else:
        m = heads[0]
        head = NEW_HEAD.replace("JOIN", m.group("join")).replace("LOG", m.group("log"))
        out = out[:m.start()] + head + out[m.end():]
        tail_at = out.find("  return entries;\n}\n", m.start())
        if tail_at < 0:
            problems.append("找不到 readSessionEntries 结尾")
        else:
            new_tail = "  return { entries, commit: () => { if (cursors) cursors.set(expectedSessionFile, next); } };\n}\n"
            out = out[:tail_at] + new_tail + out[tail_at + len("  return entries;\n}\n"):]

    # 引入 open / stat（不动原有 import，单独加一行，避免和打包器改过的名字冲突）
    if path.endswith(".mjs"):
        anchor = re.search(r"^import [^\n]*from 'node:fs/promises';\n", out, re.M)
        line = ("import { open as __scanOpen, stat as __scanStat } from 'node:fs/promises';\n"
                + COLD_LIMIT_LINE)
    else:
        anchor = re.search(r"^var promises = require\('node:fs/promises'\);\n", out, re.M)
        line = ("const { open: __scanOpen, stat: __scanStat } = require('node:fs/promises');\n"
                + COLD_LIMIT_LINE)
    if not anchor:
        problems.append("找不到 node:fs/promises 的导入行")
    else:
        out = out[:anchor.end()] + line + out[anchor.end():]

    if problems:
        failed = True
        print(f"  FAIL（未写入）: {name}")
        for p in problems:
            print(f"      - {p}")
        continue

    with open(path + ".bak-scanner", "w", encoding="utf-8") as f:
        f.write(src)
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    print(f"  ✓ patched: {name}（原文件备份为 {name}.bak-scanner）")

if not targets:
    print("ERROR: happy dist file not found")
    sys.exit(1)
sys.exit(1 if failed else 0)
