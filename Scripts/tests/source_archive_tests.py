import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile


EXPORTER = Path(__file__).resolve().parents[1] / "export-source.py"


class SourceArchiveTests(unittest.TestCase):
    def test_public_ignore_rules_keep_formal_postcard_fixtures(self):
        public_root = EXPORTER.parent.parent
        self.write(".gitignore", (public_root / ".gitignore").read_text())
        for path, ignored in (("postcards/private.png", True),
                              ("Fixtures/Postcards/accepted-first.webp", False)):
            result = subprocess.run(["git", "-C", str(self.repo), "-c", "core.excludesFile=/dev/null",
                                     "check-ignore", "--no-index", "--", path],
                                    capture_output=True, text=True)
            self.assertIn(result.returncode, (0, 1))
            self.assertEqual(result.returncode == 0, ignored, path)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="travel-cat-source-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.repo = self.base / "project with spaces"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "test@example.invalid")
        self.files = {
            "Package.swift": "// fixture\n",
            "README.md": "Candidate fixture\n",
            "LICENSE": "Apache License\nVersion 2.0\n",
            "NOTICE": "Travel Cat contributors\n",
            "AGENTS.md": "Public contributor guidance\n",
            ".gitignore": "TravelPetData/\ndist/\n.local/\nconfig/deploy.local.json\n",
            "Plugins/travel-cat/.codex-plugin/plugin.json": '{"name":"travel-cat"}',
            "Sources/TravelUI/Resources/pet.json": "{}",
            "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp": "fixture bytes",
            "Sources/TravelUI/Resources/retained.log": "resource fixture",
            "Tests/example.swift": "// regression",
            "Sources/TravelUI/PostcardPreparation.swift": "// shared preparation",
            "Sources/TravelStorage/GeneratedPostcardImageReader.swift": "// bounded reader",
            "Automation/schemas/postcard-preparation.schema.json": '{"oneOf":[]}',
            ".agents/skills/travel-cat-agent/references/postcard-preparation.schema.json": '{"oneOf":[]}',
            "Plugins/travel-cat/skills/travel-cat-heartbeat/references/postcard-preparation.schema.json": '{"oneOf":[]}',
            "Fixtures/example.err": "retained fixture",
            "Scripts/tool.sh": "#!/bin/sh\nexit 0\n",
            "Scripts/publish_github.py": "#!/usr/bin/env python3\n",
            "Publish to GitHub.command": "#!/bin/zsh\n",
            "Deploy Local.command": "#!/bin/zsh\n",
            "CONTRIBUTING.md": "Public contribution boundaries\n",
            "SECURITY.md": "Public security reporting boundaries\n",
            ".github/workflows/ci.yml": "name: CI\n",
            ".github/ISSUE_TEMPLATE/bug_report.yml": "name: Bug report\n",
            "config/deploy.demo.json": '{"schemaVersion":2,"applicationDirectory":"~/Applications","dataRoot":"~/Library/Application Support/TravelCat/TravelPetData"}',
            "config/deploy.schema.json": '{"type":"object"}',
            "config/public-assets.json": '{"schemaVersion":1,"assets":[]}',
            "Automation/provenance/old.provenance": "not transferable",
            "docs/verification/personal.md": "not public",
        }
        for name, value in self.files.items():
            self.write(name, value)
        (self.repo / "Scripts/tool.sh").chmod(0o755)
        (self.repo / "Scripts/publish_github.py").chmod(0o755)
        (self.repo / "Publish to GitHub.command").chmod(0o755)
        (self.repo / "Deploy Local.command").chmod(0o755)
        self.commit()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True)

    def write(self, path, contents):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)
        return target

    def commit(self):
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")

    def export(self, filename="source.zip"):
        self.assertTrue(EXPORTER.is_file(), "The clean source exporter must exist")
        output = self.base / filename
        result = subprocess.run(["python3", str(EXPORTER), "--source", str(self.repo), str(output)],
                                capture_output=True, text=True)
        return result, output

    def test_allowlist_preserves_resources_and_omits_private_generated_files(self):
        self.write("TravelPetData/private.json", "private")
        self.write("dist/generated.log", "temporary")
        result, output = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        with zipfile.ZipFile(output) as archive:
            names = archive.namelist()
            for path in ["Package.swift", "Fixtures/example.err", "Sources/TravelUI/Resources/retained.log"]:
                self.assertIn("TravelCat/" + path, names)
            for path in (
                "Publish to GitHub.command", "Deploy Local.command",
                "Scripts/publish_github.py", "CONTRIBUTING.md", "SECURITY.md",
                ".github/workflows/ci.yml", ".github/ISSUE_TEMPLATE/bug_report.yml",
                "config/deploy.demo.json",
                "LICENSE", "NOTICE",
                "Sources/TravelUI/PostcardPreparation.swift",
                "Sources/TravelStorage/GeneratedPostcardImageReader.swift",
                "Automation/schemas/postcard-preparation.schema.json",
                ".agents/skills/travel-cat-agent/references/postcard-preparation.schema.json",
                "Plugins/travel-cat/skills/travel-cat-heartbeat/references/postcard-preparation.schema.json",
            ):
                self.assertIn("TravelCat/" + path, names)
            self.assertFalse(any("TravelPetData/" in p or "/.git/" in p or "provenance" in p
                                 or "personal.md" in p or "/dist/" in p for p in names))
            self.assertEqual(archive.getinfo("TravelCat/Scripts/tool.sh").external_attr >> 16, 0o100755)
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        self.assertEqual(Path(str(output) + ".sha256").read_text(), f"{digest}  {output.name}\n")

    def test_dirty_source_is_rejected(self):
        self.write("Sources/new.swift", "// unreviewed")
        result, output = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_public_demo_is_exported_but_committed_local_deploy_config_is_refused(self):
        clean_result, output = self.export()
        self.assertEqual(clean_result.returncode, 0, clean_result.stderr)
        with zipfile.ZipFile(output) as archive:
            self.assertIn("TravelCat/config/deploy.demo.json", archive.namelist())
            self.assertIn("TravelCat/config/deploy.schema.json", archive.namelist())
            self.assertIn("TravelCat/config/public-assets.json", archive.namelist())
            self.assertIn("TravelCat/AGENTS.md", archive.namelist())

        output.unlink()
        Path(str(output) + ".sha256").unlink()
        self.write("config/deploy.local.json", '{"apiToken":"must-not-print"}\n')
        self.git("add", "-f", "config/deploy.local.json")
        self.git("commit", "-qm", "private fixture")
        refused, output = self.export()
        self.assertNotEqual(refused.returncode, 0)
        self.assertNotIn("must-not-print", refused.stdout + refused.stderr)
        self.assertFalse(output.exists())

    def test_ignored_local_config_is_retained_and_not_exported(self):
        private = self.write(".local/deploy.json", '{"apiToken":"local-only"}\n')
        result, output = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(private.is_file())
        self.assertEqual(private.read_text(), '{"apiToken":"local-only"}\n')
        with zipfile.ZipFile(output) as archive:
            self.assertFalse(any("/.local/" in name for name in archive.namelist()))

    def test_committed_symlink_is_rejected_without_reading_its_target(self):
        (self.repo / "Sources/link").symlink_to(self.base / "missing-private-target")
        self.commit()
        result, output = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_personal_runtime_path_is_rejected(self):
        self.write("Scripts/bad.sh", "exec /Users/example/Applications/private\n")
        self.commit()
        result, output = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_portability_verifier_has_no_literal_author_home_but_still_builds_the_token(self):
        verifier = (EXPORTER.parents[0] / "verify-travel-cat-plugin.sh").read_text()
        self.assertNotIn("/Users/", verifier)
        self.assertIn("'/'\"Users\"'/'", verifier)

    def test_lowercase_script_directory_is_rejected(self):
        self.write("scripts/legacy.sh", "#!/bin/sh\n")
        blob = self.git("hash-object", "-w", "scripts/legacy.sh").stdout.strip()
        self.git("update-index", "--add", "--cacheinfo", f"100644,{blob},scripts/legacy.sh")
        self.git("commit", "-qm", "lowercase index fixture")
        result, output = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lowercase", result.stderr)
        self.assertFalse(output.exists())

    def test_extensionless_runtime_path_is_rejected(self):
        self.write("Scripts/launcher", "exec /Users/example/Applications/private\n")
        (self.repo / "Scripts/launcher").chmod(0o755)
        self.commit()
        result, output = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_windows_separator_in_member_is_rejected(self):
        self.write("Sources/dir\\..\\escape.swift", "// unsafe archive name")
        self.commit()
        result, output = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())

    def test_submodule_entry_is_rejected(self):
        revision = self.git("rev-parse", "HEAD").stdout.strip()
        (self.repo / "Sources/module").mkdir()
        self.git("update-index", "--add", "--cacheinfo", f"160000,{revision},Sources/module")
        self.git("commit", "-qm", "gitlink fixture")
        result, output = self.export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nonregular", result.stderr)
        self.assertFalse(output.exists())

    def test_archive_is_reproducible_and_never_overwrites(self):
        first, output = self.export()
        second, other = self.export("second.zip")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(output.read_bytes(), other.read_bytes())
        before = output.read_bytes()
        repeated, _ = self.export()
        self.assertNotEqual(repeated.returncode, 0)
        self.assertEqual(output.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
