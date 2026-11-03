#!/usr/bin/env python3
"""
Patch happy 的 dist，让会话把可选模型列表上报到 session metadata，
并且在 GPT 会话里拦住手机发来的 claude-* 模型。
Re-run after every `npm i -g happy@...` / `happy update`（patch-happy.sh 会调用）。

────────────────────────────────────────────────────────────────────────
问题 1：手机 App 的模型选择列表是**硬编码在 App 里**的
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

────────────────────────────────────────────────────────────────────────
问题 2（2026-11-03 发现）：GPT 会话在手机上完全没法用，报
`API Error: 400 unknown provider for model claude-opus-5`。

原因不是「选错模型」，而是 **App 每条消息都带 meta.model**。dist 里：

    let messageModel = currentModel;
    if (message.meta?.hasOwnProperty("model")) {
      messageModel = message.meta.model || void 0;
      currentModel = messageModel;

所以手机上只要存着一个 Claude 模型的选择，每条消息都会把它塞给 SDK，而
GPT 会话的 ANTHROPIC_BASE_URL 指向本地 CLIProxyAPI，代理只认 gpt-*，
直接 400。终端里同一个会话是好的——终端不发 meta.model。

两处都要改，缺一不可：
  a) 上报的列表按会话后端切换，GPT 会话报 gpt-* ——手机上才选得到；
  b) 在 loop 里兜底：GPT 会话收到 claude-* 一律降为 undefined（= 不覆盖，
     让 Claude Code 用自己的 ANTHROPIC_MODEL）。没有 (b) 的话，手机上
     那个「已经存着的」claude-opus-5 照样会把会话打死。

判据用 `process.env.ANTHROPIC_MODEL` 以 `gpt-` 开头 —— smart-resume.sh 只给
`.backend=gpt` 的会话注入它，其余会话显式 `env -u` 掉，所以这是进程级的、
不会误伤普通 Claude 会话（同一份 dist 被所有会话共用）。

────────────────────────────────────────────────────────────────────────
注入点只有两个，且都不做 spread：

⚠️ 不要再往 `const session = X.sessionSyncClient(response)` 后面加无条件的
`session.updateMetadata((meta) => ({ ...meta, models }))` —— 2026-10-24 试过，
手机上会话直接坏掉（选择器空、会话异常）。原因是那一刻本地 meta 可能还没同步
回来，`{...null, models}` 会把 path / host / flavor 这些字段全抹掉，服务端还会
把这份残缺 metadata 存成新版本。创建点注入没有这个风险：只是往一个 happy 自己
填满的对象上加一个键。

锚点必须恰好匹配 1 次，否则该文件整个不写（打印 FAIL）。
模型列表块用 sentinel 注释包起来，重跑时**就地整块替换**，不依赖 .bak-models
回滚（那样会连带撤销 patch 1-4 的改动）。
"""
import glob
import os
import re
import sys

MARK = "__happyClaudeModels"
GUARD_MARK = "__happyGptSession"

DIST = os.path.expanduser("~/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.*js")
targets = [p for p in glob.glob(DIST)
           if (p.endswith(".mjs") or p.endswith(".cjs")) and ".bak" not in p]

# Claude 侧与上游 main 的 getClaudeModelModes() 一致：一行一个模型，不带 [1m]
# 孪生行（这些模型在 Claude Code 自己的模型表里都是 1M-native，后缀只会多加一个
# context-1m beta header，gateway / Bedrock / Vertex 可能拒绝）。
# key 用完整模型 id 而不是短别名：别名表里 `sonnet` 仍指向 Sonnet 4.6，
# 而 `opus-5` 根本不在别名表里。
#
# GPT 侧三个模型就是本地代理 config 里 api-keys.codex 暴露的全部，多写一个会
# 被代理 `unknown provider` 拒掉。顺序 = 默认在最前。
BEGIN = "// <<<happy-models-begin>>>\n"
END = "// <<<happy-models-end>>>\n"
MODELS = BEGIN + """const __happyGptSession = (process.env.ANTHROPIC_MODEL || "").startsWith("gpt-");
const __happyClaudeModels = __happyGptSession ? [
  { code: "gpt-6-sol", value: "GPT-6 Sol", description: "default, coding" },
  { code: "gpt-6.1-sol", value: "GPT-6.1 Sol", description: "strongest, often busy" },
  { code: "gpt-6-astra", value: "GPT-6 Astra", description: "design, hard debugging" }
] : [
  { code: "claude-fable-5-1", value: "Fable 5.1", description: "1M context" },
  { code: "claude-fable-5", value: "Fable 5" },
  { code: "claude-opus-5-5", value: "Opus 5.5" },
  { code: "claude-opus-5", value: "Opus 5" },
  { code: "claude-sonnet-5-5", value: "Sonnet 5.5" },
  { code: "claude-haiku-5-5", value: "Haiku 5.5" }
];
""" + END

