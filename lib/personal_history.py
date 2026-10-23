#!/usr/bin/env python3
"""Select or resume Personal history without reading the ordinary history root.

Selection is read-only: neither transcripts nor .current-session are rewritten.
Only --launch starts a client, with the private config and project made explicit.
"""
import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import re
import sys
import time


UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
WRAPPERS = (
    "<command-name>", "<command-message>", "<command-args>",
    "<local-command-stdout", "<local-command-stderr", "<local-command-caveat>",
    "<task-notification",
)


class PersonalHistoryError(Exception):
    pass


class ActiveLockError(Exception):
    pass


def checked_path(path, root):
    # Do not allow even a same-name root symlink to redefine the private boundary.
    if path.is_symlink() or not path.resolve().is_relative_to(root):
        raise PersonalHistoryError(f"refusing linked or cross-root data path: {path}")
    if path.exists() and path.is_file() and path.stat().st_nlink != 1:
        raise PersonalHistoryError(f"refusing hard-linked data file: {path}")
    return path


def private_layout():
    home = Path.home().resolve()
    root = home / ".claude-private"
    configured = os.environ.get("CLAUDE_CONFIG_DIR", "")
    if not configured or Path(configured).expanduser().resolve() != root:
        raise PersonalHistoryError(f"Personal requires CLAUDE_CONFIG_DIR={root}")
    checked_path(root, root)
    cwd = Path(os.environ.get("SESSION_ROOT", str(home / "claude-sessions"))).expanduser().absolute() / "Personal"
    if cwd.resolve() != cwd:
        raise PersonalHistoryError(f"refusing linked Personal working directory: {cwd}")
    key = re.sub(r"[^A-Za-z0-9-]", "-", str(cwd))  # Claude Code also turns "_" into "-"
    project = root / "projects" / key
    for path in (
        root / "projects", root / "history.jsonl", root / "jobs",
        root / "file-history", root / "session-env", root / "sessions",
        project, project / "memory",
    ):
        checked_path(path, root)
    return root, project, cwd


def effective_text(text):
    if not isinstance(text, str):
        return False
    text = text.strip()
    # Background events can wrap notifications in one or more system reminders.
    # Remove only leading reminders, retaining a real question after them.
    while text.startswith("<system-reminder>"):
        end = text.find("</system-reminder>")
        if end < 0:
            return False
        text = text[end + len("</system-reminder>"):].lstrip()
    return bool(text) and not text.startswith(WRAPPERS)


def is_effective_message(obj):
    if not isinstance(obj, dict) or obj.get("type") not in ("user", "assistant"):
        return False
    if any(obj.get(key) for key in ("isMeta", "isSidechain", "isCompactSummary", "isApiErrorMessage")):
        return False
    message = obj.get("message")
    if not isinstance(message, dict):
        return False
    content = message.get("content")
    if isinstance(content, str):
        return effective_text(content)
    if not isinstance(content, list):
        return False
    return any(
        isinstance(block, dict) and (
            block.get("type") == "image" or
            block.get("type") == "text" and effective_text(block.get("text"))
        ) for block in content
    )


def latest_message_time(path, cwd):
    latest = None
    # Stream large transcripts; an unfinished final JSON/UTF-8 write is not corruption.
    with path.open("rb") as stream:
        for number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except (ValueError, UnicodeError):
                if not line.endswith(b"\n"):
                    break
                raise PersonalHistoryError(f"corrupted history: {path.name}, line {number}")
            if not is_effective_message(obj):
                continue
            if obj.get("cwd") and os.path.realpath(obj["cwd"]) != str(cwd):
                continue
            try:
                timestamp = datetime.fromisoformat(obj.get("timestamp", "").replace("Z", "+00:00"))
            except (ValueError, TypeError, AttributeError):
                continue
            if timestamp.tzinfo is None:
                continue
            latest = max(latest, timestamp) if latest else timestamp
    return latest


def candidates(root, project):
    files = []
    if project.exists():
        for path in sorted(project.glob("*.jsonl")):
            checked_path(path, root)
            if not path.is_file():
                raise PersonalHistoryError(f"not a regular history file: {path}")
            files.append(path)
            if UUID.fullmatch(path.stem):
                checked_path(project / path.stem, root)
    return files


def select_uuid(explicit_uuid=None):
    root, project, cwd = private_layout()
    if explicit_uuid and not UUID.fullmatch(explicit_uuid):
        raise PersonalHistoryError("invalid session UUID")
    files = candidates(root, project)
    background_ids = {
        str(data.get("sessionId", data.get("session_id", "")))
        for data, age in private_job_states(root)
        if isinstance(data, dict) and data.get("template") == "bg"
        and os.path.realpath(data.get("cwd") or "/") == str(cwd)
    }
    if explicit_uuid and explicit_uuid in background_ids:
        raise PersonalHistoryError("background task history cannot be resumed as the Personal main conversation")
    if explicit_uuid:
        target = project / f"{explicit_uuid}.jsonl"
        if target not in files or latest_message_time(target, cwd) is None:
            raise PersonalHistoryError(f"session {explicit_uuid} has no valid private history")
        return explicit_uuid
    ranked = []
    for path in files:
        if UUID.fullmatch(path.stem) and path.stem not in background_ids:
            timestamp = latest_message_time(path, cwd)
            if timestamp is not None:
                ranked.append((timestamp, path.stem))
    if ranked:
        return max(ranked)[1]
    if files:
        raise PersonalHistoryError("private history exists but contains no valid conversation")
    return None


