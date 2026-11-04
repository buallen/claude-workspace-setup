#!/bin/bash
# 磁盘清理 — 经三路对抗审查修正版（2026-08-11）
#
# 默认 DRY RUN，只打印将要做什么。加 --apply 才真正执行。
#   bash disk-cleanup-safe.sh          # 预演
#   bash disk-cleanup-safe.sh --apply  # 真删
#   bash disk-cleanup-safe.sh --apply 3   # 只跑第 3 段
#
# 已被对抗审查否决、故意不在本脚本内的项目见文件末尾注释。

set -uo pipefail

# yarn/pnpm 装在 nvm 的 node 目录下，launchd 的 PATH 里没有它们，
# 段 3 会报 command not found 而跳过最大的两块缓存（2026-10-13 实测 Yarn 5.7G）。
export PATH="$HOME/.nvm/versions/node/v22.22.0/bin:$PATH"

# launchd 跑本脚本时 cwd 是 `/`，而 `/` 在 macOS 上是只读系统卷。pnpm 没配
# store-dir 时按 cwd 解析存储位置，于是往 `/` 写临时文件、报
# `EROFS: read-only file system, open '/_tmp_...'`，段 3 的 pnpm 那行从加进来
# 起就没成功过一次（2026-11-04 翻日志才发现，当时手动跑 prune 清出 20G）。
# 这里 cd 回 HOME 只是兜底，段 3 另外显式传了 --store-dir。
cd "$HOME" || exit 1

APPLY=0
[ "${1:-}" = "--apply" ] && { APPLY=1; shift; }
ONLY="${1:-}"

CLONE_DIR="/private/var/folders/ch/x1jdfbrd1xsfgt37vh6snz9r0000gn/X/com.google.Chrome.code_sign_clone"

avail()  { df -g /System/Volumes/Data | awk 'NR==2{print $4}'; }
banner() { echo; echo "──── $* ────"; }
skip()   { [ -n "$ONLY" ] && [ "$ONLY" != "$1" ]; }

# 失败必须冒出来。原来的 run() 是裸 eval，不看退出码：pnpm 连续几个月每晚
# EROFS 失败，日志里有那一行，但脚本照样报“完成”，log-janitor 照样发
# 「🧹 已自动清理」。静默跳过比没清更糟 —— 它让人以为清过了。
FAILED=()
# 退出码要在 eval 后面直接接住。写成 `if eval ...; then return 0; fi` 再读 $?
# 拿到的是 if 语句自己的状态（失败分支里是 0），不是命令的。
run() {
  if [ "$APPLY" != 1 ]; then echo "  [预演] $*"; return 0; fi
  local rc=0
  eval "$@" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  # 全角字符不要紧跟变量展开：macOS 自带 bash 3.2 下会输出乱码。
  echo "  ✗ 失败 rc=${rc} : $*"
  FAILED+=("$*")
  return "$rc"
}

[ "$APPLY" = 0 ] && echo "*** DRY RUN — 不会删任何东西，加 --apply 才执行 ***"
START_AVAIL=$(avail)
echo "起始可用空间：${START_AVAIL}G"

