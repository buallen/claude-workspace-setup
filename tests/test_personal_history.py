from concurrent.futures import ThreadPoolExecutor, TimeoutError
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib/personal_history.py"
A = "11111111-1111-4111-8111-111111111111"
B = "22222222-2222-4222-8222-222222222222"
C = "33333333-3333-4333-8333-333333333333"
STUB = r'''
import json, os, re, subprocess, sys
from pathlib import Path
name = Path(sys.argv[0]).name
args = sys.argv[1:]
event = {"command": name, "args": args, "config": os.environ.get("CLAUDE_CONFIG_DIR")}
with open(os.environ["CALL_LOG"], "a") as f:
    f.write(json.dumps(event) + "\n")
if name == "ps":
    if os.environ.get("ACTIVE"):
        print("987654 876543")
elif name == "tmux":
    if args[0] == "has-session":
        sys.exit(0 if os.environ.get("EXISTING") else 1)
    if args[0] == "list-panes":
        print("876543")
    if args[0] in ("new-session", "send-keys"):
        command = args[-1] if args[0] == "new-session" else args[-2]
        # Only the launcher command: never start the fallback login shell.
        command = command.removesuffix("; exec /bin/zsh -l")
        env = os.environ.copy()
        env.pop("CLAUDE_CONFIG_DIR", None)
        env.pop("HAPPY_SESSION_NAME", None)
        cwd = args[args.index("-c") + 1] if args[0] == "new-session" else os.environ.get("PANE_CWD")
        subprocess.run(["/bin/bash", "-c", command], env=env, cwd=cwd, check=True)
elif name in ("happy", "claude"):
    root = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
    key = re.sub(r"[^A-Za-z0-9_-]", "-", os.getcwd())
    target = root / "projects" / key
    target.mkdir(parents=True, exist_ok=True)
    with (target / "simulated-write.jsonl").open("a") as f:
        f.write(json.dumps({"type": "permission-mode"}) + "\n")
    sys.exit(int(os.environ.get("HAPPY_EXIT", "0")))
'''


def message(ts, text="继续处理这个问题", **extra):
    return {"type": "user", "timestamp": ts, "message": {"role": "user", "content": text}, **extra}


class PersonalHistoryTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="personal-history-test-")
        self.addCleanup(scratch.cleanup)
        self.home = Path(scratch.name).resolve()
        self.private = self.home / ".claude-private"
        self.normal = self.home / ".claude"
        self.cwd = self.home / "claude-sessions/Personal"
        self.cwd.mkdir(parents=True)
        self.key = re.sub(r"[^A-Za-z0-9_-]", "-", str(self.cwd))
        self.project = self.private / "projects" / self.key
        self.project.mkdir(parents=True)
        self.normal_project = self.normal / "projects" / self.key
        self.normal_project.mkdir(parents=True)
        self.marker = self.cwd / ".current-session"
        self.marker.write_text(C + "\n")
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.log = self.home / "calls.jsonl"
        self.log.write_text("")
        self.env = {
            "HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin",
            "CLAUDE_CONFIG_DIR": str(self.private), "CALL_LOG": str(self.log),
            "CLAUDE_LAUNCHER": "happy", "TZ": "Asia/Singapore",
        }
        for name in ("happy", "claude", "tmux", "ps", "claude-auth-sync"):
            self.stub(self.bin / name)
        (self.bin / "python3").symlink_to(sys.executable)

    def stub(self, path):
        path.write_text(f"#!{sys.executable}\n" + STUB)
        path.chmod(0o700)

    def history(self, uid, *records, project=None):
        p = (project or self.project) / (uid + ".jsonl")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records))
        return p

    def run_helper(self, *args, **env):
        return subprocess.run(
            [sys.executable, "-B", str(HELPER), *args], env={**self.env, **env},
            capture_output=True, text=True, timeout=10,
        )

    def events(self, name):
        return [e for e in map(json.loads, self.log.read_text().splitlines()) if e["command"] == name]

    def assert_selected(self, uid, *args):
        result = self.run_helper(*args)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), uid)
        self.assertEqual(self.marker.read_text(), C + "\n")

    def fixture_latest(self):
        self.history(A, message("2026-09-01T09:00:00+08:00"))
        self.history(B, message("2026-09-02T09:00:00+08:00"))
        self.history(C, message("2026-09-03T09:00:00+08:00", "<command-name>/exit</command-name>"))

    def test_latest_ignores_marker_and_mtime(self):
        self.fixture_latest()
        os.utime(self.project / (A + ".jsonl"), None)
        self.assert_selected(B)

    def test_does_not_scan_other_projects_or_subagents(self):
        self.fixture_latest()
        self.history(C, message("2026-09-10T09:00:00+08:00"), project=self.private / "projects/Other")
        self.history(C, message("2026-09-10T09:00:00+08:00"), project=self.project / "subagents")
        self.assert_selected(B)

    def test_registered_background_history_never_replaces_main(self):
        self.fixture_latest()
        job = self.private / "jobs/background/state.json"
        job.parent.mkdir(parents=True)
        for state in ("blocked", "done", "working"):
            job.write_text(json.dumps({"template": "bg", "state": state, "cwd": str(self.cwd), "sessionId": B}))
            with self.subTest(state=state):
                self.assert_selected(A)
                self.assertNotEqual(self.run_helper(B).returncode, 0)
        job.unlink()
        normal_job = self.normal / "jobs/background/state.json"
        normal_job.parent.mkdir(parents=True)
        normal_job.write_text(json.dumps({"template": "bg", "state": "blocked", "cwd": str(self.cwd), "sessionId": B}))
        self.assert_selected(B)

    def test_only_background_history_does_not_create_empty_conversation(self):
        self.history(B, message("2026-09-02T09:00:00+08:00"))
        job = self.private / "jobs/background/state.json"
        job.parent.mkdir(parents=True)
        job.write_text(json.dumps({"template": "bg", "state": "blocked", "cwd": str(self.cwd), "sessionId": B}))
        self.assertNotEqual(self.run_helper("--launch", "happy").returncode, 0)
        self.assertEqual(self.events("happy"), [])

    def test_skip_metadata_sidechain_tools_notifications(self):
        self.history(A, message("2026-09-01T09:00:00+08:00"))
        for record in (
            message("2026-09-02T09:00:00+08:00", isMeta=True),
            message("2026-09-02T09:00:00+08:00", isSidechain=True),
            message("2026-09-02T09:00:00+08:00", isCompactSummary=True),
            message("2026-09-02T09:00:00+08:00", "<task-notification>finished</task-notification>"),
            message("2026-09-02T09:00:00+08:00", [{"type": "tool_result", "content": "ok"}]),
        ):
            with self.subTest(record=record):
                self.history(B, record)
                self.assert_selected(A)

    def test_wrapped_background_notifications_do_not_count(self):
        self.history(A, message("2026-09-01T09:00:00+08:00"))
        wrapped = "<system-reminder>\n<task-notification>finished</task-notification>\n</system-reminder>"
        for text in (wrapped, wrapped + "\n" + wrapped, "<system-reminder>incomplete"):
            for content in (text, [{"type": "text", "text": text}]):
                with self.subTest(content=content):
                    self.history(B, message("2026-09-02T09:00:00+08:00", content))
                    self.assert_selected(A)

    def test_real_question_after_reminder_still_counts(self):
        self.history(A, message("2026-09-01T09:00:00+08:00"))
        text = "<system-reminder>environment context</system-reminder>\n请继续处理这个问题"
        self.history(B, message("2026-09-02T09:00:00+08:00", text))
        self.assert_selected(B)

    def test_real_message_mentioning_wrapper_is_not_discarded(self):
        self.history(A, message("2026-09-01T09:00:00+08:00", "解释一下 <command-name> 的含义"))
        self.assert_selected(A)

    def test_images_and_assistant_text_count(self):
        self.history(A, message("2026-09-01T09:00:00+08:00", [{"type": "image", "source": {}}]))
        self.assert_selected(A)
        self.history(B, {"type": "assistant", "timestamp": "2026-09-02T09:00:00+08:00", "message": {"content": [{"type": "text", "text": "已处理"}]}})
        self.assert_selected(B)

    def test_explicit_id_must_be_private_and_valid(self):
        self.fixture_latest()
        self.assert_selected(A, A)
        self.assertNotEqual(self.run_helper(C).returncode, 0)
        self.history("44444444-4444-4444-8444-444444444444", message("2026-09-09T09:00:00+08:00"), project=self.normal_project)
        self.assertNotEqual(self.run_helper("44444444-4444-4444-8444-444444444444").returncode, 0)
        self.assertNotEqual(self.run_helper("../escape").returncode, 0)

    def test_non_uuid_filename_cannot_be_resumed(self):
        self.history("not-a-uuid", message("2026-09-01T09:00:00+08:00"))
        self.assertNotEqual(self.run_helper().returncode, 0)

    def test_private_root_symlink_to_normal_is_rejected(self):
        shutil.rmtree(self.private)
        self.private.symlink_to(self.normal, target_is_directory=True)
        self.history(A, message("2026-09-01T09:00:00+08:00"), project=self.normal_project)
        self.assertNotEqual(self.run_helper("--check").returncode, 0)

    def test_missing_project_under_cross_root_symlink_is_rejected(self):
        shutil.rmtree(self.private / "projects")
        target = self.normal / "empty-projects"
        target.mkdir()
        (self.private / "projects").symlink_to(target, target_is_directory=True)
        self.assertNotEqual(self.run_helper("--check").returncode, 0)

    def test_linked_history_is_rejected_even_under_different_name(self):
        source = self.history(A, message("2026-09-01T09:00:00+08:00"), project=self.normal_project)
        for hard in (False, True):
            with self.subTest(hard=hard):
                dest = self.project / (B + ".jsonl")
                if hard:
                    os.link(source, dest)
                else:
                    dest.symlink_to(source)
                self.assertNotEqual(self.run_helper().returncode, 0)
                dest.unlink()

    def test_truncated_tail_but_not_corrupt_middle_is_tolerated(self):
        p = self.history(A, message("2026-09-01T09:00:00+08:00"))
        with p.open("ab") as f:
            f.write(b'{"type":"user","text":"\xe4')
        self.assert_selected(A)
        p.write_bytes(p.read_bytes() + b'\n{}\n')
        self.assertNotEqual(self.run_helper().returncode, 0)

    def test_only_empty_histories_fail_without_launch(self):
        self.history(A, {"type": "permission-mode"})
        self.assertNotEqual(self.run_helper("--launch", "happy").returncode, 0)
        self.assertEqual(self.events("happy"), [])

    def test_fresh_launch_and_failed_resume_never_retry(self):
        result = self.run_helper("--launch", "happy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events("happy")[0]["args"], ["--yolo"])
        (self.project / "simulated-write.jsonl").unlink()
        self.history(A, message("2026-09-01T09:00:00+08:00"))
        result = self.run_helper("--launch", "happy", HAPPY_EXIT="7")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(len(self.events("happy")), 2)

    def test_private_active_lock_blocks_but_stale_or_other_root_does_not(self):
        self.fixture_latest()
        lock = self.private / "jobs/job/state.json"
        lock.parent.mkdir(parents=True)
        lock.write_text(json.dumps({"state": "working", "cwd": str(self.cwd)}))
        self.assert_selected(B)
        result = self.run_helper("--launch", "happy")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.events("happy"), [])
        os.utime(lock, (time.time() - 301, time.time() - 301))
        self.assertEqual(self.run_helper("--launch", "happy").returncode, 0)
        normal_lock = self.normal / "jobs/job/state.json"
        normal_lock.parent.mkdir(parents=True)
        shutil.copyfile(lock, normal_lock)
        self.assertEqual(self.run_helper("--launch", "happy").returncode, 0)

    def copied_launcher(self):
        tree = self.home / "workspace"
        shutil.copytree(ROOT, tree, ignore=shutil.ignore_patterns("__pycache__", "tests"))
        self.stub(tree / "bin/claude-auth-sync")
        (tree / "lib/vscode_restore.py").write_text("import json, os, sys\nfrom pathlib import Path\nPath(os.environ['HOME'], 'restore-args.json').write_text(json.dumps(sys.argv[1:]))\n")
        return tree

    def test_managed_create_and_idle_relaunch_resume_private_history(self):
        self.fixture_latest()
        shadow = self.history(A, {"type": "permission-mode"}, project=self.normal_project)
        before = shadow.read_bytes()
        tree = self.copied_launcher()
        for existing in (False, True):
            with self.subTest(existing=existing):
                env = {**self.env, **({"EXISTING": "1"} if existing else {})}
                result = subprocess.run(["/bin/bash", str(tree / "bin/claude-session"), "Personal"], env=env, text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.events("happy")[-1]["args"], ["--yolo", "--resume", B])
                self.assertEqual(self.events("happy")[-1]["config"], str(self.private))
                self.assertEqual(shadow.read_bytes(), before)
                self.assertEqual(self.marker.read_text(), C + "\n")
        restore = json.loads((self.home / "restore-args.json").read_text())
        self.assertEqual(restore[-1], "")

    def test_active_pane_only_attaches_and_wrong_config_fails(self):
        tree = self.copied_launcher()
        result = subprocess.run(["/bin/bash", str(tree / "bin/claude-session"), "Personal"], env={**self.env, "EXISTING": "1", "ACTIVE": "1"}, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events("happy"), [])
        self.assertFalse(any(e["args"][0] == "send-keys" for e in self.events("tmux")))
        result = subprocess.run(["/bin/bash", str(tree / "bin/claude-session"), "Personal"], env={**self.env, "CLAUDE_CONFIG_DIR": str(self.normal)}, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)

    def test_smart_resume_personal_routes_to_private_helper(self):
        self.fixture_latest()
        tree = self.copied_launcher()
        result = subprocess.run(["/bin/bash", str(tree / "bin/smart-resume.sh"), "Personal"], env={**self.env, "CLAUDE_CONFIG_DIR": str(self.normal)}, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events("happy")[-1]["args"], ["--yolo", "--resume", B])
        self.assertEqual(self.events("happy")[-1]["config"], str(self.private))

    def test_ordinary_spaced_session_keeps_existing_resume_path(self):
        tree = self.copied_launcher()
        name = "Team Pay"
        cwd = self.home / "claude-sessions" / name
        cwd.mkdir(parents=True)
        key = re.sub(r"[^A-Za-z0-9_-]", "-", str(cwd))
        self.history(A, message("2026-09-01T09:00:00+08:00"), project=self.normal / "projects" / key)
        (cwd / ".current-session").write_text(A + "\n")
        env = {**self.env, "CLAUDE_CONFIG_DIR": str(self.normal), "CLAUDE_LAUNCHER": "claude"}
        result = subprocess.run(["/bin/bash", str(tree / "bin/claude-session"), name], env=env, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events("claude")[-1]["args"], ["--dangerously-skip-permissions", "--resume", A])
        self.assertTrue((self.normal / "projects" / key / "simulated-write.jsonl").exists())

    def test_claude_personal_and_explicit_restore(self):
        self.fixture_latest()
        tree = self.copied_launcher()
        result = subprocess.run(["/bin/bash", str(tree / "bin/claude-session"), "Personal", A], env={**self.env, "CLAUDE_LAUNCHER": "claude"}, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events("claude")[-1]["args"], ["--dangerously-skip-permissions", "--resume", A])
        self.assertEqual(self.events("claude")[-1]["config"], str(self.private))
        self.assertEqual(json.loads((self.home / "restore-args.json").read_text())[-1], A)

    def test_personal_model_override_is_explicit_and_scoped(self):
        self.fixture_latest()
        model = "claude-fable-5-1[1m]"
        (self.private / "personal-launch.json").write_text(json.dumps({"model": model}))
        shared = self.normal / "settings.json"
        shared.write_text(json.dumps({"env": {"ANTHROPIC_MODEL": "claude-sonnet-5"}}))
        before = shared.read_bytes()
        tree = self.copied_launcher()
        for launcher in ("happy", "claude"):
            result = subprocess.run(["/bin/bash", str(tree / "bin/claude-session"), "Personal"], env={**self.env, "CLAUDE_LAUNCHER": launcher, "ANTHROPIC_MODEL": "claude-sonnet-5"}, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr)
            event = self.events(launcher)[-1]
            model_index = event["args"].index("--model")
            self.assertEqual(event["args"][model_index:model_index + 2], ["--model", model])
            if launcher == "happy":
                self.assertIn(f"--model={model}", event["args"])
            self.assertIn(B, event["args"])
            self.assertEqual(event["config"], str(self.private))
            self.assertEqual(shared.read_bytes(), before)
            self.assertEqual(self.marker.read_text(), C + "\n")

    def test_installed_happy_parser_passes_model_to_local_claude(self):
        self.fixture_latest()
        model = "claude-sonnet-5"
        local_model = "claude-fable-5-1"
        (self.private / "personal-launch.json").write_text(json.dumps({"model": model, "claudeModel": local_model}))
        result = self.run_helper("--launch", "happy")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.events("happy")[-1]["args"]
        node = shutil.which("node")
        self.assertIsNotNone(node, "installed Happy compatibility check requires node")
        modules = Path(node).resolve().parents[1] / "lib/node_modules"
        # npm 包 2026-10 起从 happy-coder 改名为 happy
        bundles = [p for p in (modules / "happy/dist").glob("index-*.mjs") if "const parsedSandboxFlag = extractNoSandboxFlag(args);" in p.read_text()]
        self.assertEqual(len(bundles), 1, "Happy CLI parser location changed; review compatibility")
        script = r'''
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[1], 'utf8');
const anchor = source.indexOf('const parsedSandboxFlag = extractNoSandboxFlag(args);');
const start = source.indexOf('for (let i = 0; i < args.length; i++) {', anchor);
const end = source.indexOf('if (unknownArgs.length > 0)', start);
if (anchor < 0 || start < 0 || end < 0) throw new Error('Happy parser not found');
const state = {args: JSON.parse(process.argv[2]), options: {}, unknownArgs: []};
vm.runInNewContext(source.slice(start, end), state, {timeout: 1000});
console.log(JSON.stringify({model: state.options.model, localArgs: state.unknownArgs}));
'''
        result = subprocess.run([node, "-e", script, str(bundles[0]), json.dumps(args)], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        parsed = json.loads(result.stdout)
        self.assertEqual(parsed["model"], model)
        self.assertIn(f"--model={local_model}", parsed["localArgs"])
        self.assertIn(B, parsed["localArgs"])
        native = modules / "@anthropic-ai/claude-code/bin/claude.exe"
        result = subprocess.run([str(native), f"--model={local_model}", "--help"], env={**self.env, "DISABLE_AUTOUPDATER": "1"}, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--model", result.stdout)

    def test_direct_claude_uses_claude_model_override(self):
        self.fixture_latest()
        (self.private / "personal-launch.json").write_text(json.dumps({"model": "claude-sonnet-5", "claudeModel": "claude-fable-5-1"}))
        result = self.run_helper("--launch", "claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events("claude")[-1]["args"][-2:], ["--model", "claude-fable-5-1"])
        self.assertIn(B, self.events("claude")[-1]["args"])

    def test_invalid_personal_model_cannot_launch(self):
        # 代理时代的路由别名（带斜杠、claude-ccr-*）在代理下线后指向死模型，必须拒绝
        self.fixture_latest()
        config = self.private / "personal-launch.json"
        for content in ("{", '{"model":"--bad-option"}', '{"model":"valid","claudeModel":[]}',
                        '{"model":"Codex API/gpt-6-astra"}', '{"model":"anthropic/claude-ccr-h00"}'):
            config.write_text(content)
            with self.subTest(content=content):
                self.assertNotEqual(self.run_helper("--launch", "happy").returncode, 0)
                self.assertEqual(self.events("happy"), [])

    def test_unpinned_personal_model_launches_without_model_flag(self):
        # 不配置或留空 = 不钉模型，沿用 settings.json，与其他会话一致
        self.fixture_latest()
        config = self.private / "personal-launch.json"
        for content in ("[]", "{}", '{"model":null}', '{"model":""}'):
            config.write_text(content)
            with self.subTest(content=content):
                result = self.run_helper("--launch", "happy")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("--model", self.events("happy")[-1]["args"])

    def test_personal_model_config_cannot_link_to_shared_root(self):
        target = self.normal / "model.json"
        target.write_text(json.dumps({"model": "claude-sonnet-5"}))
        (self.private / "personal-launch.json").symlink_to(target)
        self.assertNotEqual(self.run_helper("--check").returncode, 0)

    def test_private_context_file_rejects_shared_symlink(self):
        normal_flag = self.normal / "discuss-pending"
        normal_flag.write_text("NORMAL")
        (self.private / "discuss-pending").symlink_to(normal_flag)
        result = self.run_helper("--context-file", "discuss-pending")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(normal_flag.read_text(), "NORMAL")

    def test_post_compact_reads_only_private_status(self):
        for root, goal in ((self.private, "PRIVATE"), (self.normal, "NORMAL")):
            (root / "agent-status.json").write_text(json.dumps({"pipelines": {"one": {"stage": "working", "original_goal": goal}}}))
        result = subprocess.run(["/bin/bash", str(ROOT / "hooks/post-compact.sh")], env=self.env, capture_output=True, text=True, timeout=10)
        self.assertIn("PRIVATE", result.stdout)
        self.assertNotIn("NORMAL", result.stdout)

    def test_empty_report_marker_has_no_output(self):
        marker = self.private / "discuss-pending"
        for content in ("", "\n", "  \n"):
            marker.write_text(content)
            result = subprocess.run(["/bin/bash", str(ROOT / "hooks/discuss-check.sh")], env=self.env, cwd=self.home, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_concurrent_report_producer_cannot_be_deleted_by_consumer(self):
        spec = importlib.util.spec_from_file_location("report_state_test", ROOT / "lib/report_state.py")
        state = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(state)
        marker = self.private / "discuss-pending"
        state.update(marker, "report-A")
        read = Path.read_text
        reader_ready = threading.Event()
        release_reader = threading.Event()
        writer_started = threading.Event()

        def paused_read(path, *args, **kwargs):
            content = read(path, *args, **kwargs)
            if path == marker:
                reader_ready.set()
                if not release_reader.wait(3):
                    raise RuntimeError("test reader barrier timed out")
            return content

        def publish_b():
            writer_started.set()
            state.update(marker, "report-B")

        with patch.object(Path, "read_text", paused_read), ThreadPoolExecutor(max_workers=2) as pool:
            consumer = pool.submit(state.update, marker)
            self.assertTrue(reader_ready.wait(3))
            producer = pool.submit(publish_b)
            try:
                self.assertTrue(writer_started.wait(3))
                with self.assertRaises(TimeoutError):
                    producer.result(timeout=0.05)
            finally:
                release_reader.set()
            self.assertEqual(consumer.result(timeout=3), "report-A")
            producer.result(timeout=3)
        self.assertEqual(state.update(marker), "report-B")
        self.assertEqual(state.update(marker), "")

    def test_report_flags_cannot_be_consumed_across_configs(self):
        tree = self.copied_launcher()
        # Redirect ONLY the ordinary legacy /tmp flag into this test's HOME.
        normal_flag = self.home / "normal-pending"
        for script in ("detect-report.sh", "discuss-check.sh"):
            p = tree / "hooks" / script
            p.write_text(p.read_text().replace("/tmp/claude-discuss-pending", str(normal_flag)))
        for root, goal in ((self.private, "PRIVATE"), (self.normal, "NORMAL")):
            report = self.home / f"REPORT-{goal}.md"
            report.write_text(goal * 1000)
            env = {**self.env, "CLAUDE_CONFIG_DIR": str(root)}
            result = subprocess.run(["/bin/bash", str(tree / "hooks/detect-report.sh")], input=json.dumps({"tool_input": {"file_path": str(report)}}), env=env, cwd=self.home, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
        for root, expected, forbidden in ((self.normal, "NORMAL", "PRIVATE"), (self.private, "PRIVATE", "NORMAL")):
            result = subprocess.run(["/bin/bash", str(tree / "hooks/discuss-check.sh")], env={**self.env, "CLAUDE_CONFIG_DIR": str(root)}, cwd=self.home, capture_output=True, text=True, timeout=10)
            self.assertIn(expected, result.stdout)
            self.assertNotIn(forbidden, result.stdout)


if __name__ == "__main__":
    unittest.main()
