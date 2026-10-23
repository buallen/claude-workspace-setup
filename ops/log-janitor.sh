#!/bin/bash
# log-janitor.sh — 定时任务日志轮转 + 磁盘水位守卫
#
# 存在的理由：2026-07-30 nightly-distill.sh 里一行 `cat X >> X`（把文件追加到
# 自己身上）把 /tmp 写到 98GB、磁盘只剩 13GB，连带 distiller 自己因
# "No space left on device" 失败。那行已修，但没有任何机制会在下一次失控时拦住它。
# 这个脚本就是那道防线：单纯截断超限日志，并在磁盘吃紧时告警。
#
# launchd: ~/Library/LaunchAgents/com.kanlu.log-janitor.plist（每小时）

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="${HOME:-$(echo ~)}"
export TZ="Asia/Singapore"

LARK_CLI="/opt/homebrew/bin/lark-cli"
# Lark 收件人放在不进仓库的本地配置里（仓库公开）；没配就只记日志不发通知
[ -f "$HOME/.config/claude-workspace/local.env" ] && . "$HOME/.config/claude-workspace/local.env"
KAN_OPEN_ID="${LARK_NOTIFY_USER_ID:-}"
STATE_FILE="$HOME/.claude/log-janitor-state.json"
LOG_FILE="/tmp/log-janitor.log"

MAX_LOG_MB=50           # 单个日志超过这个大小就截断，只留尾部
KEEP_TAIL_MB=5          # 截断后保留的尾部大小
RUNAWAY_MB=500          # 超过这个就是失控，除截断外还要告警
DISK_WARN_PCT=85        # 磁盘使用率告警线（只告警，不动手）
DISK_CRIT_PCT=90        # 超过这个自动跑 disk-cleanup-safe.sh 的安全段
MEM_FREE_WARN_PCT=15    # 空闲内存低于这个百分比时告警并列出静置 session
ROLLING_KEEP_DAYS=14    # 按 PID/时间戳滚动的一次性日志保留天数
KEEP_SNAPSHOTS=7        # 全量快照类目录保留最近几份
APP_LOG_KEEP_DAYS=3     # 第三方 App 滚动日志保留天数

# 每次运行生成新文件、永不复用的日志目录（happy 按 PID 命名，一天几十个）。
# 这类目录截断没意义——文件本身不再被写入，只能按龄删。
ROLLING_LOG_DIRS=(
  "$HOME/.happy/logs"
)

# 每天全量复制一份的快照目录：内容几乎不变，只有份数在涨。
# skill-dream.py 每晚 23:30 把整个 skills 树抄一份（9MB），50 天攒了 40 份 342MB，
# 而最老那份和最新那份只差 2 个文件——99% 是同一份内容复制了 40 遍。
# 按龄删没用（每份都"新"过一次），只能按份数留最近 N 份。
SNAPSHOT_DIRS=(
  "$HOME/.claude/skill-backups"
  "$HOME/.claude/playbook-backups"
  "$HOME/.claude/memory-backups"
)

# 第三方 App 自己的滚动日志：自带保留策略但上限定得离谱或干脆没有。
# Lark xlog 日增 86MB（比上面所有快照加起来还多），微信 log 日增 ~24MB。
# 这些目录不归我们写，只按龄删已经写完的旧文件，当天的一律不碰。
APP_LOG_DIRS=(
  "$HOME/Library/Application Support/LarkInternational/sdk_storage/log/xlog"
  "$HOME/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/log"
)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }

notify() {
  [ -x "$LARK_CLI" ] || return 0
  "$LARK_CLI" im +messages-send --as user --user-id "$KAN_OPEN_ID" --text "$1" >/dev/null 2>&1
}