# ═══════════════════════════════════════════════════════════
# 1. Chrome code_sign_clone —— 最大头
#    审查结论：仅 lsof 显示在用的那个必须保留；执行时实时查，不用静态名单；
#    跳过 15 分钟内新建的（可能是正在进行的更新）。
# ═══════════════════════════════════════════════════════════
skip 1 || {
banner "1. Chrome 闲置克隆"
if [ -d "$CLONE_DIR" ]; then
  # 全系统扫，直接 grep 整行 —— 不能用 awk 取字段：
  # 路径含空格（"Google Chrome.app.bundle/.../Google Chrome"），$NF 会被截断成 "Chrome"，
  # 导致正在使用的克隆被误判为可删。
  IN_USE=$(lsof 2>/dev/null | grep -oE 'code_sign_clone\.[A-Za-z0-9]+' | sort -u)
  echo "  实时 lsof — 正在使用（保留）：${IN_USE:-无}"

  # 熔断：查不到克隆引用时，必须确认 Chrome 真的在跑 /Applications 里的本体才放行。
  # （克隆与本体可能共享 inode，lsof 解析到哪条路径不固定，所以不能只看 lsof 有没有命中）
  if [ -z "$IN_USE" ] && pgrep -x "Google Chrome" >/dev/null; then
    CPID=$(pgrep -x "Google Chrome" | head -1)
    # 用 grep -c 而非 grep -q：-q 命中即退出会让上游 lsof 收到 SIGPIPE，
    # 在 set -o pipefail 下整条管道被判为失败，导致这里永远走 else 分支。
    HITS=$(lsof -p "$CPID" 2>/dev/null | awk '$4=="txt"' \
           | grep -c '/Applications/Google Chrome.app/')
    if [ "${HITS:-0}" -gt 0 ]; then
      echo "  ✓ Chrome (PID $CPID) 运行的是 /Applications 下的本体，克隆均无引用"
    else
      echo "  ✗ 中止：查不到克隆引用，也确认不了 Chrome 在跑本体，不能盲删"
      exit 1
    fi
  fi

  TOTAL=0; KEPT=0
  for c in $(ls "$CLONE_DIR" 2>/dev/null); do
    TOTAL=$((TOTAL+1))
    if [ -n "$IN_USE" ] && echo "$IN_USE" | grep -qx "$c"; then
      echo "  保留（进程占用）：$c"; KEPT=$((KEPT+1)); continue
    fi
    # 15 分钟内新建的跳过，避免撞上正在进行的更新
    if [ -n "$(find "$CLONE_DIR" -maxdepth 1 -name "$c" -mmin -15 2>/dev/null)" ]; then
      echo "  保留（15分钟内新建）：$c"; KEPT=$((KEPT+1)); continue
    fi
    run "rm -rf '$CLONE_DIR/$c'"
  done
  echo "  共 $TOTAL 个，保留 $KEPT 个，清理 $((TOTAL-KEPT)) 个"
else
  echo "  目录不存在，跳过"
fi
}

# ═══════════════════════════════════════════════════════════
# 2. gcloud 日志 —— 审查修正：用 SDK 自带 max_log_days，不用 disable_file_logging
#    （后者会丢失 HTTP trace / token 刷新细节，排障时要用到）
# ═══════════════════════════════════════════════════════════
skip 2 || {
banner "2. gcloud 日志"
GLOG="$HOME/.config/gcloud/logs"
if [ -d "$GLOG" ]; then
  echo "  当前：$(du -sm "$GLOG" 2>/dev/null | cut -f1)MB"
  # 按 mtime 而非日期字符串筛选，避开跨午夜长命令的竞态；删前查 lsof
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    if lsof +D "$d" >/dev/null 2>&1; then echo "  保留（有进程在写）：$(basename "$d")"; continue; fi
    run "rm -rf '$d'"
  done < <(find "$GLOG" -maxdepth 1 -type d -mtime +7 2>/dev/null)
  echo "  源头修复：保留 7 天自动轮转（SDK 内置机制，可用 gcloud config unset 撤销）"
  run "gcloud config set core/max_log_days 7"
fi
}

# ═══════════════════════════════════════════════════════════
# 3. 开发工具缓存 —— 全部经审查确认 SAFE
#    注意：ms-playwright 绝不触碰（浏览器本体；profile 目录是段 7，别混）
# ═══════════════════════════════════════════════════════════
skip 3 || {
banner "3. 开发工具缓存"
run "yarn cache clean"                    # 2.6G
# --store-dir 必须显式传：见文件头 cd 那段，不传就在 launchd 下 EROFS。
run "pnpm store prune --store-dir '$HOME/Library/pnpm/store'"   # 2026-11-04 实测 20G
run "go clean -modcache"                  # 944M，无 go 进程在跑
run "rm -rf ~/.bun/install/cache"         # 316M
run "npm cache clean --force"             # 47M
# 裸 brew cleanup 只删已装 formula 的旧版本，下载缓存原封不动（日志里刷满
# "Skipping X: most recent version not installed"）。-s --prune=all 才清缓存。
run "brew cleanup -s --prune=all"         # 2026-11-04 实测 1.3G
}

