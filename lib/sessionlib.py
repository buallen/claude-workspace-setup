"""Single source of truth for claude-workspace sessions.

One rule each for: session name -> directory -> Claude project directory,
which processes belong to a session, what state it is in, and which
conversation it is on. sessionctl, the watchdog and the nightly upgrade use
this module instead of carrying their own copies (2026-10-23: there were four
"newest conversation" algorithms and three project-key rules).

Process layout of a running session (happy launcher):
    tmux pane shell -> smart-resume.sh -> node bin/happy ->
    node .../happy/dist/index.mjs (the "happy wrapper") ->
    node .../scripts/claude_local_launcher.cjs -> claude.exe -> tool shells
"""
from dataclasses import dataclass, field
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

from personal_history import is_effective_message

HOME = Path.home()
SESSION_ROOT = Path(os.environ.get("SESSION_ROOT", HOME / "claude-sessions"))
PRIVATE_SESSIONS = frozenset({"Personal"})
TMUX = shutil.which("tmux") or "/opt/homebrew/bin/tmux"

UUID_RE = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
HAPPY_WRAPPER_RE = re.compile(r"node_modules/happy(?:-coder)?/dist/index\.mjs")
LAUNCHER_RE = re.compile(r"node_modules/happy(?:-coder)?/scripts/claude_local_launcher\.cjs")
CLAUDE_RE = re.compile(r"claude\.exe(?:\s|$)|@anthropic-ai/claude-code/cli\.js")
TOOL_SHELL_RE = re.compile(r"^(?:/bin/)?(?:zsh|bash|sh) -c ")
RESUME_ARG_RE = re.compile(r"--(?:resume|session-id)[ =]([0-9a-f-]{36})")

# Same thresholds and pattern as tab-status-poller.py, so `sessionctl status`
# and the tab emoji agree.
JSONL_FRESH = 180
JOB_FRESH = 600
WORK_RE = re.compile(r"·\s*↑\s*[\d.]+k?\s*tokens|esc to interrupt|·\s*\d+\s*(shell|tool)\b")
SHELL_COMMANDS = frozenset({"zsh", "bash", "sh", "login", "-zsh"})


# ── names and paths ──────────────────────────────────────────────────────────

def session_dir(name):
    return SESSION_ROOT / name


def config_dir(name):
    return HOME / (".claude-private" if name in PRIVATE_SESSIONS else ".claude")


def project_key(path):
    # Claude Code (and happy's getProjectPath) replace every character that is
    # not a letter, digit or dash, including "." and "_".
    return re.sub(r"[^A-Za-z0-9-]", "-", str(path))


def project_dir(name):
    return config_dir(name) / "projects" / project_key(session_dir(name))


def marker_path(name):
    return session_dir(name) / ".current-session"


def name_from_cwd(cwd):
    """Session name if cwd is exactly ~/claude-sessions/<name>, else None."""
    try:
        real = Path(os.path.realpath(cwd))
    except (TypeError, ValueError):
        return None
    root = Path(os.path.realpath(SESSION_ROOT))
    if real.parent == root and not real.name.startswith(("_", ".")):
        return real.name
    return None


# ── tmux ─────────────────────────────────────────────────────────────────────

def tmux(*args):
    # Never let an inherited $TMUX point us at another server or socket.
    env = {k: v for k, v in os.environ.items() if k not in ("TMUX", "TMUX_PANE")}
    # Tests run against a private server so they never touch real sessions.
    socket = os.environ.get("SESSIONLIB_TMUX_SOCKET")
    prefix = [TMUX, "-L", socket] if socket else [TMUX]
    result = subprocess.run([*prefix, *args], capture_output=True, text=True, env=env)
    return result.returncode, result.stdout


def target(name):
    # "=" forces an exact match; without it tmux prefix-matches, so
    # "Product" would hit "Product priorities".
    return f"={name}:"


def list_sessions():
    code, out = tmux("list-sessions", "-F", "#{session_name}")
    return [line for line in out.splitlines() if line] if code == 0 else []


def pane(name):
    code, out = tmux("display-message", "-p", "-t", target(name),
                     "#{pane_pid}\t#{pane_tty}\t#{pane_current_command}")
    if code != 0 or not out.strip():
        return None
    pid, tty, command = out.rstrip("\n").split("\t")
    return {"pid": int(pid), "tty": tty, "command": command}


def pane_text(name, lines=30):
    code, out = tmux("capture-pane", "-p", "-t", target(name), "-S", f"-{lines}")
    return out if code == 0 else ""


