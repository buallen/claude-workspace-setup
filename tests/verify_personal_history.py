#!/usr/bin/env python3
"""Run the local, credential-free Personal history regression checks."""
import ast
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
PYTHON_FILES = [
    ROOT / "lib/personal_history.py",
    ROOT / "lib/report_state.py",
    ROOT / "tests/test_personal_history.py",
    Path(__file__).resolve(),
]
SHELL_FILES = [
    ROOT / "bin/claude-session",
    ROOT / "bin/smart-resume.sh",
    ROOT / "lib/session.sh",
    ROOT / "hooks/post-compact.sh",
    ROOT / "hooks/detect-report.sh",
    ROOT / "hooks/discuss-check.sh",
    Path.home() / "bin/claude-auth-watchdog.sh",
]


def main():
    sys.dont_write_bytecode = True
    for path in PYTHON_FILES:
        source = path.read_text()
        compile(ast.parse(source, filename=str(path)), str(path), "exec")
        if any(line.rstrip() != line for line in source.splitlines()):
            raise ValueError(f"trailing whitespace: {path}")
    for path in SHELL_FILES:
        subprocess.run(["/bin/bash", "-n", str(path)], check=True)
    subprocess.run(["/bin/zsh", "-n", str(Path.home() / ".zprofile")], check=True)
    suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"), pattern="test_*.py")
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
