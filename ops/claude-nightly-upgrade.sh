#!/bin/bash
# claude-nightly-upgrade.sh — 每天 04:00 由 com.kanlu.claude-nightly-upgrade 触发
#
# 做两件事：
#   1) 把 Claude Code 升到 npm 上的 latest
#   2) 把「跑着旧版且当前空闲」的 tmux session 重启到新版
#
# 为什么第 2 步不能省：运行中的 claude 进程用的是启动瞬间加载进内存的镜像，
# 光升 npm 包，已经在跑的 session 一辈子还是旧版。2026-08-22→09-02 这 11 天
# 出了 20 个版本，手动逐个重启不现实。
#
# 04:00 这个点是挑过的：00:25 distiller / 02:30 mall-effect / 02:55 mall-heartbeat
# 都会拉起 claude 进程，撞上会互相干扰；03:30–08:00 是唯一的空档。
#
# 用法：
#   claude-nightly-upgrade.sh              正常执行
#   claude-nightly-upgrade.sh --dry-run    只报告会做什么，不 kill 不装包

set -uo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

NODE_VER="v22.22.0"
NVM_BIN="$HOME/.nvm/versions/node/$NODE_VER/bin"
NVM_PREFIX="$HOME/.nvm/versions/node/$NODE_VER"
CC_DIR="$NVM_PREFIX/lib/node_modules/@anthropic-ai/claude-code"
CC_SYMLINK="/opt/homebrew/bin/claude"
SMART_RESUME="$HOME/.claude/claude-workspace/bin/smart-resume.sh"
# 名字不能叫 TMUX：tmux 用 $TMUX 环境变量定位 server socket，覆盖成二进制
# 路径后，脚本里所有 tmux 命令都连不上 server（list-sessions 静默返回空）。
TMUX_BIN="/opt/homebrew/bin/tmux"
LARK_CLI="/opt/homebrew/bin/lark-cli"
# Lark 收件人放在不进仓库的本地配置里（仓库公开）；没配就只记日志不发通知
[ -f "$HOME/.config/claude-workspace/local.env" ] && . "$HOME/.config/claude-workspace/local.env"
KAN_OPEN_ID="${LARK_NOTIFY_USER_ID:-}"
LOG_FILE="/tmp/claude-nightly-upgrade.log"
# 单个 session 最坏路径 = KILL_WAIT + SHELL_WAIT + BOOT_WAIT×2 ≈ 95s；
# 14 个 session 全走最坏 ≈ 22 分钟，加上 npm 升级，30 分钟已经没有余量了，所以提到 40。
# 04:00 起跑，最晚 04:40 结束，下一个 cron 在 08:00 之后，不会撞上。
MAX_RUNTIME=2400          # 40 分钟总超时
KILL_WAIT=20              # 单个进程等待退出的秒数
SHELL_WAIT=15             # kill 后等 pane 回落到 shell 的秒数（happy 收尾可能慢于 claude.exe）
BOOT_WAIT=30              # 重启后等待新进程出现的秒数（失败会重发一次，总计 2×）

# nvm 必须在 PATH 最前。这不是风格问题：即使写 npm 的全路径，那个 npm 也是被
# PATH 里第一个 node 执行的，而 /opt/homebrew/bin/node 排在 nvm 前面 —— 2026-09-02
# 就是这么把 2.1.258 静默装进 /opt/homebrew/Cellar/node/26.0.0 的，npm 还报 exit 0。
export PATH="$NVM_BIN:$PATH"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

notify() {
  [ -x "$LARK_CLI" ] || return 0
  "$LARK_CLI" im +messages-send --as user --user-id "$KAN_OPEN_ID" --text "$1" >/dev/null 2>&1
}

