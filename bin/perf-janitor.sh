#!/bin/bash
# perf-janitor.sh — 资源回收守护脚本
# 由 launchd com.kanlu.perf-janitor 每天 03:17 (UTC+8) 触发
set -uo pipefail

TMUX=/opt/homebrew/bin/tmux
PROJ="$HOME/.claude/projects"
LOG="$HOME/Library/Logs/perf-janitor.log"
IDLE_HOURS=168         # session 闲置多久后回收（7 天）
KEEP_DAYS=7            # tool-results / subagents 保留天数

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

log "=== janitor start ==="

# ---------- 1. 回收闲置 session ----------
NOW=$(date +%s)
"$TMUX" list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r s; do
  dir=$(echo "$s" | tr ' ' '-')
  d="$PROJ/-Users-kan-lu-claude-sessions-$dir"
  latest=$(ls -t "$d"/*.jsonl 2>/dev/null | head -1)
  [ -z "$latest" ] && continue
  m=$(stat -f %m "$latest" 2>/dev/null) || continue
  h=$(( (NOW - m) / 3600 ))
  if [ "$h" -ge "$IDLE_HOURS" ]; then
    # 确认 pane 下没有活跃子进程（避免误杀正在跑的任务）
    pp=$("$TMUX" list-panes -t "$s" -F '#{pane_pid}' 2>/dev/null | head -1)
    n=$(ps -eo pid=,ppid= | awk -v root="$pp" '{pid[$1]=$2} END{n=1;q[1]=root;seen[root]=1;c=0;for(i=1;i<=n;i++){for(p in pid){if(pid[p]==q[i]&&!seen[p]){seen[p]=1;q[++n]=p;c++}}} print c}')
    if [ "${n:-0}" -le 2 ]; then
      "$TMUX" kill-session -t "$s" 2>/dev/null && log "killed idle session: $s (${h}h, ${n} procs)"
    else
      log "skip active session: $s (${h}h, ${n} procs)"
    fi
  fi
done

# ---------- 2. 清理 tool-results / subagents ----------
n1=$(find "$PROJ"/-Users-kan-lu-*/*/tool-results -type f -mtime +$KEEP_DAYS 2>/dev/null | wc -l | tr -d ' ')
find "$PROJ"/-Users-kan-lu-*/*/tool-results -type f -mtime +$KEEP_DAYS -delete 2>/dev/null
n2=$(find "$PROJ"/-Users-kan-lu-*/*/subagents -type f -mtime +$KEEP_DAYS 2>/dev/null | wc -l | tr -d ' ')
find "$PROJ"/-Users-kan-lu-*/*/subagents -type f -mtime +$KEEP_DAYS -delete 2>/dev/null
log "cleaned tool-results: $n1 files, subagents: $n2 files"

# ---------- 3. 回收 MCP 孤儿进程 ----------
orphans=0
for pid in $(ps -eo pid=,ppid=,command= | awk '$2==1 && /mcp/ && !/perf-janitor/ {print $1}'); do
  kill -9 "$pid" 2>/dev/null && orphans=$((orphans+1))
done
log "killed $orphans orphan MCP processes"

# ---------- 4. playwright 缓存上限 ----------
for c in ms-playwright ms-playwright-mcp; do
  p="$HOME/Library/Caches/$c"
  [ -d "$p" ] || continue
  sz=$(du -sm "$p" 2>/dev/null | awk '{print $1}')
  if [ "${sz:-0}" -gt 4096 ]; then
    rm -rf "$p" && log "purged $c cache (${sz}MB)"
  fi
done

# ---------- 5. 内存告警 ----------
free_gb=$(vm_stat | awk '/Pages free/{gsub(/\./,"",$3); printf "%.1f", $3*16384/1073741824}')
swap_used=$(sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/')
log "memory: free=${free_gb}GB swap_used=${swap_used}M"
if (( $(echo "$free_gb < 2" | bc -l) )); then
  log "WARN: low memory (${free_gb}GB free)"
fi

log "=== janitor done ==="
