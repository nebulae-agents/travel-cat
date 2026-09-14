import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "deploy_config.py"


class DeployConfigTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "private configuration module is missing")
        spec = importlib.util.spec_from_file_location("deploy_config", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory(prefix="travel-cat-config-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.home = self.base / "home"
        self.home.mkdir()
        self.repo = self.home / "source"
        self.repo.mkdir()
        self.path = self.repo / ".local/deploy.json"
        self.options = {"repository": self.repo, "home": self.home}
        self.demo = {"schemaVersion": 1, "applicationDirectory": "~/Applications",
                     "codexHome": "~/.codex",
                     "dataRoot": "~/Library/Application Support/TravelCat/TravelPetData"}

    def choose(self, answers=(), **kwargs):
        answers = iter(answers)
        self.messages = []

        def read(prompt):
            self.messages.append(prompt)
            try:
                return next(answers)
            except StopIteration:
                raise EOFError()

        return self.module.choose_config(input_fn=read, output_fn=self.messages.append,
                                         interactive=True, **self.options, **kwargs)

    def create(self):
        return self.choose(["", "", "yes"])

    def test_v2_wizard_has_only_app_and_album_paths(self):
        result = self.create()
        self.assertEqual(set(result), {"schemaVersion", "applicationDirectory", "dataRoot"})
        self.assertEqual(result["schemaVersion"], 2)
        self.assertNotIn("codexHome", "\n".join(self.messages))

    def test_v2_paths_retain_safety_checks_without_codex_directory_dependency(self):
        candidate = {key: value for key, value in self.demo.items() if key != "codexHome"}
        candidate["schemaVersion"] = 2
        (self.home / ".codex").write_bytes(b"not a directory and not our concern")
        result = self.module.validate_config(candidate, **self.options)
        self.assertEqual(result["schemaVersion"], 2)
        for value in (str(self.repo / "album"), "~/Applications/album", "relative", "~/../album", "/"):
            with self.subTest(value=value):
                with self.assertRaises(self.module.ConfigError):
                    self.module.validate_config(dict(candidate, dataRoot=value), **self.options)
        for changed in (dict(candidate, codexHome="~/.codex"), dict(candidate, schemaVersion=True)):
            with self.assertRaises(self.module.ConfigError):
                self.module.validate_config(changed, **self.options)

    def test_v1_regeneration_backups_exact_bytes_and_writes_v2(self):
        old = self.module.write_config(self.demo, **self.options)
        raw = self.path.read_bytes()
        self.assertEqual(self.choose(["1"]), old)
        self.assertEqual(self.path.read_bytes(), raw)
        result = self.choose(["2", "", "", "yes"])
        self.assertEqual(result["schemaVersion"], 2)
        self.assertNotIn("codexHome", result)
        self.assertEqual(result["dataRoot"], old["dataRoot"])
        self.assertEqual(next(self.path.parent.glob("deploy.json.backup-*")).read_bytes(), raw)

    def assert_unchanged(self, original, inode):
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(self.path.stat().st_ino, inode)

    def test_first_create_expands_defaults_and_sets_private_modes(self):
        result = self.create()
        self.assertEqual(result, json.loads(self.path.read_bytes()))
        self.assertEqual(result["applicationDirectory"], str(self.home / "Applications"))
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.path.parent.stat().st_mode), 0o700)
        self.assertFalse(Path(result["dataRoot"]).exists())
        self.assertIn("applicationDirectory", "\n".join(self.messages))

    def test_reuse_keeps_exact_bytes_inode_and_no_backup(self):
        self.create()
        original = self.path.read_bytes()
        inode = self.path.stat().st_ino
        self.choose([""])
        self.assert_unchanged(original, inode)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_regeneration_creates_unique_exact_backups_and_warns_on_new_album(self):
        self.create()
        original = self.path.read_bytes()
        alternate = self.home / "old project/TravelPetData"
        alternate.mkdir(parents=True)
        sentinel = alternate / "album.json"
        sentinel.write_bytes(b"existing album")
        self.choose(["2", "", str(alternate), "yes"])
        self.assertIn("另一相册", "\n".join(self.messages))
        self.assertEqual(sentinel.read_bytes(), b"existing album")
        second = self.path.read_bytes()
        self.choose(["2", "", "", "yes"])
        backups = sorted(self.path.parent.glob("deploy.json.backup-*"))
        self.assertEqual(len(backups), 2)
        self.assertCountEqual([p.read_bytes() for p in backups], [original, second])
        self.assertTrue(all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in backups))

    def test_first_create_cancellation_at_every_prompt_creates_no_active_file(self):
        for position in range(3):
            with self.subTest(position=position):
                with self.assertRaises(self.module.ConfigCancelled):
                    self.choose([""] * position)
                self.assertFalse(self.path.exists())
        with self.assertRaises(self.module.ConfigCancelled):
            self.choose(["", "", "no"])
        self.assertFalse(self.path.exists())

    def test_existing_cancel_at_every_prompt_preserves_file(self):
        self.create()
        original, inode = self.path.read_bytes(), self.path.stat().st_ino
        for answers in ([], ["3"], ["2"], ["2", ""], ["2", "", ""],
                        ["2", "", "", "no"]):
            with self.subTest(answers=answers):
                with self.assertRaises(self.module.ConfigCancelled):
                    self.choose(answers)
                self.assert_unchanged(original, inode)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_keyboard_interrupt_cancels_without_write(self):
        def interrupt(_):
            raise KeyboardInterrupt()
        with self.assertRaises(self.module.ConfigCancelled):
            self.module.choose_config(input_fn=interrupt, output_fn=lambda _: None,
                                      interactive=True, **self.options)
        self.assertFalse(self.path.exists())

    def test_chinese_prompts_confirmation_and_cancellation(self):
        self.choose(["", "", "确认"])
        self.assertIn("配置摘要", "\n".join(self.messages))
        self.choose(["1"])
        self.assertIn("1. 使用现有配置（默认）", "\n".join(self.messages))
        with self.assertRaises(self.module.ConfigCancelled):
            self.choose(["取消"])

    def test_invalid_input_preserves_existing_bytes(self):
        self.create()
        original, inode = self.path.read_bytes(), self.path.stat().st_ino
        for answers in (["unexpected"], ["2", "relative", "", "yes"]):
            with self.assertRaises(self.module.ConfigError):
                self.choose(answers)
            self.assert_unchanged(original, inode)

    def test_invalid_existing_json_never_regenerates_or_falls_back(self):
        self.create()
        cases = [b"{broken", b"{}", b"[]", b'{"schemaVersion":1,"schemaVersion":1}',
                 b" " * (65536 + 1), b"\xff", json.dumps(dict(self.demo, secret="x")).encode()]
        for contents in cases:
            with self.subTest(contents=contents[:70]):
                self.path.write_bytes(contents)
                with self.assertRaises(self.module.ConfigError):
                    self.choose(["2", "", "", "yes"])
                self.assertEqual(self.path.read_bytes(), contents)

    def test_private_config_requires_expanded_absolute_paths(self):
        self.create()
        self.path.write_text(json.dumps(self.demo))
        with self.assertRaises(self.module.ConfigError):
            self.module.load_config(**self.options)

    def test_bad_schema_types_unknown_missing_keys_and_path_values(self):
        cases = [dict(self.demo, schemaVersion=True), dict(self.demo, schemaVersion=1.0),
                 dict(self.demo, schemaVersion=2), dict(self.demo, codexHome=None),
                 dict(self.demo, codexHome=[]), dict(self.demo, codexHome=""),
                 dict(self.demo, dataRoot="relative"), dict(self.demo, dataRoot="~/a/../b"),
                 dict(self.demo, dataRoot="~someone/data"), dict(self.demo, extra=1),
                 {key: value for key, value in self.demo.items() if key != "dataRoot"}]
        for candidate in cases:
            with self.subTest(candidate=candidate):
                with self.assertRaises(self.module.ConfigError):
                    self.module.validate_config(candidate, **self.options)

    def test_rejects_unsafe_application_locations_and_overlaps(self):
        cases = [dict(self.demo, applicationDirectory=str(self.home / "other")),
                 dict(self.demo, dataRoot=str(self.repo / "TravelPetData")),
                 dict(self.demo, dataRoot=str(self.repo.parent)),
                 dict(self.demo, dataRoot="~/.codex/albums"),
                 dict(self.demo, codexHome="~/Applications/state"),
                 dict(self.demo, dataRoot="~/Applications/album"),
                 dict(self.demo, dataRoot="/")]
        for candidate in cases:
            with self.subTest(candidate=candidate):
                with self.assertRaises(self.module.ConfigError):
                    self.module.validate_config(candidate, **self.options)
        self.assertEqual(self.module.validate_config(dict(self.demo, applicationDirectory="/Applications"),
                                                     **self.options)["applicationDirectory"], "/Applications")

    def test_rejects_case_variant_repository_overlap_with_nonexistent_tail(self):
        variant = self.repo.with_name(self.repo.name.upper()) / "not-created/TravelPetData"
        self.assertFalse(variant.exists())
        with self.assertRaises(self.module.ConfigError):
            self.module.validate_config(dict(self.demo, dataRoot=str(variant)), **self.options)
        self.assertFalse(variant.exists())

    def test_rejects_double_leading_separator_repository_overlap(self):
        variant = "/" + str(self.repo / "not-created/TravelPetData")
        self.assertTrue(variant.startswith("//"))
        with self.assertRaises(self.module.ConfigError):
            self.module.validate_config(dict(self.demo, dataRoot=variant), **self.options)
        self.assertFalse((self.repo / "not-created").exists())

    def test_rejects_unicode_equivalent_repository_overlap_with_nonexistent_tail(self):
        accented_repo = self.home / "r\u00e9po"
        accented_repo.mkdir()
        variant = self.home / "re\u0301po/not-created/TravelPetData"
        self.assertFalse(variant.exists())
        with self.assertRaises(self.module.ConfigError):
            self.module.validate_config(dict(self.demo, dataRoot=str(variant)),
                                        repository=accented_repo, home=self.home)
        self.assertFalse(variant.exists())

    def test_rejects_macos_data_volume_aliases_before_inspecting_paths(self):
        for prefix in ("/System/Volumes/Data", "/SYSTEM/VOLUMES/DATA",
                       "/System//Volumes/dAtA"):
            alias = prefix + str(self.repo / "not-created/TravelPetData")
            with self.subTest(alias=prefix):
                with self.assertRaises(self.module.ConfigError):
                    self.module.validate_config(dict(self.demo, dataRoot=alias), **self.options)
        self.assertFalse((self.repo / "not-created").exists())

    def test_rejects_symlink_path_ancestry_and_non_directory_components(self):
        target = self.base / "other"
        target.mkdir()
        link = self.home / "linked"
        link.symlink_to(target, target_is_directory=True)
        ordinary = self.home / "file"
        ordinary.write_text("do not touch")
        for value in (str(link / "new"), str(ordinary), str(ordinary / "new")):
            with self.assertRaises(self.module.ConfigError):
                self.module.validate_config(dict(self.demo, dataRoot=value), **self.options)

    def test_symlink_config_and_local_directory_are_refused(self):
        self.create()
        original = self.path.read_bytes()
        outside = self.base / "external-config"
        outside.write_bytes(original)
        self.path.unlink()
        self.path.symlink_to(outside)
        with self.assertRaises(self.module.ConfigError):
            self.choose([""])
        self.path.unlink()
        self.path.parent.rmdir()
        self.path.parent.symlink_to(self.base, target_is_directory=True)
        with self.assertRaises(self.module.ConfigError):
            self.create()
        self.assertEqual(outside.read_bytes(), original)

    def test_interrupted_atomic_write_preserves_old_file(self):
        self.create()
        original, inode = self.path.read_bytes(), self.path.stat().st_ino
        for operation in ("write", "fsync", "replace"):
            with self.subTest(operation=operation):
                with patch.object(self.module.os, operation, side_effect=OSError("injected interruption")):
                    with self.assertRaises(self.module.ConfigError):
                        self.choose(["2", "", "", "yes"])
                self.assert_unchanged(original, inode)
        self.assertFalse(list(self.path.parent.glob(".deploy-*.tmp")))

    def test_failed_backup_write_does_not_leave_a_partial_backup(self):
        self.create()
        original, inode = self.path.read_bytes(), self.path.stat().st_ino
        actual_write = self.module.os.write
        calls = []
        def interrupted(descriptor, contents):
            calls.append(descriptor)
            if len(calls) == 2:
                raise OSError("backup write interrupted")
            return actual_write(descriptor, contents)
        with patch.object(self.module.os, "write", side_effect=interrupted):
            with self.assertRaises(self.module.ConfigError):
                self.choose(["2", "", "", "yes"])
        self.assert_unchanged(original, inode)
        self.assertEqual(list(self.path.parent.glob("deploy.json.backup-*")), [])

    def test_config_changed_while_prompting_is_not_overwritten(self):
        self.create()
        modified = self.path.read_bytes() + b"\n"
        answers = iter(["2", "", "", "yes"])
        def read(_):
            answer = next(answers)
            if answer == "yes":
                self.path.write_bytes(modified)
            return answer
        with self.assertRaises(self.module.ConfigError):
            self.module.choose_config(input_fn=read, output_fn=lambda _: None,
                                      interactive=True, **self.options)
        self.assertEqual(self.path.read_bytes(), modified)

    def test_parent_replaced_while_prompting_is_not_accepted_even_with_same_file(self):
        self.create()
        original, inode = self.path.read_bytes(), self.path.stat().st_ino
        answers = iter(["2", "", "", "yes"])
        def read(_):
            answer = next(answers)
            if answer == "yes":
                retired = self.repo / "retired-local"
                self.path.parent.rename(retired)
                self.path.parent.mkdir(mode=0o700)
                (retired / "deploy.json").rename(self.path)
            return answer
        with self.assertRaises(self.module.ConfigError):
            self.module.choose_config(input_fn=read, output_fn=lambda _: None,
                                      interactive=True, **self.options)
        self.assert_unchanged(original, inode)

    def test_private_permissions_and_nonregular_config_are_refused(self):
        self.create()
        self.path.chmod(0o644)
        with self.assertRaises(self.module.ConfigError):
            self.module.load_config(**self.options)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o644)
        self.path.chmod(0o600)
        self.path.parent.chmod(0o755)
        with self.assertRaises(self.module.ConfigError):
            self.module.load_config(**self.options)
        self.path.parent.chmod(0o700)
        self.path.unlink()
        os.mkfifo(str(self.path), mode=0o600)
        with self.assertRaises(self.module.ConfigError):
            self.module.load_config(**self.options)

    def test_system_temporary_alias_is_accepted_and_canonicalized(self):
        if not Path("/tmp").is_symlink():
            self.skipTest("macOS system alias not present")
        result = self.module.validate_config(dict(self.demo, dataRoot="/tmp/travel-cat-config-alias/album"),
                                             **self.options)
        self.assertEqual(result["dataRoot"], "/private/tmp/travel-cat-config-alias/album")

    def test_failed_initial_write_leaves_no_active_configuration(self):
        with patch.object(self.module.os, "replace", side_effect=OSError("interrupted")):
            with self.assertRaises(self.module.ConfigError):
                self.create()
        self.assertFalse(self.path.exists())
        self.assertFalse(list(self.path.parent.glob(".deploy-*.tmp")))

    def test_config_created_by_other_writer_during_first_wizard_is_preserved(self):
        answers = iter(["", "", "yes"])
        created = []
        def read(_):
            answer = next(answers)
            if answer == "yes":
                self.module.write_config(self.demo, **self.options)
                created.append(self.path.read_bytes())
            return answer
        with self.assertRaises(self.module.ConfigError):
            self.module.choose_config(input_fn=read, output_fn=lambda _: None,
                                      interactive=True, **self.options)
        self.assertEqual(self.path.read_bytes(), created[0])

    def test_noninteractive_requires_explicit_valid_existing_reuse(self):
        for reuse in (False, True):
            with self.assertRaises(self.module.ConfigError):
                self.module.choose_config(interactive=False, reuse_existing=reuse, **self.options)
        expected = self.create()
        with self.assertRaises(self.module.ConfigError):
            self.module.choose_config(interactive=False, **self.options)
        self.assertEqual(self.module.choose_config(interactive=False, reuse_existing=True,
                                                  **self.options), expected)

    def test_shell_syntax_is_only_literal_data_and_never_evaluated(self):
        marker = self.base / "should-not-exist"
        value = str(self.home / ("album-$(touch " + str(marker).replace("/", "_") + ")-$TOKEN-`id`"))
        result = self.module.validate_config(dict(self.demo, dataRoot=value), **self.options)
        self.assertEqual(result["dataRoot"], value)
        self.assertFalse(marker.exists())
        with self.assertRaises(self.module.ConfigError):
            self.module.validate_config(dict(self.demo, dataRoot="$HOME/data"), **self.options)

    def test_caller_can_suggest_verified_old_album_without_touching_it(self):
        old = self.home / "legacy/TravelPetData"
        old.mkdir(parents=True)
        result = self.choose(["", "", "yes"], suggested_data_root=old)
        self.assertEqual(result["dataRoot"], str(old))
        self.assertEqual(list(old.iterdir()), [])

    def test_generated_config_is_ignored_by_real_git(self):
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        (self.repo / ".gitignore").write_bytes((SCRIPT.parents[1] / ".gitignore").read_bytes())
        self.create()
        result = subprocess.run(["git", "-C", str(self.repo), "check-ignore", ".local/deploy.json"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_noninteractive_failures_are_friendly_and_do_not_write(self):
        scripts = self.repo / "Scripts"
        scripts.mkdir()
        for name in ("deploy_config.py", "configure-local.py"):
            shutil.copyfile(SCRIPT.with_name(name), scripts / name)
        for flags in ([], ["--reuse-existing"]):
            result = subprocess.run(["python3", str(scripts / "configure-local.py"), *flags],
                                    input="", capture_output=True, text=True)
            self.assertEqual(result.returncode, 65, result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertFalse(self.path.exists())


if __name__ == "__main__":
    unittest.main()
