import importlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))


def message(text):
    return json.dumps({"type": "user", "message": {"role": "user", "content": text},
                       "timestamp": "2026-01-01T00:00:00Z"}) + "\n"


class SessionlibTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.old_home = os.environ.get("HOME")
        os.environ["HOME"] = str(self.home)
        os.environ.pop("SESSION_ROOT", None)
        import sessionlib
        self.sl = importlib.reload(sessionlib)

    def tearDown(self):
        if self.old_home is not None:
            os.environ["HOME"] = self.old_home
        self.tmp.cleanup()

    def project(self, name):
        path = self.sl.project_dir(name)
        path.mkdir(parents=True, exist_ok=True)
        return path

    def test_project_key_replaces_every_non_alnum_dash(self):
        # Claude Code turns ".", "_" and spaces into "-"; session.sh used to keep "_".
        self.assertEqual(self.sl.project_key("/Users/a.b/claude-sessions/My_Sess 2"),
                         "-Users-a-b-claude-sessions-My-Sess-2")

    def test_private_session_uses_private_config_dir(self):
        self.assertEqual(self.sl.config_dir("Personal"), self.home / ".claude-private")
        self.assertEqual(self.sl.config_dir("GCP"), self.home / ".claude")

    def test_name_from_cwd_only_for_direct_children(self):
        root = self.home / "claude-sessions"
        (root / "GCP" / "sub").mkdir(parents=True)
        (root / "_archived" / "Old").mkdir(parents=True)
        self.assertEqual(self.sl.name_from_cwd(root / "GCP"), "GCP")
        self.assertIsNone(self.sl.name_from_cwd(root / "GCP" / "sub"))
        self.assertIsNone(self.sl.name_from_cwd(root / "_archived"))
        self.assertIsNone(self.sl.name_from_cwd(self.home))

    def test_resume_target_prefers_marker_with_existing_transcript(self):
        project = self.project("GCP")
        a, b = "a" * 8 + "-1111-4111-8111-" + "1" * 12, "b" * 8 + "-1111-4111-8111-" + "1" * 12
        (project / f"{a}.jsonl").write_text(message("old"))
        (project / f"{b}.jsonl").write_text(message("new"))
        (self.home / "claude-sessions" / "GCP").mkdir(parents=True)
        self.sl.write_marker("GCP", a)
        self.assertEqual(self.sl.resume_target("GCP"), a)

    def test_resume_target_falls_back_to_newest_real_conversation(self):
        project = self.project("GCP")
        real, noise, bg = ("a" * 8 + "-1111-4111-8111-" + "1" * 12,
                           "c" * 8 + "-1111-4111-8111-" + "1" * 12,
                           "d" * 8 + "-1111-4111-8111-" + "1" * 12)
        (project / f"{real}.jsonl").write_text(message("a real question"))
        os.utime(project / f"{real}.jsonl", (1, 1))
        # Newer, but only a slash-command wrapper: not a real turn.
        (project / f"{noise}.jsonl").write_text(message("<command-name>/clear</command-name>"))
        # Newest, but it belongs to a bg-agent job started from this session.
        (project / f"{bg}.jsonl").write_text(message("bg work"))
        session = self.home / "claude-sessions" / "GCP"
        session.mkdir(parents=True)
        job = self.home / ".claude" / "jobs" / "j1"
        job.mkdir(parents=True)
        (job / "state.json").write_text(json.dumps({"sessionId": bg, "cwd": str(session), "state": "working"}))
        self.sl.write_marker("GCP", "e" * 8 + "-1111-4111-8111-" + "1" * 12)  # transcript purged
        self.assertEqual(self.sl.resume_target("GCP"), real)

    def test_marker_write_is_atomic_and_validated_on_read(self):
        (self.home / "claude-sessions" / "GCP").mkdir(parents=True)
        self.sl.marker_path("GCP").write_text("not-a-uuid\n")
        self.assertIsNone(self.sl.read_marker("GCP"))
        uuid = "a" * 8 + "-1111-4111-8111-" + "1" * 12
        self.sl.write_marker("GCP", uuid)
        self.assertEqual(self.sl.read_marker("GCP"), uuid)
        self.assertEqual(list(self.sl.marker_path("GCP").parent.glob(".current-session.*.tmp")), [])


if __name__ == "__main__":
    unittest.main()
