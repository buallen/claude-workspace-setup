#!/usr/bin/env python3
import json
import os
import shlex
import sys
import tempfile
from pathlib import Path


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save(path, settings):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, suffix=".tmp") as tf:
        json.dump(settings, tf, indent=2, ensure_ascii=False)
        tmp = tf.name
    os.replace(tmp, path)


def shell_quote_single(value):
    return value.replace("'", "'\\''")


SESSION_LAUNCHERS = {
    "claude-session",
    "happy-session",
    "happy-session-private",
}


def entry_session_name(split):
    """Derive a split entry's session name from its restore command.

    The name is the first argument after the *-session launcher token, so we no
    longer need a static ``name`` field — that field would pin the VS Code tab
    title and block the dynamic "${sequence}" status icon. Falls back to a
    legacy ``name`` field for entries written by older versions.
    """
    commands = split.get("commands") or []
    if commands:
        try:
            parts = shlex.split(commands[0])
        except ValueError:
            parts = []
        for index, part in enumerate(parts):
            if Path(part).name in SESSION_LAUNCHERS and index + 1 < len(parts):
                return parts[index + 1]
    return split.get("name")


def register(settings_path, session_name, command_name, session_id=""):
    settings = load(settings_path)
    terminals = settings.get("restoreTerminals.terminals", [])
    safe_name = shell_quote_single(session_name)
    restore_cmd = (
        f"{command_name} '{safe_name}' '{session_id}'"
        if session_id
        else f"{command_name} '{safe_name}'"
    )

    existing = None
    for terminal in terminals:
        for split in terminal.get("splitTerminals", []):
            if entry_session_name(split) == session_name:
                existing = split
                break
        if existing is not None:
            break

    changed = False
    if existing is None:
        terminals.append({"splitTerminals": [{"commands": [restore_cmd]}]})
        settings["restoreTerminals.terminals"] = terminals
        changed = True
    else:
        if "name" in existing:  # un-pin a legacy entry so its tab shows status
            del existing["name"]
            changed = True
        if existing.get("commands", [""])[0] != restore_cmd:
            existing["commands"] = [restore_cmd]
            changed = True

    if settings.get("terminal.integrated.tabs.title") != "${sequence}":
        settings["terminal.integrated.tabs.title"] = "${sequence}"
        changed = True

    if changed:
        save(settings_path, settings)


def register_command(settings_path, restore_name, restore_cmd):
    settings = load(settings_path)
    terminals = settings.get("restoreTerminals.terminals", [])

    existing = None
    for terminal in terminals:
        for split in terminal.get("splitTerminals", []):
            if entry_session_name(split) == restore_name:
                existing = split
                break
        if existing is not None:
            break

    changed = False
    if existing is None:
        terminals.append({"splitTerminals": [{"commands": [restore_cmd]}]})
        settings["restoreTerminals.terminals"] = terminals
        changed = True
    else:
        if "name" in existing:  # un-pin a legacy entry so its tab shows status
            del existing["name"]
            changed = True
        if existing.get("commands", [""])[0] != restore_cmd:
            existing["commands"] = [restore_cmd]
            changed = True

    if settings.get("terminal.integrated.tabs.title") != "${sequence}":
        settings["terminal.integrated.tabs.title"] = "${sequence}"
        changed = True

    if changed:
        save(settings_path, settings)


def remove(settings_path, session_name):
    settings = load(settings_path)
    terminals = settings.get("restoreTerminals.terminals", [])
    new_terminals = [
        terminal
        for terminal in terminals
        if not any(entry_session_name(split) == session_name for split in terminal.get("splitTerminals", []))
    ]

    if len(new_terminals) == len(terminals):
        print(f"Not found in VS Code restore list: {session_name}")
        return

    settings["restoreTerminals.terminals"] = new_terminals
    save(settings_path, settings)
    print(f"Removed from VS Code restore list: {session_name}")


def list_commands(settings_path):
    settings = load(settings_path)
    for terminal in settings.get("restoreTerminals.terminals", []):
        for split in terminal.get("splitTerminals", []):
            name = entry_session_name(split) or ""
            command = split.get("commands", [""])[0]
            print(f"{name}: {command}")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "register" and len(sys.argv) == 6:
        _, _, settings_path, session_name, command_name, session_id = sys.argv
        register(settings_path, session_name, command_name, session_id)
    elif command == "register-command" and len(sys.argv) == 5:
        _, _, settings_path, restore_name, restore_cmd = sys.argv
        register_command(settings_path, restore_name, restore_cmd)
    elif command == "remove" and len(sys.argv) == 4:
        _, _, settings_path, session_name = sys.argv
        remove(settings_path, session_name)
    elif command == "list" and len(sys.argv) == 3:
        _, _, settings_path = sys.argv
        list_commands(settings_path)
    else:
        print(
            "Usage: vscode_restore.py register <settings> <session-name> <command-name> <session-id>\n"
            "       vscode_restore.py register-command <settings> <restore-name> <restore-command>\n"
            "       vscode_restore.py remove <settings> <session-name>\n"
            "       vscode_restore.py list <settings>",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    main()