# ═══════════════════════════════════════════════════════════
# 4. nvm —— 审查修正：原计划 8 个版本里有 5 个被项目 .nvmrc 钉死
#    只删这 3 个确认无引用的
# ═══════════════════════════════════════════════════════════
skip 4 || {
banner "4. nvm 闲置版本（仅 3 个无 .nvmrc 引用的）"
export NVM_DIR="$HOME/.nvm"
for v in v20.20.2 v24.13.0 v24.15.0; do
  [ -d "$NVM_DIR/versions/node/$v" ] || { echo "  已不存在：$v"; continue; }
  run "rm -rf '$NVM_DIR/versions/node/$v'"
done
echo "  保留 v10.24.0/v14.21.3/v18.19.0/v20.14.0/v20.18.1（被项目 .nvmrc 引用）"
echo "  保留 v22.22.0（当前默认，16 个 launchd 任务硬编码依赖）"
}

# ═══════════════════════════════════════════════════════════
# 5. 一次性冗余文件 —— 逐个查明来源后确认安全
# ═══════════════════════════════════════════════════════════
skip 5 || {
banner "5. 一次性冗余文件"
# Android 模拟器镜像源包：内容已解压落地到 homebrew SDK，运行中的模拟器不依赖它
[ -f /private/tmp/sysimg.zip ] && run "rm -f /private/tmp/sysimg.zip"          # 1.4G
# GoogleUpdater 扩展下载缓存（非版本目录，Current 软链不受影响）
run "rm -rf ~/Library/Application\\ Support/Google/GoogleUpdater/crx_cache"    # 731M
# cloudflared 已滚动的旧日志，lsof 确认无进程占用，下次滚动本来也会覆盖
run "rm -f ~/.happy/cloudflared-ssh.log.old ~/.happy/cloudflared-happy.log.old" # 22M
# 【故意不清空废纸篓】2026-08-11 起 ~/.Trash 里放着 wechat-backup-20260608-1458（54G），
# 是 Kan 主动移进去观察一段时间的，清空 = 永久删除他还没决定的东西。
# 要清废纸篓请手动确认里面没有待观察的内容，别放进自动脚本。
echo "  跳过废纸篓（内含待观察的 wechat-backup-20260608-1458，54G）"
}

# ═══════════════════════════════════════════════════════════
# 6. Docker —— 审查修正：不用 image prune -a
#    （会删掉 3 个本地构建镜像，其中 partner-platform-api 源码本机都找不到）
# ═══════════════════════════════════════════════════════════
skip 6 || {
banner "6. Docker（仅 build cache 与 dangling 层）"
if docker info >/dev/null 2>&1; then
  run "docker builder prune -f"      # 526M，当前无进行中的 build
  run "docker image prune -f"        # 仅 dangling <none> 层，不带 -a
  echo "  保留 api-api / partner-platform-api / developer-platform-api-api（本地构建，删了拉不回来）"
else
  echo "  Docker 未运行，跳过"
fi
}

# ═══════════════════════════════════════════════════════════
# 7. playwright-mcp 的陈旧浏览器 profile
#    每次 MCP server 启动建一个 mcp-chrome-<hash>/，从不回收：2026-11-04 积了
#    12 个共 7.7G。里面只有浏览器 profile，cookie 本来就由
#    export-chrome-cookies.py 每次重新注入，丢了不影响既有流程。
#    ⚠️ 与 ~/Library/Caches/ms-playwright（浏览器本体，绝对禁区）只差一个后缀，
#    所以这里写死目录、只删 mcp-chrome-* 子项，不用通配父目录。
# ═══════════════════════════════════════════════════════════
skip 7 || {
banner "7. playwright-mcp 陈旧 profile（>5 天未用）"
PWMCP="$HOME/Library/Caches/ms-playwright-mcp"
if [ -d "$PWMCP" ]; then
  n=0
  for d in "$PWMCP"/mcp-chrome-*/; do
    [ -d "$d" ] || continue
    [ -n "$(find "$d" -maxdepth 0 -mtime -5 2>/dev/null)" ] && continue
    lsof +D "$d" >/dev/null 2>&1 && { echo "  保留（有进程占用）：$(basename "$d")"; continue; }
    echo "  $(du -sh "$d" 2>/dev/null | cut -f1)  $(basename "$d")"
    run "rm -rf '$d'"; n=$((n+1))
  done
  echo "  处理 $n 个"
else
  echo "  目录不存在，跳过"
fi
}