# 内建 watchdog，不用 gtimeout —— 外部二进制包装会把 TCC 责任方从 bash 换成
# gtimeout，半夜弹权限窗无人点，反而成了 hang 源。见 memory 里 gtimeout 那条。
( sleep "$MAX_RUNTIME"; kill -9 $$ 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!
trap 'kill "$WATCHDOG_PID" 2>/dev/null' EXIT

log "═══════ 开始 ($([ $DRY_RUN = 1 ] && echo DRY-RUN || echo 正式执行)) ═══════"

# ── 第一步：升级 npm 包 ────────────────────────────────────────────────────
UPGRADE_MSG=""
cur_ver=$(node -p "require('$CC_DIR/package.json').version" 2>/dev/null)
if [ -z "$cur_ver" ]; then
  log "❌ 读不到当前版本（$CC_DIR 不存在？），中止"
  notify "🔴 Claude 夜间升级中止：读不到 $CC_DIR/package.json"
  exit 1
fi

latest_ver=$(npm view @anthropic-ai/claude-code version --fetch-timeout=30000 2>/dev/null | tail -1 | tr -d '[:space:]')

if [ -z "$latest_ver" ]; then
  log "⚠ 查不到 npm latest（网络？），跳过升级，继续把已装的 $cur_ver 铺开"
  UPGRADE_MSG="查询 npm 失败，未升级（仍为 ${cur_ver}）"
elif [ "$cur_ver" = "$latest_ver" ]; then
  log "✅ 已是最新 ${cur_ver}，跳过升级"
  UPGRADE_MSG="已是最新 $cur_ver"
else
  log "发现新版：$cur_ver → $latest_ver"
  # 硬校验 prefix。装错位置比不装更糟：npm 会报 success，nvm 那份纹丝不动，
  # 而 /opt/homebrew/bin/claude 软链仍指向旧版，问题被完全掩盖。
  prefix=$(npm config get prefix 2>/dev/null)
  if [ "$prefix" != "$NVM_PREFIX" ]; then
    log "❌ npm prefix = ${prefix}，期望 $NVM_PREFIX —— 拒绝升级（会装错位置）"
    notify "🔴 Claude 夜间升级中止：npm prefix 指向 $prefix 而非 nvm，升级会静默装错位置。请检查 PATH 里 node 的顺序。"
    UPGRADE_MSG="prefix 异常($prefix)，未升级"
  elif [ $DRY_RUN = 1 ]; then
    log "[dry-run] 会执行：npm i -g @anthropic-ai/claude-code@latest"
    UPGRADE_MSG="[dry-run] $cur_ver → $latest_ver"
  else
    npm i -g @anthropic-ai/claude-code@latest >>"$LOG_FILE" 2>&1
    new_ver=$(node -p "require('$CC_DIR/package.json').version" 2>/dev/null)
    if [ "$new_ver" = "$latest_ver" ]; then
      log "✅ 升级成功 $cur_ver → $new_ver"
      UPGRADE_MSG="升级 $cur_ver → $new_ver"
    else
      log "❌ 升级后版本仍是 ${new_ver}（期望 ${latest_ver}）"
      notify "🔴 Claude 夜间升级异常：装完仍是 ${new_ver}，期望 $latest_ver"
      UPGRADE_MSG="升级失败（仍为 ${new_ver}）"
    fi
  fi
fi

# 软链自愈。5 个脚本硬编码 /opt/homebrew/bin/claude，5 个 plist 的 PATH 里只有
# /opt/homebrew/bin 没有 nvm；同时 TCC 的 FDA 授权是按软链解析后的真实路径认的，
# 指向必须一直是 nvm 那条，不能让 npm 或 brew 把它改到 Cellar 去。
EXPECTED_TARGET="$CC_DIR/bin/claude.exe"
if [ "$(readlink "$CC_SYMLINK" 2>/dev/null)" != "$EXPECTED_TARGET" ]; then
  if [ $DRY_RUN = 1 ]; then
    log "[dry-run] 软链指向异常，会重建 $CC_SYMLINK → $EXPECTED_TARGET"
  else
    log "⚠ 软链指向异常，重建 $CC_SYMLINK → $EXPECTED_TARGET"
    ln -sf "$EXPECTED_TARGET" "$CC_SYMLINK" && log "✅ 软链已重建"
    notify "⚠️ /opt/homebrew/bin/claude 指向被改动过，已重建指回 nvm"
  fi
fi

PKG_MTIME=$(stat -f '%m' "$CC_DIR/package.json" 2>/dev/null || echo 0)

# ── 第二步：重启版本落后且空闲的 session ──────────────────────────────────
# 把所有 claude.exe 归属到 session：对每个 claude pid 向上追祖先，直到命中某个
# tmux pane_pid。从进程往上追比从 pane 往下找可靠 —— pgrep -f 在沙箱里会漏进程，
# ps -eo args= 的输出又会被 CLAUDE.md 里的多行 commit 模板撑断行。
#
# 整个映射用一次 awk 算完。最初的写法是「对每个 session 遍历所有 claude 进程、
# 每追一层调一次 awk」，16 session × 12 进程 × 12 层 ≈ 2300 次进程创建，
# 跑 3 分钟都出不来结果。
build_claude_map() {
  ps -eo pid=,ppid= | awk '{print $1" "$2}' > /tmp/cnu-pidppid.txt
  "$TMUX_BIN" list-panes -a -F '#{pane_pid}|#{session_name}' 2>/dev/null > /tmp/cnu-panes.txt
  ps -eo pid=,command= | grep -F 'claude.exe' | grep -v grep | awk '{print $1}' > /tmp/cnu-claudepids.txt
  awk '
    FILENAME ~ /pidppid/ { parent[$1] = $2; next }
    FILENAME ~ /panes/   { split($0, a, "|"); pane[a[1]] = a[2]; next }
    {
      p = $1
      for (i = 0; i < 12; i++) {
        if (p in pane)      { print $1 "|" pane[p]; break }
        if (!(p in parent)) break
        p = parent[p]
        if (p == 1 || p == 0) break
      }
    }
  ' /tmp/cnu-pidppid.txt /tmp/cnu-panes.txt /tmp/cnu-claudepids.txt > /tmp/cnu-map.txt
}

find_claude_pid() {
  awk -F'|' -v s="$1" '$2==s {print $1; exit}' /tmp/cnu-map.txt
}

build_claude_map

RESTARTED=(); SKIPPED_BUSY=(); SKIPPED_AGENT=(); SKIPPED_CURRENT=(); REMOTE=(); FAILED=()

while IFS= read -r sess; do
  [ -z "$sess" ] && continue

  pid=$(find_claude_pid "$sess")
  if [ -z "$pid" ]; then
    # 没有本地 claude 进程 = happy 远程模式（手机端驱动），下次唤起自然加载新版
    REMOTE+=("$sess")
    continue
  fi

  # 版本判定：ps eww 在 macOS 读不到别的进程的环境变量，所以用
  # 「进程启动时间 vs 包安装时间」这个可靠代理。
  lstart=$(ps -o lstart= -p "$pid" 2>/dev/null | xargs)
  pstart=$(date -j -f '%a %b %d %T %Y' "$lstart" '+%s' 2>/dev/null || echo 0)
  if [ "$pstart" -gt "$PKG_MTIME" ]; then
    SKIPPED_CURRENT+=("$sess")
    continue
  fi

  pane=$("$TMUX_BIN" capture-pane -p -t "$sess" 2>/dev/null)

  # ── 三道闸。前两道读 pane 渲染，第三道读 transcript mtime ──────────────
  #
  # ⚠️ 2026-10-20 重写。原先两道闸从 2026-09-11 上线到 10-19 共 365 次重启
  # **一次都没触发过**，10-20 04:01 把 Infra 正在跑的 oplog-overnight-round2
  # 工作流连同它的 sidechain 子 agent 一起杀了（子 agent 在被 kill 前 1 秒还在
  # 写 jsonl）。实测复现后确认两道闸的 pattern 都对不上真实渲染：
  #
  #   闸1 旧 'esc to interrupt'
  #       —— 主 loop 等后台任务时底部渲染的是 spinner 行
  #          「· Germinating… (3m 24s · ↓ 10.9k tokens)」，没有这几个字。
  #   闸2 旧 '^[[:space:]]*◯.*agents done'
  #       —— 「agents done」这个写法是旧版 UI。现在 ◯ 行只有
  #          「◯ Explore  <描述>    16s · ↓ 23.3k tokens」，
  #          agents 字样被挪到了状态栏的「← 2 agents」，而那行**空闲时也在**，
  #          所以不能拿 ← N agents 当判据（实测 3 个空闲 session 全部误报）。
  #
  # 下面的 pattern 是 2026-10-20 用「1 个正在跑 agent 的 pane + 3 个空闲 pane」
  # 实测对照过的，4/4 判定正确。改这里之前请照同样的方法重测，别凭 UI 猜。

  # 闸1：主 loop 正在跑。spinner 行形如「<符号> Germinating… (3m 24s · ↓ 10.9k tokens)」，
  # 判据取「有 ↓ N tokens) 且同行没有 · done」——空闲时那行是
  # 「✻ Crunched for 15m 4s · done Monday 3:07 PM」，带 done 不带右括号。
  # spinner 符号本身会轮换（实测见过 · 和 ✶），所以不匹配符号。
  # 旧的 esc to interrupt 保留为 OR 分支：某些 UI 状态下仍会出现。
  if echo "$pane" | grep -q 'esc to interrupt' \
     || echo "$pane" | awk '/↓[ ]*[0-9.]+k?[ ]*tokens\)/ && !/· done/ { found = 1 } END { exit !found }'; then
    SKIPPED_BUSY+=("$sess")
    log "⏭  $sess — 主 loop 正在跑任务，跳过"
    continue
  fi

  # 闸2：有后台 agent 未完成。主 loop 显示空闲不代表没活——Workflow / Task 派出去的
  # 子 agent 会在状态栏下方各占一行「◯ <类型>  <描述>   <时长> · ↓ <tokens>」。
  # ◯ = 在跑，⏺ = 已结束；⏺ 同时也是普通回复行的前缀，所以只认 ◯，不认 ⏺。
  if echo "$pane" | grep -qE '^[[:space:]]*◯[[:space:]]'; then
    SKIPPED_AGENT+=("$sess")
    log "⏭  $sess — 有后台 agent 在跑，跳过"
    continue
  fi

  # 闸3：transcript 还在被写。前两道依赖 UI 文本，Claude Code 一改渲染就会静默失效
  # （已经发生过一次），这道只看 jsonl 的 mtime，不依赖任何渲染。
  # 实测依据：真正空闲的 session 从上次重启起 7.5 小时一个字节都没写；
  # 而被误杀的 Infra 在 kill 前 1 秒还在写。阈值 600s 给慢工具留足余量。
  if [ "$sess" = "Personal" ]; then gate_base="$HOME/.claude-private/projects"
  else gate_base="$HOME/.claude/projects"; fi
  gate_slug=$(echo "$HOME/claude-sessions/$sess" | sed 's|[/. ]|-|g')
  gate_jsonl=$(ls -t "$gate_base/$gate_slug"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$gate_jsonl" ]; then
    gate_age=$(( $(date +%s) - $(stat -f '%m' "$gate_jsonl" 2>/dev/null || echo 0) ))
    if [ "$gate_age" -lt 600 ]; then
      SKIPPED_AGENT+=("$sess")
      log "⏭  $sess — transcript ${gate_age}s 前还在写，判定仍在活动，跳过"
      continue
    fi
  fi

  if [ $DRY_RUN = 1 ]; then
    log "[dry-run] 会重启 $sess (pid=$pid, 启动于 $lstart)"
    RESTARTED+=("$sess")
    continue
  fi

  # marker 同步。真源是「project 目录里最后被写入的 .jsonl」，不是别的：
  #
  #  ✗ marker 文件本身 —— 它由「最后一个**退出**的对话」写入。同一 session 目录下
  #    有并发对话时，先退出的那个会把 marker 覆盖成自己，活跃对话反而丢失。
  #    2026-09-03 Workspace 就这样被一个并发对话把 marker 写成了 9aefee8f。
  #  ✗ 进程命令行的 --resume —— 那是**启动时**的值。session 中途 /clear、/compact
  #    或 smart-resume 的 fork 都会产生新对话 ID，命令行却永远不变。实测 Workspace
  #    启动参数是 e8551729，而当时真正在写的已经是 f5c64b78。
  #  ✓ 最新 mtime 的 jsonl —— 用户最后说话的那个对话，一定是最后被写入的那个文件。
  #
  # project 目录名是会话路径把 / . 空格 全部换成 -，如
  # "/Users/kan.lu/claude-sessions/API Platform" → "-Users-kan-lu-claude-sessions-API-Platform"
  if [ "$sess" = "Personal" ]; then proj_base="$HOME/.claude-private/projects"
  else proj_base="$HOME/.claude/projects"; fi
  proj_slug=$(echo "$HOME/claude-sessions/$sess" | sed 's|[/. ]|-|g')
  newest_jsonl=$(ls -t "$proj_base/$proj_slug"/*.jsonl 2>/dev/null | head -1)
  if [ -n "$newest_jsonl" ]; then
    live_uuid=$(basename "$newest_jsonl" .jsonl)
  else
    # 兜底：project 目录还不存在（全新 session）时退回启动参数
    live_uuid=$(ps -o command= -p "$pid" 2>/dev/null | tr '\n' ' ' \
                | grep -oE '\-\-resume [0-9a-f-]{36}' | awk '{print $2}')
  fi
  marker_file="$HOME/claude-sessions/$sess/.current-session"
  if [ -n "$live_uuid" ] && [ "$live_uuid" != "$(cat "$marker_file" 2>/dev/null | tr -d '[:space:]')" ]; then
    echo "$live_uuid" > "$marker_file"
    log "   $sess — marker 已同步为 $live_uuid"
  fi

  log "▶  $sess — 重启中 (pid=$pid)"
  kill -TERM "$pid" 2>/dev/null
  for i in $(seq 1 "$KILL_WAIT"); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  if kill -0 "$pid" 2>/dev/null; then
    log "❌ $sess — ${KILL_WAIT}s 未退出，放弃（不强杀，避免留下半死状态）"
    FAILED+=("$sess(未退出)")
    continue
  fi
  # 等 pane 真的回落到 shell 再发命令。
  #
  # ⚠️ 这里原本是固定的 `sleep 3`，赌 happy 包装层会在 claude.exe 死后 3 秒内退出。
  # 2026-10-20 04:02 赌输了一次：Product priorities 的 transcript 有 128MB（全机最大），
  # happy 收尾（SESSION_SCANNER 全量重读 + 上报）慢，claude.exe 死后它又活了约 5 秒。
  # send-keys 在 04:02:02 发出，happy 04:02:03 才退出 —— 命令被还活着的 TUI 吃掉，
  # pane 随后回落到 shell 但命令已经丢了，该会话空置了 7.5 小时直到人工发现。
  # kill 的是 claude.exe（build_claude_map 只找这个），happy 是否跟着退出不受我们控制，
  # 所以只能等 pane_current_command 变回 shell，不能靠猜时间。
  for i in $(seq 1 "$SHELL_WAIT"); do
    cur=$("$TMUX_BIN" display-message -p -t "$sess" '#{pane_current_command}' 2>/dev/null)
    case "$cur" in zsh|-zsh|bash|-bash|sh|login) break ;; esac
    sleep 1
  done
  if [ "$i" -ge "$SHELL_WAIT" ]; then
    log "⚠ $sess — ${SHELL_WAIT}s 后 pane 仍是 '$cur'，send-keys 可能被 TUI 吃掉"
  fi

  # Personal 的对话在 ~/.claude-private/projects/，不带这个变量会去默认目录找，
  # 报 No conversation found 后重试 5 次放弃。
  extra=""
  [ "$sess" = "Personal" ] && extra="CLAUDE_CONFIG_DIR=$HOME/.claude-private "
  "$TMUX_BIN" send-keys -t "$sess" "${extra}$SMART_RESUME '$sess'" Enter

  # 验证真的起来了。BOOT_WAIT=30 对正常启动绰绰有余（376 次历史重启：中位 7s、
  # p90 8s、最大 16s、超过 20s 的 0 次），所以超时基本等于「命令压根没送达」，
  # 而不是「启动慢」—— 这种情况重发一次就能救回来，比留个空会话到天亮划算。
  ok=0
  for attempt in 1 2; do
    for i in $(seq 1 "$BOOT_WAIT"); do
      sleep 1
      build_claude_map
      newpid=$(find_claude_pid "$sess")
      if [ -n "$newpid" ] && [ "$newpid" != "$pid" ]; then ok=1; break; fi
    done
    [ $ok = 1 ] && break
    if [ "$attempt" = 1 ]; then
      log "⚠ $sess — ${BOOT_WAIT}s 内没起来，重发一次 smart-resume"
      "$TMUX_BIN" send-keys -t "$sess" "${extra}$SMART_RESUME '$sess'" Enter
    fi
  done
  if [ $ok = 1 ]; then
    log "✅ $sess — 已起来 (pid=$newpid)"
    RESTARTED+=("$sess")
  else
    log "❌ $sess — 重发后仍未启动（共等 $((BOOT_WAIT * 2))s）"
    FAILED+=("$sess(未启动)")
  fi
done < <("$TMUX_BIN" list-sessions -F '#{session_name}' 2>/dev/null | sort)

# ── 汇总 ──────────────────────────────────────────────────────────────────
join() { local IFS=', '; echo "$*"; }
SUMMARY="🌙 Claude 夜间升级 $(date '+%m-%d %H:%M')
$UPGRADE_MSG"
[ ${#RESTARTED[@]}       -gt 0 ] && SUMMARY="$SUMMARY
✅ 已重启(${#RESTARTED[@]}): $(join "${RESTARTED[@]}")"
[ ${#SKIPPED_CURRENT[@]} -gt 0 ] && SUMMARY="$SUMMARY
⏭ 已是新版(${#SKIPPED_CURRENT[@]})"
[ ${#REMOTE[@]}          -gt 0 ] && SUMMARY="$SUMMARY
📱 远程模式(${#REMOTE[@]}): $(join "${REMOTE[@]}")"
[ ${#SKIPPED_BUSY[@]}    -gt 0 ] && SUMMARY="$SUMMARY
⏸ 忙碌跳过(${#SKIPPED_BUSY[@]}): $(join "${SKIPPED_BUSY[@]}")"
[ ${#SKIPPED_AGENT[@]}   -gt 0 ] && SUMMARY="$SUMMARY
⏸ 后台agent跳过(${#SKIPPED_AGENT[@]}): $(join "${SKIPPED_AGENT[@]}")"
[ ${#FAILED[@]}          -gt 0 ] && SUMMARY="$SUMMARY
🔴 失败(${#FAILED[@]}): $(join "${FAILED[@]}")"

log "$SUMMARY"

# 只在「有实际动作」或「出错」时打扰；全都已是新版的平静夜晚不发通知。
if [ $DRY_RUN = 0 ]; then
  if [ ${#RESTARTED[@]} -gt 0 ] || [ ${#FAILED[@]} -gt 0 ] \
     || [ ${#SKIPPED_BUSY[@]} -gt 0 ] || [ ${#SKIPPED_AGENT[@]} -gt 0 ]; then
    notify "$SUMMARY"
  fi
fi

# ── 闸失效自检 ────────────────────────────────────────────────────────────
# 这三道闸是「不触发才正常」的那类逻辑，坏掉的时候**毫无症状**——
# 2026-09-11 到 10-19 它们 0/365 静默失效了 38 天，直到真把 Infra 的工作流杀了
# 才被发现。所以在这里反过来监控：重启攒够 60 次而一次都没跳过，就提醒复测。
# 判据本身没法自动验证，这行提醒的作用是触发人去做一次「1 跑 3 闲」的对照实验。
if [ $DRY_RUN = 0 ] && [ ${#RESTARTED[@]} -gt 0 ]; then
  gate_restarts=$(grep -c '已起来 (pid=' "$LOG_FILE" 2>/dev/null) || gate_restarts=0
  gate_skips=$(grep -c '⏭ .* 跳过' "$LOG_FILE" 2>/dev/null) || gate_skips=0
  if [ "$gate_restarts" -ge 60 ] && [ "$gate_skips" -eq 0 ]; then
    log "⚠ 闸失效自检：累计 ${gate_restarts} 次重启、0 次跳过，闸可能又对不上 UI 了"
    notify "⚠️ nightly 安全闸可能已失效：累计 ${gate_restarts} 次重启但 0 次跳过。
请做一次对照实验复测 pattern（1 个正在跑 agent 的 pane + 3 个空闲 pane），
方法见 claude-nightly-upgrade.sh 里三道闸上方的注释。"
  fi
fi

log "═══════ 结束 ═══════"
rm -f /tmp/cnu-pidppid.txt /tmp/cnu-panes.txt /tmp/cnu-claudepids.txt /tmp/cnu-map.txt
exit 0
