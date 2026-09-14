import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "github_preflight.py"
AUDIT = SCRIPT.with_name("audit-project-upload.sh")


def load_preflight():
    spec = importlib.util.spec_from_file_location("github_preflight", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GitHubPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="travel-cat-github-preflight-")
        self.addCleanup(self.temporary.cleanup)
        self.repo = Path(self.temporary.name) / "public source"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Boundary Test")
        self.git("config", "user.email", "boundary@example.invalid")
        self.write(
            ".gitignore",
            ".local/\n.env\n.env.*\n!.env.example\nconfig/deploy.local.json\n",
        )
        self.write("README.md", "public fixture\n")
        self.commit()
        self.initial_commit = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args, input_text=None):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            input=input_text,
            capture_output=True,
            text=True,
            check=True,
        )

    def write(self, path, contents):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(contents, bytes):
            target.write_bytes(contents)
        else:
            target.write_text(contents)
        return target

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def force_stage(self, path, contents):
        self.write(path, contents)
        self.git("add", "-f", "--", path)

    def run_cli(self, max_bytes=None):
        command = ["python3", str(SCRIPT), "--repository", str(self.repo)]
        if max_bytes is not None:
            command.extend(["--max-bytes", str(max_bytes)])
        return subprocess.run(command, capture_output=True, text=True)

    def violations(self, maximum=5 * 1024 * 1024):
        module = load_preflight()
        return module.check_repository(self.repo, max_bytes=maximum)

    def assert_code(self, expected, maximum=5 * 1024 * 1024):
        self.assertIn(expected, {violation.code for violation in self.violations(maximum)})

    def test_clean_index_and_ignored_local_config_pass_without_deleting_local_file(self):
        private = self.write(".local/deploy.json", '{"apiToken":"LOCAL-ONLY"}\n')
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.violations(), [])
        self.assertTrue(private.is_file())
        self.assertEqual(private.read_text(), '{"apiToken":"LOCAL-ONLY"}\n')

    def test_forced_staged_private_deployment_files_are_refused_without_echoing_secrets(self):
        secret = "AKIA" + "IOSFODNN7EXAMPLE"
        for path in (".local/deploy.json", "config/deploy.local.json"):
            with self.subTest(path=path):
                self.git("reset", "-q", "--hard", self.initial_commit)
                self.force_stage(path, '{"apiToken":"' + secret + '"}\n')
                result = self.run_cli()
                self.assertEqual(result.returncode, 65)
                self.assertNotIn(secret, result.stdout + result.stderr)
                self.assertTrue((self.repo / path).is_file())
                self.assert_code("private-path")

    def test_committed_private_deployment_files_are_refused_from_the_whole_index(self):
        secret = "ghp_" + "abcdefghijklmnopqrstuvwxyz0123456789"
        for path in (".local/deploy.json", "config/deploy.local.json"):
            with self.subTest(path=path):
                self.git("reset", "-q", "--hard", self.initial_commit)
                self.force_stage(path, '{"token":"' + secret + '"}\n')
                self.git("commit", "-qm", "must remain private")
                result = self.run_cli()
                self.assertEqual(result.returncode, 65)
                self.assertNotIn(secret, result.stdout + result.stderr)
                self.assert_code("private-path")

    def test_credential_containers_and_high_confidence_secret_content_are_refused(self):
        cases = {
            ".env.production": "OPENAI_API_KEY=" + "sk-" + "live-fixture\n",
            "config/service-account.json": '{"private_key":"fixture"}\n',
            "Sources/private.swift": 'let key = "' + "AKIA" + 'IOSFODNN7EXAMPLE"\n',
            "Fixtures/key.txt": "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nfixture\n",
        }
        for path, contents in cases.items():
            with self.subTest(path=path):
                self.git("reset", "-q", "--hard", self.initial_commit)
                self.force_stage(path, contents)
                result = self.run_cli()
                self.assertEqual(result.returncode, 65)
                self.assertNotIn(contents.strip(), result.stdout + result.stderr)
                self.assertTrue(self.violations())

    def test_generated_app_data_and_build_paths_are_refused_even_when_committed(self):
        for path in (
            ".build/cache.bin",
            ".swiftpm/cache.bin",
            "DerivedData/cache.bin",
            "TravelPetData/state.json",
            "dist/Travel Cat.app/Contents/Info.plist",
            "Artifacts/Test.xcresult/result.json",
        ):
            with self.subTest(path=path):
                self.git("reset", "-q", "--hard", self.initial_commit)
                self.force_stage(path, "generated fixture\n")
                self.git("commit", "-qm", "generated entry")
                self.assert_code("generated-path")
                self.assertEqual(self.run_cli().returncode, 65)

    def test_symlink_gitlink_and_unresolved_index_stages_are_refused(self):
        link = self.repo / "Sources/link"
        link.parent.mkdir(parents=True)
        link.symlink_to("missing-private-target")
        self.git("add", "--", "Sources/link")
        self.assert_code("nonregular-mode")

        self.git("reset", "-q", "--hard", self.initial_commit)
        commit = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("update-index", "--add", "--cacheinfo", f"160000,{commit},Sources/module")
        self.assert_code("nonregular-mode")

        self.git("reset", "-q", "--hard", self.initial_commit)
        blob = self.git("hash-object", "-w", "--stdin", input_text="conflict\n").stdout.strip()
        self.git("update-index", "--index-info", input_text=f"100644 {blob} 1\tSources/conflict.swift\n")
        self.assert_code("unresolved-index")

    def write_asset_policy(self, path, contents, reason="fixture approved public asset"):
        policy = {
            "schemaVersion": 1,
            "assets": [
                {
                    "path": path,
                    "bytes": len(contents),
                    "sha256": hashlib.sha256(contents).hexdigest(),
                    "reason": reason,
                }
            ],
        }
        self.write("config/public-assets.json", json.dumps(policy) + "\n")

    def test_oversized_formal_asset_requires_exact_valid_policy_entry(self):
        asset_path = "Sources/TravelUI/Resources/fixture.bin"
        contents = b"x" * 2048
        self.write(asset_path, contents)
        self.write_asset_policy(asset_path, contents)
        self.commit()
        self.assertEqual(self.violations(maximum=1024), [])

        blob = self.git("hash-object", "-w", "--stdin", input_text="tampered\n").stdout.strip()
        self.git("update-index", "--cacheinfo", f"100644,{blob},{asset_path}")
        self.assert_code("approved-asset-mismatch", maximum=1024)

    def test_missing_or_malformed_asset_policy_fails_closed_at_the_default_cap(self):
        asset_path = "Sources/TravelUI/Resources/fixture.bin"
        self.force_stage(asset_path, b"x" * 2048)
        self.assert_code("oversized-blob", maximum=1024)

        self.write("config/public-assets.json", "not-json\n")
        self.git("add", "config/public-assets.json")
        self.assert_code("malformed-asset-policy", maximum=1024)

    def test_public_demo_and_schema_are_allowed(self):
        self.write("config/deploy.demo.json", json.dumps(self.demo()) + "\n")
        self.write("config/deploy.schema.json", '{"type":"object"}\n')
        self.write(".env.example", "API_TOKEN=replace-me\n")
        self.commit()
        self.assertEqual(self.violations(), [])
        self.assertEqual(self.run_cli().returncode, 0)

    def test_committed_logs_only_allowed_in_exact_formal_trees(self):
        for suffix in ("log", "out", "err"):
            for directory in ("Scripts", "assets"):
                with self.subTest(directory=directory, suffix=suffix):
                    self.git("reset", "-q", "--hard", self.initial_commit)
                    self.write(f"{directory}/debug.{suffix}", "fixture\n")
                    self.commit()
                    self.assert_code("generated-path")
            for directory in ("Assets", "Fixtures", "Tests/Fixtures", "Sources/TravelUI/Resources"):
                with self.subTest(directory=directory, suffix=suffix):
                    self.git("reset", "-q", "--hard", self.initial_commit)
                    self.write(f"{directory}/example.{suffix}", "fixture\n")
                    self.commit()
                    self.assertEqual(self.violations(), [])

    @staticmethod
    def demo():
        return {"schemaVersion": 2, "applicationDirectory": "~/Applications",
                "dataRoot": "~/Library/Application Support/TravelCat/TravelPetData"}

    def test_demo_requires_exact_schema_and_home_relative_paths(self):
        cases = [{}, {**self.demo(), "schemaVersion": True},
                 {**self.demo(), "schemaVersion": 1},
                 {**self.demo(), "unrecognized": "value"}]
        for value in ("/opt/private", "relative/path", "~/../private", "~other/private", 12):
            cases.append({**self.demo(), "dataRoot": value})
        for document in cases:
            with self.subTest(document=document):
                self.write("config/deploy.demo.json", json.dumps(document))
                self.git("add", "config/deploy.demo.json")
                self.assert_code("unsafe-demo-config")

    def test_demo_rejects_duplicate_keys(self):
        document = json.dumps(self.demo())
        self.write("config/deploy.demo.json", document[:-1] + ',"schemaVersion":1}')
        self.git("add", "config/deploy.demo.json")
        self.assert_code("unsafe-demo-config")

    def test_legacy_public_demo_remains_valid_for_existing_committed_source(self):
        value = dict(self.demo(), schemaVersion=1, codexHome="~/.codex")
        self.write("config/deploy.demo.json", json.dumps(value))
        self.git("add", "config/deploy.demo.json")
        self.assertEqual(self.violations(), [])

    def test_public_demo_rejects_private_fields_and_personal_absolute_paths(self):
        cases = (
            {"mode": "demo", "apiToken": "must-remain-local"},
            {"mode": "demo", "output": "/Users/example/TravelCat"},
        )
        for document in cases:
            with self.subTest(document=document):
                self.git("reset", "-q", "--hard", self.initial_commit)
                self.write("config/deploy.demo.json", json.dumps(document) + "\n")
                self.git("add", "config/deploy.demo.json")
                self.assert_code("unsafe-demo-config")
                self.assertEqual(self.run_cli().returncode, 65)

    def test_upload_audit_reuses_the_whole_index_preflight(self):
        scripts = self.repo / "Scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copy2(AUDIT, scripts / AUDIT.name)
        shutil.copy2(SCRIPT, scripts / SCRIPT.name)
        self.force_stage("config/deploy.local.json", '{"token":"local-only"}\n')
        self.git("add", "Scripts")
        self.git("commit", "-qm", "committed private boundary fixture")

        result = subprocess.run(
            [str(scripts / AUDIT.name)], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertNotIn("local-only", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