def private_job_states(root):
    now = time.time()
    for path in (root / "jobs").glob("*/state.json"):
        checked_path(path, root)
        try:
            data = json.loads(path.read_text())
            age = now - path.stat().st_mtime
        except FileNotFoundError:
            continue  # A job may finish while its state is being checked.
        except (ValueError, UnicodeError):
            raise PersonalHistoryError(f"invalid private job state: {path}")
        yield data, age


def has_active_private_lock(root, cwd):
    for data, age in private_job_states(root):
        if isinstance(data, dict) and data.get("state") == "working" and age <= 300:
            if os.path.realpath(data.get("cwd") or "/") == str(cwd):
                return True
    return False


# 直连 Anthropic 的合法模型名：claude-sonnet-5、claude-fable-5-1[1m]。
# 带斜杠的是代理时代的路由别名（"Codex API/gpt-6-astra"、"anthropic/claude-ccr-<hex>"），
# 代理下线后它们指向死模型，会让 Personal 启动即报废。
ANTHROPIC_MODEL_RE = re.compile(r"claude-[A-Za-z0-9._-]+(?:\[[A-Za-z0-9]+\])?")


def configured_model(root, field="model"):
    path = checked_path(root / "personal-launch.json", root)
    if not path.exists():
        return None
    try:
        config = json.loads(path.read_text())
    except (ValueError, UnicodeError) as exc:
        raise PersonalHistoryError("invalid personal-launch.json") from exc
    model = config.get(field, config.get("model")) if isinstance(config, dict) else None
    # 缺省或留空 = 不钉模型，由 settings.json 决定，跟其他 session 一致。
    # 钉死过一次 CCR 的 "Codex API/gpt-6-astra"，代理下线后 Personal 就一直连着死模型。
    if model is None or (isinstance(model, str) and not model.strip()):
        return None
    if not isinstance(model, str) or model.lstrip().startswith("-"):
        raise PersonalHistoryError("personal-launch.json model must be a non-empty name")
    if any(ord(char) < 32 or ord(char) == 127 for char in model):
        raise PersonalHistoryError("invalid control character in Personal model name")
    model = model.strip()
    if not ANTHROPIC_MODEL_RE.fullmatch(model):
        raise PersonalHistoryError(
            f"personal-launch.json 的 {field}={model!r} 不是直连 Anthropic 的模型名。"
            "应形如 claude-sonnet-5 或 claude-fable-5-1[1m]；"
            "留空则沿用 settings.json（推荐，与其他 session 一致）"
        )
    return model


def launch(launcher, explicit_uuid):
    root, _, cwd = private_layout()
    model = configured_model(root)
    local_model = configured_model(root, "claudeModel")
    uuid = select_uuid(explicit_uuid)
    if has_active_private_lock(root, cwd):
        raise ActiveLockError("Personal 存在活跃后台任务，请等待结束后再启动")
    os.umask(0o077)
    cwd.mkdir(parents=True, exist_ok=True)
    os.chdir(cwd)
    env = {**os.environ, "CLAUDE_CONFIG_DIR": str(root), "HAPPY_SESSION_NAME": "Personal"}
    # pane 的 shell 可能继承了代理时代（CLIProxyAPI / claude-code-router）残留的变量，
    # 留着会绕开 Keychain OAuth 直连的预期路径。与 smart-resume.sh 的 env -u 对齐。
    for stale in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
                  "ANTHROPIC_DEFAULT_HAIKU_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL"):
        env.pop(stale, None)
    args = ["happy", "--yolo"] if launcher == "happy" else ["claude", "--dangerously-skip-permissions"]
    if uuid:
        args += ["--resume", uuid]
    if model:
        if launcher == "happy":
            # Happy consumes --model for remote mode. Forward the Claude Code
            # compatible alias separately to its local subprocess.
            args += ["--model", model, f"--model={local_model}"]
        else:
            args += ["--model", local_model]
    os.execvpe(args[0], args, env)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("session_id", nargs="?")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--launch", choices=("happy", "claude"))
    mode.add_argument("--context-file", choices=("discuss-pending", "agent-status.json"))
    args = parser.parse_args(argv)
    try:
        if args.check:
            root, project, _ = private_layout()
            candidates(root, project)
            configured_model(root)
            configured_model(root, "claudeModel")
        elif args.context_file:
            root, _, _ = private_layout()
            print(checked_path(root / args.context_file, root))
        elif args.launch:
            launch(args.launch, args.session_id)
        else:
            uuid = select_uuid(args.session_id)
            if uuid:
                print(uuid)
        return 0
    except ActiveLockError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    except (PersonalHistoryError, OSError, RuntimeError) as exc:
        print(f"personal_history: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
