#!/usr/bin/env python3
"""
Patch happy 的 dist，让 Claude 会话把可选模型列表上报到 session metadata。
Re-run after every `npm i -g happy@...` / `happy update`（patch-happy.sh 会调用）。

问题：手机 App 的模型选择列表是**硬编码在 App 里**的
（packages/happy-app/sources/components/modelModeOptions.ts 的 getClaudeModelModes），
升本机的 Claude Code 或 happy CLI 都不会改变它。2026-10-24 实测：Expo 的
production 渠道最新 OTA 停在 2026-09-22，而 Opus 5.5 / Sonnet 5.5 / Haiku 5.5
是 10-09 才合入 App 的 main，所以手机上根本没有这几项。

做法：App 的 getAvailableModels 里本来就有一条动态路径 ——
`mapMetadataOptions(metadata?.models)` 非空就直接用它、跳过硬编码列表。
这条路径 2026-02-14 就存在（早于用户手机那版），且不按 flavor 限制，Claude 也走。
所以只要让 CLI 把列表写进 metadata 就行，不用等上游。

上游在做同一件事：PR #1844（fix(claude): discover runtime models and preserve
active selection），合并发版后即可删掉本脚本。

字段形状抄 CLI 自己的 ACP 路径（agent/acp/sessionConfigMetadata.ts 的
mergeAcpSessionConfigIntoMetadata）：{ code, value, description? }。App 侧
mapMetadataOptions 只读这三个字段 —— code 当 key，value 当显示名。

⚠️ App 侧用 zod 的 MetadataSchema.safeParse 解析 metadata，**解析失败会让整个
metadata 变成 null**（不只是模型列表丢失）。所以 code / value 必须是字符串。

只注入一处：带 `flavor: "claude"` 的 metadata 字面量里加一个 models 字段。
happy 每次启动都用 `tag: randomUUID()` 调 getOrCreateSession，也就是每次启动
都是一个新的会话行，所以这一处就覆盖了每次重启。

⚠️ 不要再往 `const session = X.sessionSyncClient(response)` 后面加无条件的
`session.updateMetadata((meta) => ({ ...meta, models }))` —— 2026-10-24 试过，
手机上会话直接坏掉（选择器空、会话异常）。原因是那一刻本地 meta 可能还没同步
回来，`{...null, models}` 会把 path / host / flavor 这些字段全抹掉，服务端还会
把这份残缺 metadata 存成新版本。创建点注入没有这个风险：只是往一个 happy 自己
填满的对象上加一个键，不做任何 spread。

锚点必须恰好匹配 1 次，否则该文件整个不写（打印 FAIL），已打过的直接跳过。
"""
import glob
import os
import sys

MARK = "__happyClaudeModels"

DIST = os.path.expanduser("~/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.*js")
targets = [p for p in glob.glob(DIST)
           if (p.endswith(".mjs") or p.endswith(".cjs")) and ".bak" not in p]

# 与上游 main 的 getClaudeModelModes() 一致：一行一个模型，不带 [1m] 孪生行
# （这些模型在 Claude Code 自己的模型表里都是 1M-native，后缀只会多加一个
# context-1m beta header，gateway / Bedrock / Vertex 可能拒绝）。
# key 用完整模型 id 而不是短别名：别名表里 `sonnet` 仍指向 Sonnet 4.6，
# 而 `opus-5` 根本不在别名表里。
MODELS = """const __happyClaudeModels = [
  { code: "claude-fable-5-1", value: "Fable 5.1", description: "1M context" },
  { code: "claude-fable-5", value: "Fable 5" },
  { code: "claude-opus-5-5", value: "Opus 5.5" },
  { code: "claude-opus-5", value: "Opus 5" },
  { code: "claude-sonnet-5-5", value: "Sonnet 5.5" },
  { code: "claude-haiku-5-5", value: "Haiku 5.5" }
];
"""

CREATE_ANCHOR = '    flavor: "claude",\n'
CREATE_NEW = '    flavor: "claude",\n    models: __happyClaudeModels,\n'

failed = False
patched = 0
for path in targets:
    name = os.path.basename(path)
    src = open(path, encoding="utf-8").read()
    if CREATE_ANCHOR not in src:
        continue                      # 不是带 Claude 启动路径的那个 bundle
    if MARK in src:
        print(f"  skip（已打过）: {name}")
        patched += 1
        continue

    problems = []
    out = src

    n = out.count(CREATE_ANCHOR)
    if n != 1:
        problems.append(f"创建点锚点出现 {n} 次（期望 1）")
    else:
        out = out.replace(CREATE_ANCHOR, CREATE_NEW)

    if problems:
        failed = True
        print(f"  FAIL（未写入）: {name}")
        for p in problems:
            print(f"      - {p}")
        continue

    # 常量放文件最前。它不引用任何东西，所以不存在初始化顺序问题；
    # mjs 的 import 会被提升，先于这行执行，不影响。
    out = MODELS + out

    with open(path + ".bak-models", "w", encoding="utf-8") as f:
        f.write(src)
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    patched += 1
    print(f"  ✓ patched: {name}（原文件备份为 {name}.bak-models）")

if not targets:
    print("ERROR: happy dist file not found")
    sys.exit(1)
if patched == 0 and not failed:
    print("ERROR: 没找到带 Claude 启动路径的 bundle（锚点全都不在）")
    sys.exit(1)
sys.exit(1 if failed else 0)
