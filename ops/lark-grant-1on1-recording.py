#!/usr/bin/env python3
"""
把 1:1 会议录制（妙记）的「可管理」权限自动授予对方。

为什么需要它：飞书的智能纪要和逐字稿会后会自动授权给参会人，但带原始录制视频的
妙记**不会** —— 需要所有者手动加协作者，或参会人主动申请。管理员后台里没有
「参会人默认可管理」这类开关（2026-10-28 查过帮助中心与 Admin Console 文档），
而每次例会都会生成一个新的妙记文件，所以一次性授权不管用。

档位说明：官方专用接口 `vc/v1/meetings/:id/recording/set_permission` 的权限枚举
只有「查看」一档，给不了可管理。走通用云文档协作者接口才行：
`POST /open-apis/drive/v1/permissions/<minute_token>/members?type=minutes`
配 `perm=full_access`。网上有「妙记不支持 full_access」的说法，2026-10-28 实测
推翻了 —— 真实调用返回 `code=0`、`perm_type=container`。

范围（故意收得很窄）：只处理「参会人去掉自己之后恰好等于 PEER 一个人」的会议，
且妙记所有者必须是自己。`full_access` 意味着对方能改这个文件的权限、能转发，
所以不对多人会议生效。

配置（放在 ~/.config/claude-workspace/local.env，不进 git）：
    LARK_SELF_OPEN_ID="ou_..."        # 自己
    LARK_1ON1_PEER_OPEN_ID="ou_..."   # 1:1 对方
    LARK_NOTIFY_USER_ID="ou_..."      # 失败时 Lark 通知给谁（可选）

授权时默认**通知对方**（飞书会给他一条「某某把妙记分享给你」的提示），这样他不用
盯着看什么时候能访问。`need_notification` 只在 user 身份下有效，正好这里就是。
不想打扰时加 --quiet。

用法：
    lark-grant-1on1-recording.py              正常执行（会通知对方）
    lark-grant-1on1-recording.py --dry-run    只报告会授权给谁，不真的调用
    lark-grant-1on1-recording.py --quiet      授权但不通知对方
    lark-grant-1on1-recording.py --hours 48   回看窗口（默认 12 小时）
"""
import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

CLI = "/opt/homebrew/bin/lark-cli"
STATE = os.path.expanduser("~/.claude/state/lark-1on1-grants.json")
LOG = os.path.expanduser("~/Library/Logs/lark-grant-1on1.log")
TZ = timezone(timedelta(hours=8))          # Asia/Singapore，全局时区规则
ENV_FILE = os.path.expanduser("~/.config/claude-workspace/local.env")


def log(msg):
    line = f"{datetime.now(TZ):%Y-%m-%d %H:%M:%S} {msg}"
    print(line)
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass


