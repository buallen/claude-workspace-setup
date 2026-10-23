#!/usr/bin/env python3
"""SessionStart hook: keep ~/claude-sessions/<name>/.current-session on the
conversation the session's main Claude is actually in.

Claude Code fires SessionStart on startup, --resume, /clear and /compact, so
this is the one place that sees every change of conversation id. Readers
(smart-resume.sh, sessionctl) only read the marker.

Only the session's main conversation may write it. Measured on 2026-10-23:
the hook's parent process is the Claude that fired it; `claude -p` has no tty.
Skipped:
  - cwd is not exactly ~/claude-sessions/<name>
  - SESSION_MARKER_SKIP=1 (smart-resume's bg-lock fork)
  - transcript is not in this session's project dir (wrong config root)
  - the Claude is not a descendant of the happy wrapper in the session's tmux
    pane (forks, bg-agent jobs, cron `claude -p` in the same directory); for
    panes without happy, a Claude in the pane that is not `-p/--print`
  - the session id belongs to a bg-agent job
Never blocks the session: any error exits 0.
"""
import json
import os
from pathlib import Path
import sys
import time

sys.path.insert(0, str(Path(os.path.realpath(__file__)).parent.parent / "lib"))
LOG = Path.home() / "Library" / "Logs" / "session-marker.log"


def decide(payload, claude_pid, env, sl):
    """Return (name, uuid) to write, or (None, reason)."""
    cwd = payload.get("cwd") or ""
    uuid = payload.get("session_id") or ""
    name = sl.name_from_cwd(cwd)
    if not name:
        return None, "not a session directory"
    if env.get("SESSION_MARKER_SKIP") == "1":
        return None, "SESSION_MARKER_SKIP"
    if not sl.UUID_RE.fullmatch(uuid):
        return None, "no session id"
    transcript = os.path.realpath(payload.get("transcript_path") or "/")
    if os.path.dirname(transcript) != os.path.realpath(sl.project_dir(name)):
        return None, f"transcript outside {name}'s project dir"
    table = sl.process_table()
    procs = sl.session_procs(name, table)
    if procs is None:
        return None, "no tmux session"
    if procs.happy:
        main = {pid for wrapper in procs.happy for pid in sl.descendants(table, wrapper)}
        if claude_pid not in main:
            return None, "not under the session's happy wrapper"
    else:
        command = table.get(claude_pid, (0, ""))[1]
        in_pane = claude_pid in sl.descendants(table, procs.pane_pid)
        if not in_pane or " -p " in f" {command} " or "--print" in command:
            return None, "not the pane's interactive claude"
    if uuid in sl.background_job_ids(name):
        return None, "bg-agent job"
    return name, uuid


def log(line):
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        with LOG.open("a") as stream:
            stream.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n")
    except OSError:
        pass


def main():
    try:
        payload = json.load(sys.stdin)
        import sessionlib as sl
        name, value = decide(payload, os.getppid(), os.environ, sl)
        source = payload.get("source", "?")
        if name is None:
            if sl.name_from_cwd(payload.get("cwd") or ""):
                log(f"skip {payload.get('session_id', '?')[:8]} ({source}): {value}")
            return
        if sl.read_marker(name) != value:
            sl.write_marker(name, value)
            log(f"{name}: marker -> {value} ({source})")
        else:
            log(f"{name}: marker already {value[:8]} ({source})")
    except Exception as exc:  # never break session start
        log(f"error: {exc!r}")


if __name__ == "__main__":
    main()
    sys.exit(0)