# ── processes ────────────────────────────────────────────────────────────────

def process_table():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="],
                         capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) >= 2 and parts[0].isdigit() and parts[1].isdigit():
            table[int(parts[0])] = (int(parts[1]), parts[2] if len(parts) > 2 else "")
    return table


def descendants(table, root):
    children = {}
    for pid, (ppid, _) in table.items():
        children.setdefault(ppid, []).append(pid)
    found, stack = [], [root]
    while stack:
        pid = stack.pop()
        found.append(pid)
        stack.extend(children.get(pid, []))
    return found


def identity(pid):
    """(pid, start time, command) - stable across the life of one process.

    Compared again right before every signal so a reused pid is never hit.
    """
    out = subprocess.run(["ps", "-o", "lstart=,command=", "-p", str(pid)],
                         capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    # lstart is a fixed 24-character field, e.g. "Thu Oct 23 14:09:31 2026".
    return (pid, out[:24].strip(), out[24:].strip())


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


@dataclass
class SessionProcs:
    pane_pid: int = 0
    tty: str = ""
    pane_command: str = ""
    happy: list = field(default_factory=list)
    launcher: list = field(default_factory=list)
    claude: list = field(default_factory=list)
    tool_shells: list = field(default_factory=list)


def session_procs(name, table=None):
    info = pane(name)
    if info is None:
        return None
    table = table or process_table()
    procs = SessionProcs(info["pid"], info["tty"], info["command"])
    tree = descendants(table, info["pid"])
    for pid in tree:
        command = table.get(pid, (0, ""))[1]
        if HAPPY_WRAPPER_RE.search(command) and " daemon" not in command:
            procs.happy.append(pid)
        elif LAUNCHER_RE.search(command):
            procs.launcher.append(pid)
        elif CLAUDE_RE.search(command):
            procs.claude.append(pid)
    for claude in procs.claude:
        for pid in descendants(table, claude)[1:]:
            if TOOL_SHELL_RE.search(table.get(pid, (0, ""))[1]):
                procs.tool_shells.append(pid)
    return procs


# ── conversations ────────────────────────────────────────────────────────────

def happy_log(happy_pid):
    logs = sorted((HOME / ".happy/logs").glob(f"*-pid-{happy_pid}.log"),
                  key=lambda p: p.stat().st_mtime, reverse=True)
    return logs[0] if logs else None


def happy_conversation(happy_pid):
    """Conversation the happy wrapper is syncing right now.

    happy learns it from Claude's SessionStart hook, so it follows /clear,
    /compact and forks, unlike the --resume argument on the command line.
    """
    log = happy_log(happy_pid)
    if log is None:
        return None
    out = subprocess.run(["grep", "-a", "-o", r"\[SESSION_SCANNER\] New session: [0-9a-f-]\{36\}", str(log)],
                         capture_output=True, text=True).stdout.strip().splitlines()
    return out[-1].rsplit(" ", 1)[-1] if out else None


def conversation_file(name, uuid):
    return project_dir(name) / f"{uuid}.jsonl"


def read_marker(name):
    try:
        value = marker_path(name).read_text().strip()
    except (FileNotFoundError, NotADirectoryError):
        return None
    return value if UUID_RE.fullmatch(value) else None


def write_marker(name, uuid):
    """Atomic write; the only writer should be the SessionStart hook."""
    path = marker_path(name)
    tmp = path.with_name(f".current-session.{os.getpid()}.tmp")
    tmp.write_text(uuid + "\n")
    os.replace(tmp, path)


def background_job_ids(name):
    """Session ids of bg-agent jobs started from this session's directory."""
    ids = set()
    want = os.path.realpath(session_dir(name))
    for root in (HOME / ".claude", HOME / ".claude-private"):
        for state in (root / "jobs").glob("*/state.json"):
            try:
                data = json.loads(state.read_text())
            except (OSError, ValueError):
                continue
            if isinstance(data, dict) and os.path.realpath(data.get("cwd") or "/") == want:
                sid = str(data.get("sessionId", data.get("session_id", "")))
                if sid:
                    ids.add(sid)
    return ids


def has_effective_message(path, max_bytes=4 << 20):
    """True if the last max_bytes of a transcript hold a real user/assistant turn."""
    try:
        size = path.stat().st_size
        with path.open("rb") as stream:
            stream.seek(max(0, size - max_bytes))
            data = stream.read()
    except OSError:
        return False
    for line in data.splitlines():
        try:
            if is_effective_message(json.loads(line)):
                return True
        except (ValueError, UnicodeError):
            continue
    return False


def newest_conversation(name):
    """Fallback when nothing live says which conversation is current.

    Newest-by-mtime transcript that is not a bg-agent job and contains a real
    turn. Personal goes through personal_history, which ranks by message time.
    """
    if name in PRIVATE_SESSIONS:
        return None  # personal_history.py --launch selects it itself
    project = project_dir(name)
    if not project.is_dir():
        return None
    skip = background_job_ids(name)
    files = sorted(project.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    for path in files:
        if UUID_RE.fullmatch(path.stem) and path.stem not in skip and has_effective_message(path):
            return path.stem
    return None


def live_conversation(name, procs=None):
    """(uuid, source) for the conversation a session is on, best evidence first."""
    procs = procs if procs is not None else session_procs(name)
    if procs:
        for pid in procs.happy:
            uuid = happy_conversation(pid)
            if uuid:
                return uuid, "happy"
        table = process_table()
        for pid in procs.claude:
            match = RESUME_ARG_RE.search(table.get(pid, (0, ""))[1])
            if match:
                return match.group(1), "claude-args"
    uuid = read_marker(name)
    if uuid and conversation_file(name, uuid).exists():
        return uuid, "marker"
    uuid = newest_conversation(name)
    return (uuid, "newest") if uuid else (None, None)


# ── state ────────────────────────────────────────────────────────────────────

def background_active(name):
    want = os.path.realpath(session_dir(name))
    now = time.time()
    for root in (HOME / ".claude", HOME / ".claude-private"):
        for state in (root / "jobs").glob("*/state.json"):
            try:
                data = json.loads(state.read_text())
                age = now - state.stat().st_mtime
            except (OSError, ValueError):
                continue
            if (isinstance(data, dict) and data.get("state") == "working" and age < JOB_FRESH
                    and os.path.realpath(data.get("cwd") or "/") == want):
                return True
    return False


def hook_status(name):
    try:
        return (HOME / ".claude" / f"tab-status-{name}").read_text().strip()
    except OSError:
        return ""


def session_state(name, procs=None):
    """{'state': stopped|busy|background|waiting|idle, 'reasons': [...], 'idle_since': epoch|None}"""
    procs = procs if procs is not None else session_procs(name)
    if procs is None:
        return {"state": "missing", "reasons": ["no tmux session"], "idle_since": None}
    uuid, _ = live_conversation(name, procs)
    last_write = None
    if uuid:
        try:
            last_write = conversation_file(name, uuid).stat().st_mtime
        except OSError:
            pass
    if not procs.happy and not procs.claude:
        return {"state": "stopped", "reasons": ["no happy/claude process"], "idle_since": last_write}
    reasons = []
    if procs.tool_shells:
        reasons.append(f"{len(procs.tool_shells)} tool command(s) running")
    if last_write and time.time() - last_write < JSONL_FRESH:
        reasons.append("conversation written in the last 3 min")
    if WORK_RE.search(pane_text(name)):
        reasons.append("working indicator on screen")
    if reasons:
        return {"state": "busy", "reasons": reasons, "idle_since": None}
    if background_active(name):
        return {"state": "background", "reasons": ["bg-agent job working"], "idle_since": None}
    if hook_status(name) in ("waiting", "thinking"):
        return {"state": "waiting", "reasons": ["waiting for input"], "idle_since": last_write}
    return {"state": "idle", "reasons": [], "idle_since": last_write}


# ── CLI for shell scripts (smart-resume.sh, hooks) ───────────────────────────

def resume_target(name):
    """Conversation to resume: the marker if its transcript still exists, else the newest real one.

    Read-only. The marker is written by the SessionStart hook, not by readers.
    """
    uuid = read_marker(name)
    if uuid and conversation_file(name, uuid).exists():
        return uuid
    return newest_conversation(name)


def _main(argv):
    if len(argv) == 3 and argv[1] == "project-dir":
        print(project_dir(argv[2]))
    elif len(argv) == 3 and argv[1] == "resume-target":
        print(resume_target(argv[2]) or "")
    elif len(argv) == 3 and argv[1] == "name-from-cwd":
        print(name_from_cwd(argv[2]) or "")
    else:
        print("usage: sessionlib.py project-dir|resume-target|name-from-cwd ARG", file=__import__("sys").stderr)
        return 2
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(_main(sys.argv))
