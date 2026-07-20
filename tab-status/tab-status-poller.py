#!/usr/bin/env python3
"""tab-status-poller — level-triggered tmux tab emoji updater.

Edge-triggered hooks (tab-status.sh) can't keep the emoji correct for sessions
driven remotely (phone/agent-sdk) or by background jobs/workflows, because the
"started working" event (UserPromptSubmit) only fires for locally-typed prompts.
This poller reconciles every session's emoji from REAL activity each cycle:

  🔥  foreground working   — main loop actively producing (the live conversation
                              jsonl is fresh, or the pane shows a working line)
  🤖  background working    — main loop idle but a fresh `~/.claude/jobs` task
                              (cron / Ralph loop / workflow / bg-agent) is running
  🫵  waiting for input     — not working; last hook status was waiting/thinking
  💤  idle                  — not working; last hook status was idle/none

Division of labour: the poller OWNS the working overlay (🔥/🤖); the hook owns the
resting states (🫵/💤). When a session isn't working the poller only clears a
stale 🔥/🤖 it set earlier — it never clobbers a hook-managed 🫵/💤.

Cheap (one `ps` + a few stats/captures per cycle) and resilient (a bad cycle
never kills the loop).
"""
import os
import re
import sys
import json
import time
import glob
import subprocess

HOME = os.path.expanduser("~")
JOBS_DIRS = [os.path.join(HOME, ".claude/jobs"), os.path.join(HOME, ".claude-private/jobs")]
PROJ_DIRS = [os.path.join(HOME, ".claude/projects"), os.path.join(HOME, ".claude-private/projects")]
STATUS_PREFIX = os.path.join(HOME, ".claude", "tab-status-")

INTERVAL = 5         # seconds between state re-decides (ps/capture-pane cost lives here)
ANIM_TICK = 0.2      # seconds per spinner frame while working (≈ CC/Codex real spinner rate)
JSONL_FRESH = 180    # live conversation jsonl written within this → foreground working
JOB_FRESH = 600      # bg job state/jsonl touched within this → background working

# Indicators Claude Code shows ONLY while a turn is actively running. Kept tight
# on purpose: bare spinner glyphs / verb words also appear in the scrollback of
# COMPLETED turns and caused false "working" hits. These three only exist live:
#   "(2m 36s · ↑ 6.5k tokens)"  live progress line with token counter
#   "esc to interrupt"          interrupt hint shown during a live turn
#   "· 1 shell" / "· 2 tool"    footer count of currently-running shells/tools
WORK_RE = re.compile(r"·\s*↑\s*[\d.]+k?\s*tokens|esc to interrupt|·\s*\d+\s*(shell|tool)\b")

# uuid pulled from the actually-running process (resume/fork can make this differ
# from ~/claude-sessions/<name>/.current-session, so the process is the truth).
UUID_RE = re.compile(r"--(?:resume|session-id)\s+([0-9a-fA-F-]{36})")

ICONS = {"working": "🔥", "background": "🤖", "waiting": "🫵", "idle": "💤"}


def find_tmux():
    for p in ("/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"):
        if os.path.exists(p):
            return p
    return "tmux"


TMUX = find_tmux()


def tmux(*args):
    try:
        return subprocess.run([TMUX, *args], capture_output=True, text=True, timeout=8).stdout
    except Exception:
        return ""


def sessions():
    out = {}
    for ln in tmux("list-panes", "-a", "-F", "#{session_name}|#{pane_pid}").splitlines():
        if "|" in ln:
            s, p = ln.rsplit("|", 1)
            if p.strip().isdigit():
                out.setdefault(s, int(p))
    return out


def current_names():
    out = {}
    for ln in tmux("list-windows", "-a", "-F", "#{session_name}|#W").splitlines():
        if "|" in ln:
            s, w = ln.split("|", 1)
            out[s] = w
    return out


