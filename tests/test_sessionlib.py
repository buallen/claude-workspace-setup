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
        # A private, empty tmux server: never read the real sessions (one is called GCP).
        os.environ["SESSIONLIB_TMUX_SOCKET"] = f"sessionlib-unittest-{os.getpid()}"
        import sessionlib
        self.sl = importlib.reload(sessionlib)

    def tearDown(self):
        os.environ.pop("SESSIONLIB_TMUX_SOCKET", None)
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

    def test_auth_error_pending_only_when_it_is_the_last_turn(self):
        project = self.project("GCP")
        (self.home / "claude-sessions" / "GCP").mkdir(parents=True)
        uuid = "a" * 8 + "-1111-4111-8111-" + "1" * 12
        error = json.dumps({"type": "assistant", "isApiErrorMessage": True, "error": "authentication_failed",
                            "message": {"role": "assistant", "content": [{"type": "text", "text": "Login expired · Please run /login"}]}}) + "\n"
        talk = json.dumps({"type": "assistant", "message": {"role": "assistant", "content": "API Error: 401 means Please run /login"}}) + "\n"
        transcript = project / f"{uuid}.jsonl"
        self.sl.write_marker("GCP", uuid)
        transcript.write_text(message("hi") + talk)
        self.assertFalse(self.sl.auth_error_pending("GCP"))        # only talking about it
        transcript.write_text(message("hi") + error)
        self.assertTrue(self.sl.auth_error_pending("GCP"))         # real, unanswered
        transcript.write_text(message("hi") + error + message("ok, logged in"))
        self.assertFalse(self.sl.auth_error_pending("GCP"))        # user moved on

    def test_marker_on_a_conversation_without_a_real_turn_is_not_resumed(self):
        # /clear then nothing typed: the hook points the marker at an empty
        # conversation; --resume on it fails, so fall back to the real one.
        project = self.project("GCP")
        (self.home / "claude-sessions" / "GCP").mkdir(parents=True)
        real = "a" * 8 + "-1111-4111-8111-" + "1" * 12
        empty = "b" * 8 + "-1111-4111-8111-" + "1" * 12
        (project / f"{real}.jsonl").write_text(message("real work"))
        (project / f"{empty}.jsonl").write_text(json.dumps({"type": "permission-mode"}) + "\n")
        self.sl.write_marker("GCP", empty)
        self.assertEqual(self.sl.resume_target("GCP"), real)

    def test_effective_message_found_behind_a_large_tool_result_tail(self):
        project = self.project("GCP")
        path = project / "x.jsonl"
        tail = json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "tool_result", "content": "x" * 200000}]}}) + "\n"
        path.write_text(message("the question") + tail * 30)   # ~6 MB of tool results after it
        self.assertTrue(self.sl.has_effective_message(path))

    def test_work_indicator_matches_current_spinner_and_subagent_rows(self):
        busy = ["✻ Thinking… (12s · ↓ 3.4k tokens)", "· ↑ 120 tokens", "  ◯ general-purpose  Audit the diff",
                "esc to interrupt"]
        for text in busy:
            self.assertTrue(self.sl.WORK_RE.search(text), text)
        self.assertFalse(self.sl.WORK_RE.search("Done. ↓ see the summary below"))

    def test_program_ignores_tool_shells_that_mention_claude(self):
        self.assertEqual(self.sl.program("/bin/zsh -c ps ax | grep claude.exe"), "/bin/zsh")
        self.assertEqual(self.sl.program("/x/bin/node --no-warnings /x/happy/dist/index.mjs --yolo"),
                         "/x/happy/dist/index.mjs")
        self.assertEqual(self.sl.program("/x/claude-code/bin/claude.exe --resume u"), "/x/claude-code/bin/claude.exe")


if __name__ == "__main__":
    unittest.main()