def load_env():
    """读 local.env 里的 KEY="value" 行。不用 source，省得把整个文件当 shell 执行。"""
    if not os.path.exists(ENV_FILE):
        return
    with open(ENV_FILE, encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if not raw or raw.startswith("#") or "=" not in raw:
                continue
            key, _, val = raw.partition("=")
            os.environ.setdefault(key.strip(), val.strip().strip('"').strip("'"))


def cli(*args, data=None):
    """跑一条 lark-cli，返回 (ok, payload)。成功判据用退出码，不用 code==0
    —— shortcut 返回 {ok:true,...} 信封，原生 resource 命令返回 {code:0,...}，
    两种格式混在一起，只有退出码是一致可靠的。"""
    argv = [CLI, *args, "--format", "json"]
    if data is not None:
        argv += ["--data", json.dumps(data)]
    env = {**os.environ,
           "LARKSUITE_CLI_NO_UPDATE_NOTIFIER": "1",
           "LARKSUITE_CLI_NO_SKILLS_NOTIFIER": "1"}
    p = subprocess.run(argv, capture_output=True, text=True, env=env, timeout=120)
    out = p.stdout.strip()
    # dry-run 和部分命令会在 JSON 前打进度行，从第一个 { 开始截
    brace = out.find("{")
    try:
        payload = json.loads(out[brace:]) if brace >= 0 else {}
    except json.JSONDecodeError:
        payload = {}
    if p.returncode != 0:
        err = payload.get("error") or p.stderr.strip()[:200]
        return False, err
    return True, payload.get("data", payload)


def notify(text):
    uid = os.environ.get("LARK_NOTIFY_USER_ID")
    if not uid:
        return
    cli("im", "+messages-send", "--as", "user", "--user-id", uid, "--text", text)


def read_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def write_state(state):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--hours", type=int, default=12,
                    help="回看多久内结束的会议（妙记生成有延迟，窗口要比间隔大）")
    ap.add_argument("--quiet", action="store_true",
                    help="授权时不通知对方（默认通知，让对方知道录制可看了）")
    args = ap.parse_args()

    load_env()
    me = os.environ.get("LARK_SELF_OPEN_ID")
    peer = os.environ.get("LARK_1ON1_PEER_OPEN_ID")
    if not me or not peer:
        log("✗ 缺少 LARK_SELF_OPEN_ID / LARK_1ON1_PEER_OPEN_ID，检查 local.env")
        return 1

    now = datetime.now(TZ)
    # 用 isoformat 而不是 strftime("%z")：CLI 只认带冒号的偏移（+08:00），
    # %z 输出的是 +0800，会被判成 cannot parse time。
    start = (now - timedelta(hours=args.hours)).isoformat(timespec="seconds")
    end = now.isoformat(timespec="seconds")

    ok, data = cli("vc", "+search", "--participant-ids", peer,
                   "--start", start, "--end", end)
    if not ok:
        log(f"✗ vc +search 失败: {data}")
        notify(f"🔴 1:1 录制授权失败：搜索会议出错\n{data}")
        return 1

    meetings = data.get("items", [])
    if not meetings:
        log(f"近 {args.hours}h 无相关会议")
        return 0

    state = read_state()
    granted = state.setdefault("granted", {})
    done, skipped, failed = [], [], []

    for m in meetings:
        mid = m.get("id")
        topic = (m.get("display_info") or "").split("\n")[0]
        if not mid:
            continue
        if mid in granted:
            skipped.append(f"{topic}（已处理过）")
            continue

        ok, rec = cli("vc", "+recording", "--meeting-ids", mid)
        recs = (rec or {}).get("recordings", []) if ok else []
        token = recs[0].get("minute_token") if recs else None
        if not token:
            skipped.append(f"{topic}（无录制或仍在生成）")
            continue

        # 只动自己拥有的妙记：非所有者没资格加协作者
        ok, mi = cli("minutes", "minutes", "get",
                     "--params", json.dumps({"minute_token": token}))
        owner = ((mi or {}).get("minute") or mi or {}).get("owner_id") if ok else None
        if owner != me:
            skipped.append(f"{topic}（录制属于他人，不处理）")
            continue

        # 参会人去掉自己后必须恰好只剩 peer 一人 —— full_access 不给多人会议
        ok, mg = cli("vc", "meeting", "get", "--params",
                     json.dumps({"meeting_id": mid, "with_participants": True}))
        if not ok:
            failed.append(f"{topic}（查参会人失败: {mg}）")
            continue
        parts = ((mg or {}).get("meeting") or {}).get("participants") or []
        others = {p.get("id") for p in parts if p.get("id") and p.get("id") != me}
        if others != {peer}:
            skipped.append(f"{topic}（参会人不是单一 1:1 对象: {len(others)} 人）")
            continue

        if args.dry_run:
            log(f"[dry-run] 会授予 full_access: {topic} → peer（token={token}）")
            done.append(topic)
            continue

        ok, res = cli("drive", "permission.members", "create",
                      "--params", json.dumps({
                          "token": token, "type": "minutes",
                          "need_notification": not args.quiet}),
                      "--yes",
                      data={"member_type": "openid", "member_id": peer,
                            "perm": "full_access", "type": "user"})
        if ok:
            granted[mid] = {"token": token, "topic": topic,
                            "at": int(time.time()), "perm": "full_access"}
            done.append(topic)
            log(f"✓ 已授予可管理: {topic}")
        else:
            failed.append(f"{topic}（{res}）")
            log(f"✗ 授权失败: {topic} — {res}")

    if not args.dry_run:
        write_state(state)

    for s in skipped:
        log(f"⏭ {s}")
    if failed:
        notify("🔴 1:1 录制自动授权失败：\n" + "\n".join(failed))
        return 1
    if done and not args.dry_run:
        log(f"本轮授权 {len(done)} 个")
    return 0


if __name__ == "__main__":
    sys.exit(main())