# 收集所有受管日志：launchd 声明的 + 已知的定时任务日志目录
collect_logs() {
  for f in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$f" ] || continue
    for k in StandardOutPath StandardErrorPath; do
      /usr/libexec/PlistBuddy -c "Print :$k" "$f" 2>/dev/null
    done
  done
  # 定时任务自己写的 .err/.log（不经 launchd 声明）
  ls -1 /tmp/distill-*.err /tmp/research-*.err /tmp/team-learn-*.err \
        /tmp/*-cron.log /tmp/daily-status-submit.log 2>/dev/null
  ls -1 "$HOME"/claude-sessions/AgentOrg/logs/*.log \
        "$HOME"/bin/lark-alert-rca/logs/*.log 2>/dev/null
}

truncated=0
runaway_report=""

while IFS= read -r path; do
  [ -n "$path" ] && [ -f "$path" ] || continue
  size=$(stat -f%z "$path" 2>/dev/null || echo 0)
  size_mb=$(( size / 1048576 ))
  [ "$size_mb" -lt "$MAX_LOG_MB" ] && continue

  # 原地截断：保留尾部，inode 不变，正在写它的进程不受影响
  tmp=$(mktemp) || continue
  tail -c $(( KEEP_TAIL_MB * 1048576 )) "$path" > "$tmp" 2>/dev/null
  cat "$tmp" > "$path" 2>/dev/null && truncated=$(( truncated + 1 ))
  rm -f "$tmp"
  log "truncated $path (${size_mb}MB -> ${KEEP_TAIL_MB}MB)"

  if [ "$size_mb" -ge "$RUNAWAY_MB" ]; then
    runaway_report="${runaway_report}
- ${path} 曾涨到 ${size_mb}MB"
  fi
done < <(collect_logs | sort -u)

# 滚动日志目录：按龄删除。这类文件写完就不再被碰，截断救不了空间。
rolling_freed_mb=0
for dir in "${ROLLING_LOG_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  before_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
  # 只删普通文件，且只删够老的；正在被写的当天日志不受影响
  find "$dir" -maxdepth 1 -type f -name "*.log" -mtime +${ROLLING_KEEP_DAYS} -delete 2>/dev/null
  # 保留窗口内也可能有几百 MB 的单文件（happy 单次会话就能写 655MB）。
  # 这些属于已退出进程的历史日志，截断保留尾部即可，不必整份留着。
  while IFS= read -r big; do
    [ -n "$big" ] || continue
    lsof "$big" >/dev/null 2>&1 && continue   # 仍被进程持有就不动
    tmp=$(mktemp) || continue
    tail -c $(( KEEP_TAIL_MB * 1048576 )) "$big" > "$tmp" 2>/dev/null
    cat "$tmp" > "$big" 2>/dev/null && log "truncated rolling $(basename "$big")"
    rm -f "$tmp"
  done < <(find "$dir" -maxdepth 1 -type f -name "*.log" -size +${MAX_LOG_MB}M 2>/dev/null)
  after_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
  freed=$(( (before_kb - after_kb) / 1024 ))
  if [ "$freed" -gt 0 ]; then
    rolling_freed_mb=$(( rolling_freed_mb + freed ))
    log "pruned $dir: freed ${freed}MB (kept last ${ROLLING_KEEP_DAYS}d)"
  fi
done

# 快照目录：留最近 KEEP_SNAPSHOTS 份，其余整份删。
# 只删名字像时间戳的目录（YYYYMMDD-HHMMSS，可带 manual- 前缀），
# 避免误伤将来可能出现的非快照子目录。按名字排序 = 按时间排序。
snapshot_freed_mb=0
for dir in "${SNAPSHOT_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  before_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
  snaps=()
  while IFS= read -r s; do snaps+=("$s"); done < <(
    find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
      | grep -E '/(manual-)?[0-9]{8}-[0-9]{6}$' \
      | sort
  )
  count=${#snaps[@]}
  [ "$count" -le "$KEEP_SNAPSHOTS" ] && continue
  drop=$(( count - KEEP_SNAPSHOTS ))
  for (( i=0; i<drop; i++ )); do
    rm -rf "${snaps[$i]}" 2>/dev/null
  done
  after_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
  freed=$(( (before_kb - after_kb) / 1024 ))
  snapshot_freed_mb=$(( snapshot_freed_mb + freed ))
  log "pruned $(basename "$dir"): 删除 ${drop} 份旧快照，保留最近 ${KEEP_SNAPSHOTS} 份，释放 ${freed}MB"
done

# 第三方 App 日志：按龄删，且跳过仍被进程打开的文件。
# 这些目录属于别的 App，只删它写完就不再碰的旧文件，绝不截断（截断可能破坏其索引）。
app_log_freed_mb=0
for dir in "${APP_LOG_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  before_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    lsof -- "$f" >/dev/null 2>&1 && continue   # App 还开着这个文件就别动
    rm -f "$f" 2>/dev/null
  done < <(find "$dir" -type f -mtime +${APP_LOG_KEEP_DAYS} 2>/dev/null)
  after_kb=$(du -sk "$dir" 2>/dev/null | cut -f1)
  freed=$(( (before_kb - after_kb) / 1024 ))
  if [ "$freed" -gt 0 ]; then
    app_log_freed_mb=$(( app_log_freed_mb + freed ))
    log "pruned $(basename "$dir"): 释放 ${freed}MB (保留最近 ${APP_LOG_KEEP_DAYS} 天)"
  fi
done

# 磁盘水位
# 必须读 /System/Volumes/Data（真正装数据的卷），不能读 /。
# macOS 从 Catalina 起把系统盘拆成只读系统卷 + 可写数据卷：`df /` 永远显示
# 13% 左右（那是只读系统卷），而数据卷早已 84%。2026-08-20 发现本行原写
# `df /`，导致 DISK_WARN_PCT=85 的告警从上线起一次都没触发过。
disk_pct=$(df /System/Volumes/Data | tail -1 | awk '{gsub("%","",$5); print $5}')
disk_avail=$(df -h /System/Volumes/Data | tail -1 | awk '{print $4}')

if [ -n "$runaway_report" ]; then
  notify "⚠️ log-janitor 发现日志失控增长
时间：$(date '+%Y-%m-%d %H:%M:%S %Z')
已自动截断（保留尾部 ${KEEP_TAIL_MB}MB）：${runaway_report}

磁盘：已用 ${disk_pct}%，可用 ${disk_avail}
建议检查对应脚本是否有循环写日志的逻辑。
日志：$LOG_FILE"
  log "runaway alert sent"
fi

if [ "${disk_pct:-0}" -ge "$DISK_WARN_PCT" ]; then
  # 同一天只告警一次，避免每小时刷屏
  today=$(date '+%Y-%m-%d')
  last=$(python3 -c "
import json
try: print(json.load(open('$STATE_FILE')).get('last_disk_alert',''))
except Exception: print('')
" 2>/dev/null)
  if [ "$last" != "$today" ]; then
    notify "🔴 磁盘空间告警
时间：$(date '+%Y-%m-%d %H:%M:%S %Z')
根分区已用 ${disk_pct}%，仅剩 ${disk_avail}
定时任务（尤其是写日志的）可能因 No space left on device 失败。"
    python3 -c "
import json, os
p = '$STATE_FILE'
try: d = json.load(open(p))
except Exception: d = {}
d['last_disk_alert'] = '$today'
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, 'w'), indent=2)
" 2>/dev/null
    log "disk alert sent (${disk_pct}%)"
  fi
fi

# 状态读写（沿用上面 last_disk_alert 的那个 STATE_FILE）
state_get() { python3 -c "
import json
try: print(json.load(open('$STATE_FILE')).get('$1',''))
except Exception: print('')
" 2>/dev/null; }
state_set() { python3 -c "
import json, os
p = '$STATE_FILE'
try: d = json.load(open(p))
except Exception: d = {}
d['$1'] = '$2'
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, 'w'), indent=2)
" 2>/dev/null; }

TODAY=$(date '+%Y-%m-%d')

# ── 磁盘临界线：自动清理 ──────────────────────────────────────
# 只跑 disk-cleanup-safe.sh 里「清掉还能自动再生」的三段：
#   2 = gcloud 日志、3 = 开发工具缓存、6 = Docker build cache
# 段 1（Chrome 克隆）不在这里，见下面的每日块。
# 故意不跑：4(nvm 版本) 5(一次性冗余)——都是跑一次就没了的，不该反复执行。
# 一天只跑一次：缓存清完会被构建重新填满，每小时清等于每小时重下依赖，
# 而且每次都发 Lark——2026-10-12~13 两天发了 19 条「90% → 90%」。
if [ "${disk_pct:-0}" -ge "$DISK_CRIT_PCT" ] && [ "$(state_get last_auto_cleanup)" != "$TODAY" ]; then
  state_set last_auto_cleanup "$TODAY"
  for seg in 2 3 6; do
    bash "$HOME/bin/disk-cleanup-safe.sh" --apply "$seg" >> "$LOG_FILE" 2>&1
  done
  after_pct=$(df /System/Volumes/Data | tail -1 | awk '{gsub("%","",$5); print $5}')
  after_avail=$(df -h /System/Volumes/Data | tail -1 | awk '{print $4}')
  notify "🧹 磁盘达 ${disk_pct}%，已自动清理
gcloud 日志 / 开发工具缓存 / Docker build cache
现在：${after_pct}%，可用 ${after_avail}
（nvm、一次性冗余需手动跑 disk-cleanup-safe.sh）"
  log "auto-cleanup at ${disk_pct}% -> ${after_pct}%"
fi

# ── 每日一次：Chrome code_sign_clone ──────────────────────────
# 不看水位：克隆每天都在长（2026-10-20 du 已到 164G），清掉不会像缓存那样
# 逼构建重下依赖，Chrome 需要时自己再克隆。du 严重虚报（与本体共享块），
# 真实回收量只能看 df 前后差（10-13 实测 7.0G）。熔断 exit 1 只结束子进程。
if [ "$(state_get last_chrome_clone_prune)" != "$TODAY" ]; then
  state_set last_chrome_clone_prune "$TODAY"
  before_g=$(df -g /System/Volumes/Data | awk 'NR==2{print $4}')
  bash "$HOME/bin/disk-cleanup-safe.sh" --apply 1 >> "$LOG_FILE" 2>&1
  after_g=$(df -g /System/Volumes/Data | awk 'NR==2{print $4}')
  log "chrome clone prune: avail ${before_g}G -> ${after_g}G"
fi

# ── 每日一次：Otty state.db 备份（保留 7 份）────────────────────
# Otty 的标签顺序只存在这里。2026-10-15 误杀把窗口全关了，标签顺序再也找不回来。
# 库在用（WAL 模式），用 sqlite3 .backup 取一致的快照，不要直接 cp。
OTTY_DB="$HOME/Library/Application Support/io.appmakes.otty/state.db"
if [ -f "$OTTY_DB" ] && [ "$(state_get last_otty_backup)" != "$TODAY" ]; then
  state_set last_otty_backup "$TODAY"
  otty_bak="$HOME/.claude/backups/otty"
  mkdir -p "$otty_bak"
  if /usr/bin/sqlite3 "$OTTY_DB" ".backup '$otty_bak/state-$TODAY.db'" 2>>"$LOG_FILE"; then
    ls -t "$otty_bak"/state-*.db 2>/dev/null | tail -n +8 | while IFS= read -r old; do rm -f "$old"; done
    log "otty state.db backed up"
  fi
fi

# ── 每日一次：长时间空闲会话提醒（只提醒，不自动停）──────────
# 自动休眠被否决：手机「恢复」已停的会话会起一个不在 tmux 里的无终端进程，
# 停机期间手机发的消息恢复时会被跳过。所以只列出来，由人决定。
SESSIONCTL="$HOME/.claude/claude-workspace/bin/sessionctl"
if [ -x "$SESSIONCTL" ] && [ "$(date +%H)" -ge 9 ] && [ "$(state_get last_idle_report)" != "$TODAY" ]; then
  state_set last_idle_report "$TODAY"
  idle_list=$("$SESSIONCTL" idle --hours 24 2>/dev/null | awk -F'\t' '{printf "• %s（%s，%s）\n", $1, $2, $3}')
  if [ -n "$idle_list" ]; then
    notify "💤 空闲超过 24 小时的会话（每个常驻约 0.5–1G 内存）：
${idle_list}
不用了可以 sessionctl stop \"<名字>\"，要用时 happy-session \"<名字>\" 续接原对话。"
    log "idle report: $(echo "$idle_list" | wc -l | tr -d ' ') session(s)"
  fi
fi

# ── 每日一次：happy 增量扫描补丁巡检 ──────────────────────────
# 补丁（ops/patch-happy-scanner-incremental.py，上游 PR slopus/happy#1915）会被
# `npm i -g happy` 覆盖。只在「还是原版整文件读取、且没有补丁标记」时告警，
# 这样上游修好发版后（代码已变）不会误报。
if [ "$(state_get last_happy_patch_check)" != "$TODAY" ]; then
  state_set last_happy_patch_check "$TODAY"
  for dist in "$HOME"/.nvm/versions/node/*/lib/node_modules/happy/dist/index-*.mjs; do
    [ -f "$dist" ] || continue
    if grep -q 'file = await readFile(expectedSessionFile, "utf-8")' "$dist" && ! grep -q '__scanCursors' "$dist"; then
      notify "⚠️ happy 的增量扫描补丁不在了（$(basename "$dist")，多半是升级过 happy）。
跑 python3 ~/bin/patch-happy-scanner-incremental.py，再逐个 sessionctl restart。
不补的话每个会话每 3 秒整文件重读对话记录，常年多吃几百 MB 和 20–50% CPU。"
      log "happy scanner patch missing in $dist"
    fi
  done
fi

# ── 每日一次：backups 保留期清理 ──────────────────────────────
# 本脚本每小时跑，用状态文件保证 prune 一天只跑一次。
if [ "$(state_get last_backup_prune)" != "$TODAY" ]; then
  bash "$HOME/bin/claude-backup-prune.sh" >> "$LOG_FILE" 2>&1
  state_set last_backup_prune "$TODAY"
  log "backup-prune ran"
fi

# ── 内存水位 ──────────────────────────────────────────────────
# 15 个常驻 session × 约 550MB(claude.exe + happy + MCP) 是内存的主要去处。
# 这里不自动 kill 任何 session（那是 Kan 的工作现场），只告警并列出静置最久的几个。
mem_free_pct=$(memory_pressure 2>/dev/null | awk '/free percentage/{print $NF}' | tr -d '%')
if [ -n "$mem_free_pct" ] && [ "$mem_free_pct" -lt "$MEM_FREE_WARN_PCT" ] \
   && [ "$(state_get last_mem_alert)" != "$TODAY" ]; then
  now=$(date +%s)
  idle_list=$(/opt/homebrew/bin/tmux list-sessions -F "#{session_activity}|#{session_name}" 2>/dev/null \
    | sort -n | head -5 \
    | while IFS='|' read -r ts name; do
        [ -n "$ts" ] || continue
        printf '  · %s（静置 %d 小时）\n' "$name" $(( (now - ts) / 3600 ))
      done)
  notify "🧠 内存告警：空闲仅 ${mem_free_pct}%
时间：$(date '+%Y-%m-%d %H:%M:%S %Z')
node 进程 $(ps -eo comm | grep -c node) 个

静置最久的 session（可考虑关掉释放约 550MB/个）：
${idle_list:-  （取不到 tmux 列表）}"
  state_set last_mem_alert "$TODAY"
  log "mem alert sent (${mem_free_pct}% free)"
fi

log "done: truncated=${truncated} pruned=${rolling_freed_mb}MB snapshots=${snapshot_freed_mb}MB applogs=${app_log_freed_mb}MB disk=${disk_pct}% avail=${disk_avail} memfree=${mem_free_pct:-?}%"

# 自己的日志也别长成灾
if [ -f "$LOG_FILE" ] && [ "$(stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 2097152 ]; then
  tail -c 524288 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
fi

exit 0
