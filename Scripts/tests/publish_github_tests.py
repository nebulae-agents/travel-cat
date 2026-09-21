import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "publish_github.py"
ENTRY = ROOT / "Publish to GitHub.command"


def load_publisher():
    spec = importlib.util.spec_from_file_location("publish_github", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def completed(arguments, returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(arguments, returncode, stdout, stderr)


class RecordingRuntime:
    """Run Git locally while recording all GitHub-facing commands."""

    def __init__(self, repo):
        self.repo = repo
        self.tools = {"git", "gh"}
        self.interactive = True
        self.auth_ok = True
        self.create_returncode = 0
        self.push_returncode = 0
        self.create_adds_remote = True
        self.view_owner = None
        self.view_visibility = "PRIVATE"
        self.audit_count = 0
        self.change_on_audit = None
        self.calls = []

    def which(self, name):
        return f"/fixture/{name}" if name in self.tools else None

    def is_interactive(self):
        return self.interactive

    def run(self, arguments, *, cwd=None, env=None):
        command = tuple(str(item) for item in arguments)
        self.calls.append((command, dict(env) if env is not None else None))

        if command[0].endswith("audit-project-upload.sh"):
            self.audit_count += 1
            if self.change_on_audit == self.audit_count:
                (self.repo / "race.txt").write_text("changed during confirmation\n")
                self._git("add", "race.txt")
                self._git("commit", "-qm", "racing commit")
            return completed(command, stdout="upload-audit: status=ok\n")

        if command[:3] == ("gh", "auth", "status"):
            return completed(command, 0 if self.auth_ok else 1,
                             stderr="fixture authentication status\n")

        if command[:3] == ("gh", "repo", "view"):
            if self.view_owner is None:
                return completed(command, 1, stderr="fixture repository lookup failed\n")
            payload = json.dumps({
                "nameWithOwner": self.view_owner,
                "visibility": self.view_visibility,
            })
            return completed(command, stdout=payload + "\n")

        if command[:3] == ("gh", "repo", "create"):
            if self.create_returncode != 0:
                return completed(command, self.create_returncode,
                                 stderr="fixture creation failed\n")
            if self.create_adds_remote:
                target = command[3]
                self._git("remote", "add", "origin", f"https://github.com/{target}.git")
                self.view_owner = target
                self.view_visibility = "PUBLIC" if "--public" in command else "PRIVATE"
            return completed(command, stdout="fixture repository created\n")

        if command[:2] == ("git", "push"):
            return completed(command, self.push_returncode,
                             stderr="fixture push failed\n" if self.push_returncode else "")

        if command[0] == "git":
            return subprocess.run(
                command,
                cwd=cwd,
                env=env,
                capture_output=True,
                text=True,
            )
        raise AssertionError(f"unexpected command: {command!r}")

    def _git(self, *arguments):
        return subprocess.run(
            ["git", *arguments], cwd=self.repo, check=True,
            capture_output=True, text=True,
        )

    def commands(self, prefix):
        return [command for command, _ in self.calls if command[:len(prefix)] == prefix]


class PublishGitHubTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="travel-cat-publish-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "source project with spaces"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "publish-test")
        # These tiny test repositories are copied as snapshots. Background Git
        # maintenance can remove its lock while copytree is reading .git.
        self.git("config", "maintenance.auto", "false")
        self.git("config", "gc.auto", "0")
        self.git("config", "user.name", "Publish Boundary Test")
        self.git("config", "user.email", "publish@example.invalid")
        self.write("README.md", "public fixture\n")
        self.commit("initial")
        self.runtime = RecordingRuntime(self.repo)

    def test_fixture_disables_background_git_maintenance_before_snapshots(self):
        self.assertEqual(self.git("config", "--bool", "maintenance.auto").stdout.strip(), "false")
        self.assertEqual(self.git("config", "gc.auto").stdout.strip(), "0")

    def git(self, *arguments):
        return subprocess.run(
            ["git", *arguments], cwd=self.repo, check=True,
            capture_output=True, text=True,
        )

    def write(self, path, contents):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)
        return target

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)

    def run_publish(self, *answers):
        publisher = load_publisher()
        answer_iter = iter(answers)
        stdout = io.StringIO()
        stderr = io.StringIO()
        status = publisher.publish(
            repository=self.repo,
            runtime=self.runtime,
            input_fn=lambda _prompt: next(answer_iter),
            stdout=stdout,
            stderr=stderr,
        )
        return status, stdout.getvalue() + stderr.getvalue()

    def mutation_commands(self):
        return (
            self.runtime.commands(("gh", "repo", "create"))
            + self.runtime.commands(("git", "push"))
        )

    def test_missing_tools_and_missing_login_stop_without_mutation(self):
        for missing in ("git", "gh"):
            with self.subTest(missing=missing):
                self.runtime.tools.remove(missing)
                status, output = self.run_publish()
                self.runtime.tools.add(missing)
                self.assertNotEqual(status, 0)
                self.assertIn(missing, output.lower())
                self.assertEqual(self.mutation_commands(), [])

        self.runtime.auth_ok = False
        status, output = self.run_publish()
        self.assertNotEqual(status, 0)
        self.assertIn("gh auth login", output)
        self.assertEqual(self.mutation_commands(), [])
        auth = self.runtime.commands(("gh", "auth", "status"))
        self.assertEqual(auth, [("gh", "auth", "status", "--active", "--hostname", "github.com")])
        self.assertNotIn("--json", auth[0])

    def test_noninteractive_entry_stops_without_mutation(self):
        self.runtime.interactive = False
        status, output = self.run_publish()
        self.assertNotEqual(status, 0)
        self.assertIn("interactive", output.lower())
        self.assertEqual(self.mutation_commands(), [])

    def test_cancel_does_nothing(self):
        status, output = self.run_publish("good-owner/good-repo", "", "no")
        self.assertEqual(status, 0, output)
        self.assertIn("cancel", output.lower())
        self.assertEqual(self.mutation_commands(), [])
        self.assertEqual(self.git("remote").stdout, "")

    def test_invalid_owner_repository_names_are_rejected(self):
        invalid = (
            "owner", "owner/repo/extra", "/repo", "owner/", "owner name/repo",
            "owner/repo.git", "owner@evil/repo", "owner/repo?x=1", "OWNER//repo",
        )
        for target in invalid:
            with self.subTest(target=target):
                status, output = self.run_publish(target)
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.mutation_commands(), [])

    def test_first_publish_defaults_private_and_pushes_only_captured_commit(self):
        captured = self.git("rev-parse", "HEAD").stdout.strip()
        with mock.patch.dict(os.environ, {"GH_HOST": "evil.invalid", "GH_REPO": "wrong/repo"}):
            status, output = self.run_publish("good-owner/good-repo", "", "yes")
        self.assertEqual(status, 0, output)
        create = self.runtime.commands(("gh", "repo", "create"))
        self.assertEqual(create, [(
            "gh", "repo", "create", "good-owner/good-repo", "--private",
            "--source", str(self.repo.resolve()), "--remote", "origin",
        )])
        self.assertNotIn("--push", create[0])
        push = self.runtime.commands(("git", "push"))
        self.assertEqual(push, [(
            "git", "push", "--no-follow-tags", "origin",
            f"{captured}:refs/heads/publish-test",
        )])
        for command, env in self.runtime.calls:
            if command[0] == "gh":
                self.assertEqual(env["GH_HOST"], "github.com")
                self.assertNotIn("GH_REPO", env)
        self.assertIn("private", output.lower())
        self.assertIn(captured, output)

    def test_public_must_be_selected_explicitly(self):
        status, output = self.run_publish("good-owner/good-repo", "public", "yes")
        self.assertEqual(status, 0, output)
        create = self.runtime.commands(("gh", "repo", "create"))[0]
        self.assertIn("--public", create)
        self.assertNotIn("--private", create)

    def test_existing_origin_is_verified_then_receives_one_explicit_push(self):
        self.git("remote", "add", "origin", "git@github.com:good-owner/good-repo.git")
        self.runtime.view_owner = "good-owner/good-repo"
        self.runtime.view_visibility = "PUBLIC"
        captured = self.git("rev-parse", "HEAD").stdout.strip()
        status, output = self.run_publish("yes")
        self.assertEqual(status, 0, output)
        self.assertEqual(self.runtime.commands(("gh", "repo", "create")), [])
        self.assertEqual(self.runtime.commands(("git", "push")), [(
            "git", "push", "--no-follow-tags", "origin",
            f"{captured}:refs/heads/publish-test",
        )])
        view = self.runtime.commands(("gh", "repo", "view"))
        self.assertEqual(view, [(
            "gh", "repo", "view", "good-owner/good-repo",
            "--json", "nameWithOwner,visibility",
        )])
        self.assertIn("public", output.lower())

    def test_unexpected_remote_push_url_rewrite_and_mirror_are_rejected(self):
        cases = ("extra", "pushurl", "rewrite", "mirror")
        for case in cases:
            with self.subTest(case=case):
                with tempfile.TemporaryDirectory(prefix="travel-cat-remote-") as temporary:
                    repo = Path(temporary) / "repo"
                    shutil.copytree(self.repo, repo)
                    subprocess.run(["git", "remote", "add", "origin",
                                   "https://github.com/good-owner/good-repo.git"],
                                   cwd=repo, check=True)
                    if case == "extra":
                        subprocess.run(["git", "remote", "add", "backup",
                                       "https://github.com/good-owner/backup.git"], cwd=repo, check=True)
                    elif case == "pushurl":
                        subprocess.run(["git", "remote", "set-url", "--push", "origin",
                                       "https://github.com/good-owner/other.git"], cwd=repo, check=True)
                    elif case == "rewrite":
                        subprocess.run(["git", "config", "url.https://evil.invalid/.insteadOf",
                                       "https://github.com/"], cwd=repo, check=True)
                    else:
                        subprocess.run(["git", "config", "remote.origin.mirror", "true"],
                                       cwd=repo, check=True)
                    runtime = RecordingRuntime(repo)
                    publisher = load_publisher()
                    status = publisher.publish(
                        repository=repo, runtime=runtime, input_fn=lambda _prompt: "yes",
                        stdout=io.StringIO(), stderr=io.StringIO(),
                    )
                    self.assertNotEqual(status, 0)
                    mutations = runtime.commands(("gh", "repo", "create")) + runtime.commands(("git", "push"))
                    self.assertEqual(mutations, [])

    def test_dirty_detached_and_changed_head_are_rejected(self):
        self.write("untracked.txt", "dirty\n")
        status, _ = self.run_publish()
        self.assertNotEqual(status, 0)
        self.assertEqual(self.mutation_commands(), [])

        self.git("clean", "-f", "untracked.txt")
        self.git("checkout", "--detach", "-q")
        status, _ = self.run_publish()
        self.assertNotEqual(status, 0)
        self.assertEqual(self.mutation_commands(), [])

        self.git("switch", "-q", "publish-test")
        self.runtime.change_on_audit = self.runtime.audit_count + 2
        status, output = self.run_publish("good-owner/good-repo", "", "yes")
        self.assertNotEqual(status, 0, output)
        self.assertEqual(self.mutation_commands(), [])

    def test_private_paths_in_reachable_history_are_rejected_after_removal(self):
        for private_path in ("config/deploy.local.json", "archive/account.key", "TravelPetData/state.json"):
            with self.subTest(private_path=private_path):
                self.git("reset", "--hard", "-q", "HEAD")
                self.write(private_path, "fixture-private-value\n")
                self.git("add", "-f", private_path)
                self.commit("add forbidden historical path")
                self.git("rm", "-q", private_path)
                self.commit("remove forbidden historical path")
                status, output = self.run_publish()
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.mutation_commands(), [])
                self.git("reset", "--hard", "-q", "HEAD~2")

    def test_shallow_history_is_rejected(self):
        self.git("config", "extensions.worktreeConfig", "false")
        shallow = self.repo / ".git" / "shallow"
        shallow.write_text(self.git("rev-parse", "HEAD").stdout)
        status, output = self.run_publish()
        self.assertNotEqual(status, 0, output)
        self.assertIn("history", output.lower())
        self.assertEqual(self.mutation_commands(), [])

    def test_failed_create_never_pushes_and_preserves_created_remote(self):
        self.runtime.create_returncode = 1
        status, output = self.run_publish("good-owner/good-repo", "", "yes")
        self.assertNotEqual(status, 0, output)
        self.assertEqual(self.runtime.commands(("git", "push")), [])
        self.assertEqual(self.git("remote").stdout, "")

        self.runtime.create_returncode = 0
        self.runtime.create_adds_remote = True
        original_run = self.runtime.run

        def create_then_fail(arguments, **kwargs):
            result = original_run(arguments, **kwargs)
            if tuple(arguments[:3]) == ("gh", "repo", "create"):
                return completed(arguments, 1, stderr="post-create fixture failure\n")
            return result

        self.runtime.run = create_then_fail
        status, output = self.run_publish("good-owner/good-repo", "", "yes")
        self.assertNotEqual(status, 0, output)
        self.assertIn("retained", output.lower())
        self.assertEqual(self.git("remote").stdout.strip(), "origin")
        self.assertEqual(self.runtime.commands(("git", "push")), [])

    def test_failed_push_is_last_mutation_and_reports_retained_state(self):
        self.git("remote", "add", "origin", "https://github.com/good-owner/good-repo.git")
        self.runtime.view_owner = "good-owner/good-repo"
        self.runtime.push_returncode = 1
        status, output = self.run_publish("yes")
        self.assertNotEqual(status, 0, output)
        self.assertIn("retained", output.lower())
        push_index = next(index for index, (command, _) in enumerate(self.runtime.calls)
                          if command[:2] == ("git", "push"))
        self.assertEqual(self.runtime.calls[push_index + 1:], [])


    def test_unsafe_raw_push_urls_cannot_be_hidden_by_rewriting(self):
        safe = "https://github.com/good-owner/good-repo.git"
        self.git("remote", "add", "origin", safe)
        self.runtime.view_owner = "good-owner/good-repo"
        for raw in ("https://evil.invalid/good-owner/good-repo.git",
                    "https://user:fixture@github.com/good-owner/good-repo.git",
                    "https://github.com/other-owner/other-repo.git"):
            with self.subTest(raw=raw):
                self.runtime.calls.clear()
                self.git("remote", "set-url", "--push", "origin", raw)
                self.git("config", "url." + safe + ".insteadOf", raw)
                self.assertEqual(self.git("remote", "get-url", "--push", "origin").stdout.strip(), safe)
                status, output = self.run_publish("yes")
                self.assertNotEqual(status, 0, output)
                self.assertEqual(self.mutation_commands(), [])

    def test_valid_raw_push_url_is_part_of_the_snapshot(self):
        self.git("remote", "add", "origin", "https://github.com/good-owner/good-repo.git")
        raw = "git@github.com:good-owner/good-repo.git"
        self.git("remote", "set-url", "--push", "origin", raw)
        self.runtime.view_owner = "good-owner/good-repo"
        publisher = load_publisher()
        snapshot = publisher._inspect_remote(self.runtime, self.repo, "publish-test")
        self.assertEqual(snapshot["raw_push"], (raw,))
        status, output = self.run_publish("yes")
        self.assertEqual(status, 0, output)
        self.assertEqual(len(self.runtime.commands(("git", "push"))), 1)

    def test_replacement_and_grafts_cannot_hide_private_ancestors(self):
        original_repo, original_runtime = self.repo, self.runtime
        for mode in ("replace", "custom_replace", "graft", "custom_graft"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory(prefix="travel-cat-history-") as temporary:
                self.repo = Path(temporary) / "repo"
                shutil.copytree(original_repo, self.repo)
                self.runtime = RecordingRuntime(self.repo)
                try:
                    initial = self.git("rev-parse", "HEAD").stdout.strip()
                    self.write(".local/deploy.json", "private fixture\n")
                    self.commit("private ancestor")
                    self.git("rm", ".local/deploy.json")
                    self.git("commit", "-qm", "remove private fixture")
                    tip = self.git("rev-parse", "HEAD").stdout.strip()
                    environment = {}
                    if mode == "replace":
                        self.git("replace", tip, initial)
                    elif mode == "custom_replace":
                        self.git("update-ref", "refs/private-replace/" + tip, initial)
                        environment["GIT_REPLACE_REF_BASE"] = "refs/private-replace/"
                    else:
                        path = ".git/info/grafts" if mode == "graft" else ".git/private-grafts"
                        graft = self.write(path, tip + "\n")
                        if mode == "custom_graft":
                            environment["GIT_GRAFT_FILE"] = str(graft)
                    with mock.patch.dict(os.environ, environment):
                        status, output = self.run_publish("good-owner/good-repo", "", "yes")
                    self.assertNotEqual(status, 0, output)
                    self.assertEqual(self.mutation_commands(), [])
                finally:
                    self.repo, self.runtime = original_repo, original_runtime


class PublishArtifactsTests(unittest.TestCase):
    def test_real_entry_forwards_help_without_a_terminal_or_login(self):
        with tempfile.TemporaryDirectory(prefix="travel cat help ") as temporary:
            result = subprocess.run([str(ENTRY), "--help"], cwd=temporary,
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("usage:", result.stdout)
        self.assertNotIn("interactive Terminal", result.stderr)

    def test_command_entry_is_executable_and_directory_independent_with_spaces(self):
        self.assertTrue(ENTRY.is_file())
        self.assertTrue(ENTRY.stat().st_mode & stat.S_IXUSR)
        with tempfile.TemporaryDirectory(prefix="travel cat entry ") as temporary:
            base = Path(temporary)
            project = base / "project with spaces"
            scripts = project / "Scripts"
            fake_bin = base / "fake bin"
            scripts.mkdir(parents=True)
            fake_bin.mkdir()
            shutil.copy2(ENTRY, project / ENTRY.name)
            (scripts / "publish_github.py").write_text("# marker\n")
            record = base / "arguments.txt"
            python = fake_bin / "python3"
            python.write_text("#!/bin/zsh\nprint -r -- \"$1\" > \"$PUBLISH_RECORD\"\n")
            python.chmod(0o755)
            env = dict(os.environ, PATH=f"{fake_bin}:/usr/bin:/bin", PUBLISH_RECORD=str(record))
            result = subprocess.run([str(project / ENTRY.name)], cwd=base,
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(record.read_text().strip(), str((scripts / "publish_github.py").resolve()))

    def test_ci_and_public_guidance_encode_the_supported_boundary(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job_environment, steps = workflow.split("    steps:", 1)
        self.assertNotIn("${{ runner.temp }}", job_environment)
        self.assertIn('echo "TRAVEL_CAT_SCRATCH_ROOT=$RUNNER_TEMP/travel-cat-swift" >> "$GITHUB_ENV"', steps)
        for name in ("Python source contracts", "Upload tooling contracts", "Plugin contracts",
                     "Skill contracts", "Agent contracts", "Swift tests (UTC)",
                     "Prompt tests (Asia/Shanghai)", "Public upload audit"):
            self.assertIn("- name: " + name, steps)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("runs-on: macos-15", workflow)
        self.assertIn("actions/checkout@v7", workflow)
        self.assertIn("/Applications/Xcode_26.2.app/Contents/Developer", workflow)
        self.assertIn("Scripts/travel-cat-swift.sh test", workflow)
        self.assertNotIn("TRAVEL_CAT_LIVE_JOURNEY_ACCEPTANCE: 1", workflow)

        readme = (ROOT / "README.md").read_text()
        for expected in ("Deploy Local.command", "Publish to GitHub.command", "gh auth login",
                         "Swift 6.2", "Python 3", "Node.js", "临时签名", "许可证"):
            self.assertIn(expected, readme)
        security = (ROOT / "SECURITY.md").read_text()
        for expected in ("TravelPetData", ".local", "凭据", "公开"):
            self.assertIn(expected, security)
        contributing = (ROOT / "CONTRIBUTING.md").read_text()
        for expected in ("Scripts/travel-cat-swift.sh test", "Scripts/audit-project-upload.sh",
                         "Assets", "Fixtures", "TravelPetData"):
            self.assertIn(expected, contributing)


if __name__ == "__main__":
    unittest.main()