# 旧格式（无 sentinel）和新格式都能匹配，重跑时整块换掉。
BLOCK_RE = re.compile(
    r"(?://\s*<<<happy-models-begin>>>\n)?"
    r"(?:const __happyGptSession = .*?\n)?"
    r"const __happyClaudeModels = .*?^\];\n"
    r"(?://\s*<<<happy-models-end>>>\n)?",
    re.S | re.M,
)

CREATE_ANCHOR = '    flavor: "claude",\n'
CREATE_NEW = '    flavor: "claude",\n    models: __happyClaudeModels,\n'

# App 每条消息都带 meta.model；GPT 会话收到 claude-* 时降为 undefined，
# 即「不覆盖」，SDK 退回 Claude Code 自己的 ANTHROPIC_MODEL（= gpt-6-sol）。
GUARD_ANCHOR = """    let messageModel = currentModel;
    if (message.meta?.hasOwnProperty("model")) {
      messageModel = message.meta.model || void 0;
      currentModel = messageModel;
"""
GUARD_NEW = """    let messageModel = currentModel;
    if (message.meta?.hasOwnProperty("model")) {
      messageModel = message.meta.model || void 0;
      if (__happyGptSession && typeof messageModel === "string" && messageModel.startsWith("claude-")) {
        logger.debug(`[loop] GPT session: dropping client model override ${messageModel}`);
        messageModel = void 0;
      }
      currentModel = messageModel;
"""

failed = False
patched = 0
for path in targets:
    name = os.path.basename(path)
    src = open(path, encoding="utf-8").read()
    if CREATE_ANCHOR not in src and MARK not in src:
        continue                      # 不是带 Claude 启动路径的那个 bundle

    problems = []
    out = src

    # 1) 模型列表常量：已存在就整块替换，否则放文件最前。
    #    它不引用任何东西，所以不存在初始化顺序问题；mjs 的 import 会被提升，
    #    先于这行执行，不影响。
    if MARK in out:
        n = len(BLOCK_RE.findall(out))
        if n != 1:
            problems.append(f"已注入的模型列表块匹配到 {n} 处（期望 1），不敢替换")
        else:
            out = BLOCK_RE.sub(lambda _: MODELS, out, count=1)
    else:
        out = MODELS + out

    # 2) 创建点注入 models 字段
    if "models: __happyClaudeModels," not in out:
        n = out.count(CREATE_ANCHOR)
        if n != 1:
            problems.append(f"创建点锚点出现 {n} 次（期望 1）")
        else:
            out = out.replace(CREATE_ANCHOR, CREATE_NEW)

    # 3) loop 里的 claude-* 兜底
    if GUARD_MARK + " && typeof messageModel" not in out:
        n = out.count(GUARD_ANCHOR)
        if n != 1:
            problems.append(f"模型覆盖兜底锚点出现 {n} 次（期望 1）")
        else:
            out = out.replace(GUARD_ANCHOR, GUARD_NEW)

    if problems:
        failed = True
        print(f"  FAIL（未写入）: {name}")
        for p in problems:
            print(f"      - {p}")
        continue

    if out == src:
        print(f"  skip（已是最新）: {name}")
        patched += 1
        continue

    if not os.path.exists(path + ".bak-models"):
        with open(path + ".bak-models", "w", encoding="utf-8") as f:
            f.write(src)
    with open(path, "w", encoding="utf-8") as f:
        f.write(out)
    patched += 1
    print(f"  ✓ patched: {name}")

if not targets:
    print("ERROR: happy dist file not found")
    sys.exit(1)
if patched == 0 and not failed:
    print("ERROR: 没找到带 Claude 启动路径的 bundle（锚点全都不在）")
    sys.exit(1)
sys.exit(1 if failed else 0)
