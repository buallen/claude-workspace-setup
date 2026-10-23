"""The settings.json edits in setup-workspace.sh, run against temporary copies."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

SETUP = (Path(__file__).resolve().parents[1] / "setup-workspace.sh").read_text()
BLOCKS = re.findall(r"python3 - (.*?) << 'PYTHON'\n(.*?)\nPYTHON\n", SETUP, re.S)
CLAUDE_BLOCKS = [code for args, code in BLOCKS if "CLAUDE_SETTINGS" in args]


def run_all(path, hook_dir="/x/hooks"):
    out = []
    for code in CLAUDE_BLOCKS:
        argv = [str(path)] + ([hook_dir] if "hook_dir" in code else [])
        out.append(subprocess.run(["python3", "-", *argv], input=code, text=True, capture_output=True))
    return out


class SetupSettingsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_found_the_claude_settings_steps(self):
        self.assertEqual(len(CLAUDE_BLOCKS), 3)   # retire loop hook, tab-status, sessionctl hooks

    def test_jsonc_settings_are_left_untouched(self):
        path = self.dir / "settings.json"
        text = '{\n  // my note\n  "permissions": {"allow": ["Bash(ls)"]},\n}\n'
        path.write_text(text)
        for result in run_all(path):
            self.assertEqual(result.returncode, 3, result.stderr)   # shell prints a warning, not "ok"
            self.assertIn("not plain JSON", result.stderr)
        self.assertEqual(path.read_text(), text)
        self.assertFalse((self.dir / "settings.json.bak-setup").exists())

    def test_second_run_writes_nothing_and_keeps_other_settings(self):
        path = self.dir / "settings.json"
        path.write_text(json.dumps({"permissions": {"allow": ["Bash(ls)"]}, "hooks": {
            "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/a/hooks/loop.sh"}]}]}}))
        run_all(path)
        first = json.loads(path.read_text())
        self.assertEqual(first["permissions"], {"allow": ["Bash(ls)"]})
        commands = [h["command"] for g in first["hooks"].values() for x in g for h in x["hooks"]]
        self.assertFalse(any(c.endswith("loop.sh") for c in commands))
        self.assertEqual(sum("session-marker.py" in c for c in commands), 1)
        self.assertEqual(sum("guard-pkill.py" in c for c in commands), 1)
        mtime = path.stat().st_mtime_ns
        os.utime(path, ns=(mtime - 10**9, mtime - 10**9))
        before = path.stat().st_mtime_ns
        run_all(path)
        self.assertEqual(path.stat().st_mtime_ns, before)      # unchanged content -> not rewritten
        self.assertEqual(json.loads(path.read_text()), first)

    def test_non_object_json_is_skipped_not_crashed(self):
        path = self.dir / "settings.json"
        path.write_text("[]")
        for result in run_all(path):
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(path.read_text(), "[]")

    def test_backup_keeps_the_private_file_mode(self):
        path = self.dir / "settings.json"
        path.write_text(json.dumps({"env": {"TOKEN": "x"}}))
        os.chmod(path, 0o600)
        run_all(path)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(str(path) + ".bak-setup").st_mode & 0o777, 0o600)

    def test_symlinked_settings_stay_a_symlink(self):
        real = self.dir / "real.json"
        real.write_text("{}")
        link = self.dir / "settings.json"
        link.symlink_to(real)
        run_all(link)
        self.assertTrue(link.is_symlink())
        self.assertIn("session-marker.py", real.read_text())


if __name__ == "__main__":
    unittest.main()