def proc_snapshot():
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="],
                         capture_output=True, text=True).stdout
    procs, children = {}, {}
    for ln in out.splitlines():
        parts = ln.strip().split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid, ppid = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        procs[pid] = parts[2] if len(parts) > 2 else ""
        children.setdefault(ppid, []).append(pid)
    return procs, children


def session_uuids(pane_pid, procs, children):
    uuids, stack = set(), [pane_pid]
    while stack:
        p = stack.pop()
        cmd = procs.get(p, "")
        if "claude" in cmd or "happy" in cmd:
            uuids.update(UUID_RE.findall(cmd))
        stack.extend(children.get(p, []))
    return uuids


def session_dir(name):
    return os.path.realpath(os.path.join(HOME, "claude-sessions", name))


# Backend markers, each borrowed from its own CLI's native spinner:
#   Claude → CC's spark frames (✢ ✳ ✻ ✽), resting on the iconic ✻
#   GPT    → Codex CLI's braille dots (⠋⠙⠹…), resting on the full cell ⠿
# While a session is working the poller advances one frame per cycle, so the
# tab prefix animates like the CLI's own thinking spinner.
SPARK_FRAMES = "✢✳✻✽"
BRAILLE_FRAMES = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
SPARK_REST = "✻"  # text glyph → renders in the tab text color (CC clay on the active tab)
BRAILLE_REST = "⠿"

# Statusline row Claude Code itself renders (via statusline-model.sh), e.g.
# "gpt-5.6-sol  📂 Infra" or "⚡ Sonnet 5  📂 CSP" — the 📂 marker anchors it.
STATUS_LINE_RE = re.compile(r"^.*📂.*$", re.MULTILINE)
_last_known_gpt = {}  # name -> bool, carried across cycles when statusline isn't visible


def session_is_gpt(name, pane_text=None):
    """Ground truth = what model the RUNNING session is actually reporting via its
    own statusline right now, not the `.backend` launch preference file.

    Why: since 2026-07-20 every session always routes through the local proxy
    (see project_universal_claudex_proxy memory), so `.backend` only means
    "preferred default at launch" — a session can end up actively running
    gpt-5.6-sol without `.backend=claudex` (e.g. a stale per-session model
    choice from before that resolves successfully now that the proxy is
    universal), and vice versa. `.backend` alone was proven wrong: sessions
    with no `.backend` file at all were observed actually running gpt-5.6-sol.
    """
    if pane_text is None:
        pane_text = tmux("capture-pane", "-t", name, "-p", "-S", "-30")
    m = STATUS_LINE_RE.findall(pane_text)
    if m:
        is_gpt = "gpt-5.6-sol" in m[-1].lower()
        _last_known_gpt[name] = is_gpt
        return is_gpt
    # Statusline not visible this cycle (e.g. "100% context used" replaced it,
    # or a menu is covering it) — keep the last real reading instead of
    # guessing, so the icon doesn't flicker back to the wrong default.
    if name in _last_known_gpt:
        return _last_known_gpt[name]
    # First-ever read for this session with nothing visible yet: fall back to
    # the launch preference as a last resort.
    try:
        b = open(os.path.join(HOME, "claude-sessions", name, ".backend")).read().strip()
    except Exception:
        return False
    return b == "claudex"


def backend_prefix(name, working, tick, pane_text=None):
    if session_is_gpt(name, pane_text):
        return (BRAILLE_FRAMES[tick % len(BRAILLE_FRAMES)] if working else BRAILLE_REST) + " "
    return (SPARK_FRAMES[tick % len(SPARK_FRAMES)] if working else SPARK_REST) + " "