# ═══════════════════════════════════════════════════════════
# 8. 会话里的产物备份目录
#    排查过程落下的中间文件（CSV / 日志 / 镜像清单）。2026-11-04 GCP 会话的
#    artifacts-backup 一个目录 12G，全是 10-28~11-03 的排查残留。
#    只删按天命名的子项，不碰 artifacts-backup 本身，也不碰会话里别的目录。
# ═══════════════════════════════════════════════════════════
skip 8 || {
banner "8. 会话产物备份（>14 天）"
n=0
for dir in "$HOME"/claude-sessions/*/artifacts-backup; do
  [ -d "$dir" ] || continue
  while IFS= read -r item; do
    [ -z "$item" ] && continue
    echo "  $(du -sh "$item" 2>/dev/null | cut -f1)  ${item#"$HOME"/claude-sessions/}"
    run "rm -rf '$item'"; n=$((n+1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -mtime +14 2>/dev/null)
done
echo "  处理 $n 项"
}

banner "完成"
echo "可用空间：${START_AVAIL}G → $(avail)G"
[ "$APPLY" = 0 ] && echo "（这是预演，实际未删除任何文件）"
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "✗ ${#FAILED[@]} 条命令失败："
  printf '    %s\n' "${FAILED[@]}"
  exit 2
fi

# ═══════════════════════════════════════════════════════════
# 对抗审查后【故意排除】的项目及原因：
#
# · ~/.happy/logs PID 清理 —— 原逻辑从 "2026-08-03-...-pid-67176.log" 提取到的是
#   "2026" 而非 PID，实测 95/95 文件全被判为死进程，会删掉正在写入的当前会话日志。
#   且 ~/bin/log-janitor.sh 每小时已用 mtime+lsof 在管，无需重复实现。
#
# · ~/.npm/_npx (2.5G) —— 正被 3 个运行中的 MCP server 使用
#   (playwright-mcp / op-mcp / newrelic-mcp)，删后重启需联网重下。
#
# · Lark update/ (1.8G) —— 里面是完整已解压、版本与运行版本一致的 app bundle，
#   疑似更新收尾未执行。建议先让 Lark 完整重启一次自行消化，别直接 rm。
#
# · 腾讯会议 —— Caches+PerfData 实测约 0B，真正占 521M 的是 Global/
#   （本地数据库与配置，删了要重新登录、丢会议记录）。
#
# · Raycast Updates (133M) —— 是真实的 pending 更新 1.104.24，删了白下载一次。
#
# · Chrome OptGuideOnDeviceModel (4.0G) —— 未取得独立审查结论，且需退出 Chrome，
#   收益相对克隆目录微小，本轮不做。
#
# · mongodb-binaries (143M) —— 11 个项目的测试依赖，删后需联网重下，收益太小。
#
# · 废弃项目 node_modules —— "废弃"判断被推翻：salon-x、product-domain-svc、
#   Features/backoffice-v1-web 都有未推送的 commit（最后一个是今天刚提交的），
#   删 node_modules 本身安全但建议先 git push 备份，故不放进自动脚本。
#
# 【绝对禁区，任何情况下不碰】
#   ~/.claude*/projects/**/*.jsonl · ~/Library/Caches/ms-playwright
#   微信 xwechat_files · /private/var/vm/sleepimage
# ═══════════════════════════════════════════════════════════
