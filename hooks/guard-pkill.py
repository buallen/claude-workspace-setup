#!/usr/bin/env python3
"""PreToolUse hook: 拦截 macOS 上会误杀一大片进程的 pkill / killall 写法。

背景：2026-10-15 16:20，PS tickets 会话执行了 GNU 写法
`pkill -f "vite" -u kan.lu --signal TERM`。macOS 的 BSD getopt 在第一个
非选项参数处就停止解析，后面的 `-u` `kan.lu` `--signal` `TERM` 全部变成额外
的匹配模式（多个模式之间是「或」），配合 -f 匹配完整命令行，一次杀掉 186 个
进程：全部会话、Happy daemon、Otty 所有标签、隧道、小组件。见 memory
feedback_macos_pkill_gnu_syntax.md。

判定（任一命中即 deny）：
  1. 出现 `--xxx` 长选项 —— BSD pkill/killall 没有长选项，只可能是 GNU 写法
  2. 模式之后还跟着 `-x` 选项 —— 在 macOS 上它会变成匹配模式
  3. 模式里含用户名 / home 路径，或者整个模式就是 node、zsh 这类通用词
  4. 没有模式、只靠 -u/-U/-G 选人 —— 等于杀掉该用户的全部进程
远程命令（ssh 'pkill ...'）在引号里，不会被当成本机命令检查。
"""
import json
import os
import re
import shlex
import sys

USER = os.environ.get("USER", "kan.lu")
HOME = os.path.expanduser("~")

# 整个模式就是这些词时，会命中一大片进程
GENERIC = {
    "node", "python", "python3", "ruby", "java", "bun", "deno", "npm", "npx",
    "bash", "zsh", "sh", "login", "claude", "happy", "tmux", "otty",
    "chrome", "google chrome", "electron", "helper", ".", ".*", ".+",
}

# 写在命令前面、不改变实际要执行哪个程序的包装
WRAPPERS = {"sudo", "command", "exec", "nohup", "time", "nice", "builtin"}
WRAPPERS_WITH_ARG = {"timeout", "gtimeout"}
SHELLS = {"bash", "sh", "zsh"}

SIGNALS = {
    "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "EMT", "FPE", "KILL", "BUS",
    "SEGV", "SYS", "PIPE", "ALRM", "TERM", "URG", "STOP", "TSTP", "CONT",
    "CHLD", "TTIN", "TTOU", "IO", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH",
    "INFO", "USR1", "USR2",
}

# BSD pkill 里需要带参数的选项
PKILL_ARG_OPTS = set("FGgjMNPstTUuc")
KILLALL_ARG_OPTS = set("ctu")


