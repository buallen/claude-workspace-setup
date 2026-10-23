import ast
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROFILE = Path.home() / ".zprofile"
BLOCK = re.compile(r"^# >>> otty auto-attach.*?^# <<< otty auto-attach <<<\n?", re.M | re.S)
STUB = r'''
import json, os, sys
from pathlib import Path
command = Path(sys.argv[0]).name
if command == "ps":
    print("321" if "ppid=" in sys.argv else os.environ.get("ANCESTOR", "/Applications/Otty.app/Contents/MacOS/Otty"))
else:
    event = {"command": command, "args": sys.argv[1:]}
    for key in ("CLAUDE_LAUNCHER", "CLAUDE_CONFIG_DIR", "OTTY_TEST_RC", "TMUX", "TMUX_PANE"):
        event[key] = os.environ.get(key)
    with open(os.environ["CALL_LOG"], "a") as log:
        log.write(json.dumps(event) + "\n")
    created = Path(os.environ["CALL_LOG"]).with_name("session-created")
    if command == "tmux" and sys.argv[1] == "has-session":
        sys.exit(0 if created.exists() else int(os.environ.get("HAS_SESSION", "1")))
    if command == "claude-session":
        if os.environ.get("CONCURRENT_CREATE"):
            created.touch()
        sys.exit(int(os.environ.get("LAUNCH_EXIT", "0")))
'''


class OttyRestoreTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="otty-restore-test-")
        self.addCleanup(self.scratch.cleanup)
        self.home = Path(self.scratch.name).resolve()
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.launcher = self.home / ".claude/claude-workspace/bin/claude-session"
        self.launcher.parent.mkdir(parents=True)
        self.log = self.home / "calls.jsonl"
        (self.home / ".zshrc").write_text("export OTTY_TEST_RC=loaded\n")
        (self.home / ".zprofile").write_text('print recursive > "$HOME/recursive"\n')
        for path in (self.bin / "ps", self.bin / "tmux"):
            self.write_stub(path)

    def write_stub(self, path):
        path.write_text(f"#!{sys.executable}\n" + STUB)
        path.chmod(0o700)

    def run_restore(self, relative="claude-sessions/Workspace", missing=False, **overrides):
        if not missing:
            self.write_stub(self.launcher)
        cwd = self.home / relative
        cwd.mkdir(parents=True, exist_ok=True)
        self.log.write_text("")
        block = BLOCK.search(PROFILE.read_text()).group()
        block = block.replace("/bin/ps", shlex.quote(str(self.bin / "ps")))
        block = block.replace("/opt/homebrew/bin/tmux", shlex.quote(str(self.bin / "tmux")))
        block = block.replace("/tmp/oaa-debug.log", shlex.quote(str(self.home / "debug.log")))
        env = {
            "HOME": str(self.home), "ZDOTDIR": str(self.home),
            "PATH": f"{self.bin}:/usr/bin:/bin", "TERM": "dumb",
            "CALL_LOG": str(self.log), "TZ": "Asia/Singapore",
            "TMUX": "stale,123,0", "TMUX_PANE": "%1",
            "CLAUDE_CONFIG_DIR": "/wrong/inherited-config",
        }
        env.update(overrides)
        result = subprocess.run(
            ["/bin/zsh", "-fc", block + '\nprint outer-alive > "$HOME/outer-alive"\n'],
            env=env, cwd=cwd, text=True, capture_output=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / "outer-alive").exists())
        self.assertFalse((self.home / "recursive").exists())
        events = [json.loads(line) for line in self.log.read_text().splitlines()]
        return events, result

    def assert_launch(self, events, name, private=False):
        launches = [e for e in events if e["command"] == "claude-session"]
        self.assertEqual(len(launches), 1, events)
        launch = launches[0]
        self.assertEqual(launch["args"], [name])
        self.assertEqual(launch["CLAUDE_LAUNCHER"], "happy")
        self.assertEqual(launch["CLAUDE_CONFIG_DIR"], str(self.home / (".claude-private" if private else ".claude")))
        self.assertEqual(launch["OTTY_TEST_RC"], "loaded")
        self.assertIsNone(launch["TMUX"])
        self.assertIsNone(launch["TMUX_PANE"])
        self.assertFalse(any(e["command"] == "tmux" and e["args"][0] != "has-session" for e in events))

    def test_cold_start(self):
        events, _ = self.run_restore()
        self.assert_launch(events, "Workspace")

    def test_cold_start_spaced_name_and_subdirectory(self):
        events, _ = self.run_restore("claude-sessions/Team Pay/repo")
        self.assert_launch(events, "Team Pay")

    def test_cold_start_private_config(self):
        events, _ = self.run_restore("claude-sessions/Personal")
        self.assert_launch(events, "Personal", private=True)

    def test_name_is_not_interpreted_as_shell_code(self):
        name = "name'; print injected; #"
        events, result = self.run_restore("claude-sessions/" + name)
        self.assert_launch(events, name)
        self.assertNotIn("\ninjected\n", result.stdout)

    def test_existing_session_only_attaches(self):
        events, _ = self.run_restore(HAS_SESSION="0")
        self.assertEqual([(e["command"], e["args"]) for e in events], [
            ("tmux", ["has-session", "-t", "Workspace"]),
            ("tmux", ["attach", "-t", "Workspace"]),
        ])
        for event in events:
            self.assertIsNone(event["TMUX"])
            self.assertIsNone(event["TMUX_PANE"])

    def test_disabled(self):
        events, _ = self.run_restore(OTTY_NO_AUTO_ATTACH="1")
        self.assertEqual(events, [])

    def test_non_otty_shell(self):
        events, _ = self.run_restore(ANCESTOR="/usr/bin/tmux")
        self.assertEqual(events, [])

    def test_outside_session_directory(self):
        events, _ = self.run_restore("ordinary-project")
        self.assertEqual(events, [])

    def test_missing_launcher_reports_error(self):
        events, result = self.run_restore(missing=True)
        self.assertFalse(any(e["command"] == "claude-session" for e in events))
        self.assertIn("启动器不存在或不可执行", result.stderr)

    def test_failed_launcher_is_not_retried(self):
        events, result = self.run_restore(LAUNCH_EXIT="7")
        self.assert_launch(events, "Workspace")
        self.assertIn("自动恢复失败", result.stderr)

    def test_concurrent_creation_attaches_without_relaunch(self):
        events, result = self.run_restore(CONCURRENT_CREATE="1", LAUNCH_EXIT="1")
        self.assertEqual([(e["command"], e["args"]) for e in events], [
            ("tmux", ["has-session", "-t", "Workspace"]),
            ("claude-session", ["Workspace"]),
            ("tmux", ["has-session", "-t", "=Workspace"]),
            ("tmux", ["attach", "-t", "=Workspace"]),
        ])
        self.assertNotIn("自动恢复失败", result.stderr)

    def test_setup_template_matches_installed_block(self):
        source = (ROOT / "bin/otty-setup").read_text()
        literal = re.search(r"^block = ('''[\s\S]*?''')", source, re.M).group(1)
        template = ast.literal_eval(literal)
        self.assertEqual(BLOCK.search(PROFILE.read_text()).group(), BLOCK.search(template).group())


if __name__ == "__main__":
    unittest.main()