def jsonl_fresh(name, uuids):
    """True if the session's LIVE conversation jsonl was written very recently.

    Uses the uuid the process is actually running (resume/fork safe), plus the
    recorded .current-session as a fallback.
    """
    cand = set(uuids)
    try:
        u = open(os.path.join(HOME, "claude-sessions", name, ".current-session")).read().strip()
        if u:
            cand.add(u)
    except Exception:
        pass
    now = time.time()
    for u in cand:
        for base in PROJ_DIRS:
            for f in glob.glob(os.path.join(base, "*", u + ".jsonl")):
                try:
                    if now - os.path.getmtime(f) < JSONL_FRESH:
                        return True
                except OSError:
                    continue
    return False


def pane_capture(name):
    return tmux("capture-pane", "-t", name, "-p", "-S", "-30")


def pane_working(pane_text):
    return bool(WORK_RE.search(pane_text))


def bg_working(name):
    """True if a fresh background job/agent/workflow is running for this session."""
    sdir = session_dir(name)
    now = time.time()
    for base in JOBS_DIRS:
        for sf in glob.glob(os.path.join(base, "*", "state.json")):
            try:
                st = json.load(open(sf))
            except Exception:
                continue
            if st.get("state") != "working":
                continue
            if os.path.realpath(st.get("cwd", "") or "/nope") != sdir:
                continue
            mt = os.path.getmtime(sf)
            jp = st.get("linkScanPath", "")
            if jp and os.path.exists(jp):
                try:
                    mt = max(mt, os.path.getmtime(jp))
                except OSError:
                    pass
            if now - mt < JOB_FRESH:
                return True
    return False


def last_hook_status(name):
    try:
        return open(STATUS_PREFIX + name).read().strip()
    except Exception:
        return "idle"


def decide(name, pane_pid, procs, children, pane_text):
    uuids = session_uuids(pane_pid, procs, children)
    if jsonl_fresh(name, uuids) or pane_working(pane_text):
        return "working"
    if bg_working(name):
        return "background"
    return "waiting" if last_hook_status(name) in ("waiting", "thinking") else "idle"


def cycle(dry=False, tick=0):
    animating = []
    names = current_names()
    procs, children = proc_snapshot()
    for name, pane_pid in sessions().items():
        pane_text = pane_capture(name)
        try:
            state = decide(name, pane_pid, procs, children, pane_text)
        except Exception:
            continue
        cur = names.get(name, "")
        cur_icon = next((c for c in cur if c in "🔥🤖🫵💤"), "")
        working = state in ("working", "background")
        prefix = backend_prefix(name, working, tick, pane_text)

        if working:
            target = ICONS[state]
        elif cur_icon in ("🔥", "🤖"):
            # was working, now resting → revert to the hook's last resting state
            target = ICONS["waiting"] if last_hook_status(name) in ("waiting", "thinking") else ICONS["idle"]
        else:
            # resting & hook-managed: keep the icon, but still fix a stale or
            # missing backend prefix (e.g. right after session-model switch)
            target = cur_icon or ICONS["idle"]

        desired = f"{prefix}{name} {target}"
        if working:
            animating.append((name, session_is_gpt(name, pane_text), target))
        if cur == desired:
            continue
        if dry:
            print(f"  {name:<22} {cur or '∅'} → {desired}   ({state})")
        else:
            tmux("rename-window", "-t", f"{name}:", desired)
    return animating


def main():
    dry = "--dry" in sys.argv
    if "--once" in sys.argv:
        cycle(dry=dry)
        return
    tick = 0
    steps = max(1, int(INTERVAL / ANIM_TICK))
    while True:
        try:
            animating = cycle(dry=False, tick=tick)
        except Exception:
            animating = []
        # 两次状态判定之间：只做轻量 rename，按 CC 速率逐帧轮转干活中的 tab
        for _ in range(steps):
            time.sleep(ANIM_TICK)
            tick += 1
            for name, is_gpt, icon in animating:
                frames = BRAILLE_FRAMES if is_gpt else SPARK_FRAMES
                tmux("rename-window", "-t", f"{name}:",
                     f"{frames[tick % len(frames)]} {name} {icon}")


if __name__ == "__main__":
    main()