def strip_heredocs(command: str) -> str:
    """去掉 heredoc 正文：它是喂给 stdin 的数据，不是命令，里面的撇号还会让 shlex 解析失败。"""
    out, pending = [], []
    for line in command.split("\n"):
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        out.append(line)
        pending = re.findall(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
    return "\n".join(out)


def split_commands(command: str) -> list[list[str]]:
    """按 ; && || | & 换行切成简单命令，引号内的内容保持原样。"""
    lex = shlex.shlex(command, posix=True, punctuation_chars="();<>|&\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    segments, cur = [], []
    skip_target = False
    for tok in lex:
        if skip_target:
            skip_target = False
            continue
        if ("<" in tok or ">" in tok) and set(tok) <= set("<>&"):
            # 重定向：丢掉 2>/dev/null 里的 fd 号和目标文件，它们不是命令参数
            if cur and cur[-1].isdigit():
                cur.pop()
            skip_target = True
            continue
        if tok and set(tok) <= set("();<>|&\n"):
            if cur:
                segments.append(cur)
            cur = []
        else:
            cur.append(tok)
    if cur:
        segments.append(cur)
    return segments


def strip_wrappers(argv: list[str]) -> list[str]:
    i = 0
    while i < len(argv):
        w = argv[i]
        base = os.path.basename(w)
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w):
            i += 1
        elif base == "env":
            i += 1
            while i < len(argv) and (argv[i].startswith("-") or "=" in argv[i]):
                i += 2 if argv[i] in ("-u", "-C", "-S") else 1
        elif base in WRAPPERS:
            i += 1
            while i < len(argv) and argv[i].startswith("-"):
                i += 1
        elif base in WRAPPERS_WITH_ARG:
            i += 1
            while i < len(argv) and argv[i].startswith("-"):
                i += 1
            i += 1  # 时长
        else:
            break
    return argv[i:]


def broad_pattern(pat: str) -> str | None:
    low = pat.lower()
    for needle in (USER.lower(), USER.lower().replace(".", r"\."), HOME.lower(), "/users/"):
        if needle and needle in low:
            return f"模式「{pat}」含用户名或 home 路径，几乎每个进程的命令行里都有"
    core = low.strip("^$'\" ")
    if core in GENERIC:
        return f"模式「{pat}」是通用词，会命中一大片同类进程"
    if len(core) < 3:
        return f"模式「{pat}」太短，会误命中大量进程"
    return None


def check_kill(prog: str, args: list[str]) -> str | None:
    arg_opts = PKILL_ARG_OPTS if prog == "pkill" else KILLALL_ARG_OPTS
    patterns, selectors = [], set()
    i = 0
    while i < len(args):
        a = args[i]
        if a.startswith("--"):
            return f"「{a}」是 GNU 长选项，macOS 的 {prog} 不认，会被当成匹配模式"
        if a.startswith("-") and len(a) > 1:
            if patterns:
                return (f"选项「{a}」写在模式「{patterns[0]}」后面，macOS 会把它"
                        f"和后面的参数都当成额外的匹配模式")
            flags = a[1:]
            is_signal = flags.isdigit() or flags.upper().removeprefix("SIG") in SIGNALS
            if not is_signal:
                for j, ch in enumerate(flags):
                    if ch in arg_opts:
                        selectors.add(ch)
                        if j == len(flags) - 1:
                            i += 1  # 参数在下一个 token
                        break
        else:
            patterns.append(a)
        i += 1

    for pat in patterns:
        reason = broad_pattern(pat)
        if reason:
            return reason
    if not patterns and selectors & {"u", "U", "G"}:
        return f"{prog} 没有给模式、只按用户/组选进程，等于杀掉该用户的全部进程"
    return None


def find_violation(command: str, depth: int = 0) -> str | None:
    command = strip_heredocs(command)
    try:
        segments = split_commands(command)
    except ValueError:
        # 引号不配对等解析失败：去掉引号内容后，只兜底最明确的 GNU 写法
        bare = re.sub(r"\"[^\"\n]*\"|'[^'\n]*'", "''", command)
        if re.search(r"\b(pkill|killall)\b[^;&|\n]*\s--\w", bare):
            return "命令里 pkill/killall 带了 GNU 长选项"
        return None
    for seg in segments:
        argv = strip_wrappers(seg)
        if not argv:
            continue
        prog = os.path.basename(argv[0])
        if prog in ("pkill", "killall"):
            reason = check_kill(prog, argv[1:])
            if reason:
                return reason
        elif depth < 2 and (prog in SHELLS or prog == "eval"):
            # bash -c '...' / eval '...' 里的命令同样在本机执行
            body = None
            if prog == "eval":
                body = " ".join(argv[1:])
            elif "-c" in argv[1:]:
                k = argv.index("-c")
                body = argv[k + 1] if k + 1 < len(argv) else None
            if body:
                reason = find_violation(body, depth + 1)
                if reason:
                    return reason
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # 解析失败不阻断正常工作
    if payload.get("tool_name") != "Bash":
        return 0
    command = (payload.get("tool_input") or {}).get("command", "")
    if not command or not re.search(r"\b(pkill|killall)\b", command):
        return 0

    reason = find_violation(command)
    if not reason:
        return 0
    msg = (
        f"⛔️ 已阻止：{reason}。\n\n"
        "2026-10-15 一条 `pkill -f \"vite\" -u kan.lu --signal TERM` 在 macOS 上"
        "杀掉了 186 个进程（全部会话、Happy daemon、Otty 标签、隧道）。\n\n"
        "改成安全写法：\n"
        "  1. 先 `pgrep -fl '<足够独特的模式>'` 看清匹配到哪些进程\n"
        "  2. 确认只有目标后按 PID `kill <pid>`\n"
        "非要用 pkill：所有选项放在模式前面，信号写 `-TERM` 不写 `--signal`，"
        "模式里不要出现用户名、home 路径或 node/zsh 这类通用词。"
    )
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": msg,
        }
    }, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
