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
            if split.get("name") == session_name:
                existing = split
                break

    changed = False
    if existing is None:
        terminals.append({"splitTerminals": [{"name": session_name, "commands": [restore_cmd]}]})
        settings["restoreTerminals.terminals"] = terminals
        changed = True
    elif existing.get("commands", [""])[0] != restore_cmd:
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
        if not any(split.get("name") == session_name for split in terminal.get("splitTerminals", []))
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
            name = split.get("name", "")
            command = split.get("commands", [""])[0]
            print(f"{name}: {command}")


def switch_command(command, target):
    try:
        parts = shlex.split(command)
    except ValueError:
        return command

    if not parts:
        return command

    current = parts[0]
    if target == "vibe" and current == "happy-session":
        parts[0] = "happy-vibe-session"
    elif target == "happy" and current == "happy-vibe-session":
        parts[0] = "happy-session"
    else:
        return command

    return " ".join(shlex.quote(part) for part in parts)


def switch_restore_mode(settings_path, target):
    settings = load(settings_path)
    changed = 0

    for terminal in settings.get("restoreTerminals.terminals", []):
        for split in terminal.get("splitTerminals", []):
            commands = split.get("commands", [])
            if not commands:
                continue
            new_command = switch_command(commands[0], target)
            if new_command != commands[0]:
                commands[0] = new_command
                changed += 1

    if changed:
        save(settings_path, settings)

    print(f"Updated {changed} restore command(s) to {target}.")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "register" and len(sys.argv) == 6:
        _, _, settings_path, session_name, command_name, session_id = sys.argv
        register(settings_path, session_name, command_name, session_id)
    elif command == "remove" and len(sys.argv) == 4:
        _, _, settings_path, session_name = sys.argv
        remove(settings_path, session_name)
    elif command == "list" and len(sys.argv) == 3:
        _, _, settings_path = sys.argv
        list_commands(settings_path)
    elif command == "switch" and len(sys.argv) == 4 and sys.argv[3] in {"happy", "vibe"}:
        _, _, settings_path, target = sys.argv
        switch_restore_mode(settings_path, target)
    else:
        print(
            "Usage: vscode_restore.py register <settings> <session-name> <command-name> <session-id>\n"
            "       vscode_restore.py remove <settings> <session-name>\n"
            "       vscode_restore.py list <settings>\n"
            "       vscode_restore.py switch <settings> happy|vibe",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    main()
