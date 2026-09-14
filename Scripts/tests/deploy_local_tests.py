"""Deployment tests use only disposable repositories and fake OS boundaries."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from deploy_config import write_config


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE).decode().strip()


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(importlib.util.find_spec("deploy_local"), "versioned deployment implementation is missing")
        import deploy_local
        import deployment_runtime
        import deployment_files
        self.deploy = deploy_local
        self.files = deployment_files
        self.runtime_module = deployment_runtime
        self.temp = tempfile.TemporaryDirectory(prefix="travel-deployment-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / "source with spaces"
        self.repo.mkdir()
        self.home = self.base / "home"
        self.home.mkdir()
        self.config = {"schemaVersion": 1, "applicationDirectory": str(self.home / "Applications"),
                       "codexHome": str(self.home / ".codex"), "dataRoot": str(self.home / "album")}
        self.app = Path(self.config["applicationDirectory"]) / "Travel Cat.app"
        self.pet = Path(self.config["codexHome"]) / "pets/cute-black-cat"
        for path, data in {".gitignore": b".local/\n", "Package.swift": b"package",
                           "Sources/TravelCore/a.swift": b"core", "Sources/TravelStorage/a.swift": b"storage",
                           "Sources/TravelCatCLI/a.swift": b"cli", "Sources/TravelUI/Resources/pet.json": b'{"name":"cat"}',
                           "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp": b"webp-source",
                           "Plugins/travel-cat/.codex-plugin/plugin.json": b'{"version":"1.0.0"}'}.items():
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        git(self.repo, "init", "-q")
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        self.revision = git(self.repo, "rev-parse", "HEAD")
        write_config(self.config, repository=self.repo, home=self.home)
        fixture = self

        class FakeRuntime(deployment_runtime.Runtime):
            def __init__(self):
                self.events = []
                self.fail = None
                self.after_build = None
                self.running = True

            def check_tools(self):
                self.events.append("tools")
                if self.fail == "tools":
                    raise RuntimeError("missing tools")

            def audit(self, repository):
                self.events.append("audit")
                if self.fail == "audit":
                    raise RuntimeError("audit refused")

            def verify_signature(self, app):
                if (app / "bad-signature").exists():
                    raise RuntimeError("signature invalid")

            def build(self, repository, revision, config, workspace, log):
                self.events.append("build")
                if self.fail == "build":
                    raise RuntimeError("build failed")
                target = workspace / "candidate.app"
                fixture.make_app(target, revision=revision, root=config["dataRoot"])
                if self.fail == "revision":
                    fixture.change_plist(target, TravelCatSourceRevision="0" * 40)
                if self.fail == "asset":
                    (target / "Contents/Resources/TravelCat_TravelUI.bundle/pet.json").write_bytes(b"bad")
                if self.after_build:
                    self.after_build()
                return target

            def stage_pet(self, app, workspace):
                self.events.append("stage-pet")
                target = workspace / "pets/cute-black-cat"
                fixture.make_pet(target)
                return target

            def copy_tree(self, source, target):
                shutil.copytree(source, target, copy_function=shutil.copy2)

            def is_running(self, app):
                return self.running

            def stop(self, app):
                self.events.append("stop")
                if self.fail == "stop":
                    raise RuntimeError("app did not exit")
                self.running = False
                return True

            def launch(self, app):
                self.events.append("launch")
                if self.fail in ("launch", "recovery") and (app / "payload").read_bytes() != b"old":
                    raise RuntimeError("launch failed")
                if self.fail == "recovery":
                    raise RuntimeError("relaunch failed")
                self.running = True

        self.runtime = FakeRuntime()
        self.make_app(self.app, payload=b"old")

    def make_app(self, target, payload=b"new", revision=None, root=None):
        target.mkdir(parents=True)
        (target / "Contents/Resources/TravelCat_TravelUI.bundle").mkdir(parents=True)
        (target / "Contents/Helpers").mkdir()
        (target / "payload").write_bytes(payload)
        info = {"CFBundleIdentifier": "com.nebulae.travelcat", "TravelCatDataRoot": root or self.config["dataRoot"]}
        if revision:
            info["TravelCatSourceRevision"] = revision
        (target / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        for installed, source in self.runtime_module.PET_FILES.items():
            shutil.copy2(self.repo / source, target / "Contents/Resources/TravelCat_TravelUI.bundle" / Path(source).name)
        helper = target / "Contents/Helpers/travelcatctl"
        helper.write_bytes(b"helper")
        helper.chmod(0o555)
        binary = hashlib.sha256(b"helper").hexdigest()
        provenance = "\n".join(["format=travel-cat-cli-provenance-v3", "product=travelcatctl", "configuration=release",
                                "sourceTreeSHA256=" + self.runtime_module.source_digest(self.repo),
                                "binarySHA256=" + binary, "binaryArtifactID=" + binary + "/travelcatctl"]) + "\n"
        (target / "Contents/Resources/travelcatctl-release.provenance").write_text(provenance)

    def change_plist(self, app, **changes):
        path = app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info.update(changes)
        path.write_bytes(plistlib.dumps(info))

    def make_pet(self, target=None):
        target = target or self.pet
        target.mkdir(parents=True)
        for installed, source in self.runtime_module.PET_FILES.items():
            shutil.copy2(self.repo / source, target / installed)

    def run_deploy(self):
        return self.deploy.deploy(self.repo, self.config, home=self.home, runtime=self.runtime, output_fn=lambda _: None)

    def assert_old(self):
        self.assertEqual((self.app / "payload").read_bytes(), b"old")

    def test_app_only_deployment_has_no_pet_publication_or_staging(self):
        receipt = self.run_deploy()
        self.assertEqual(receipt["schemaVersion"], 2)
        self.assertEqual(receipt["targets"], {"app": str(self.app)})
        self.assertTrue({"petDigest", "petAction", "petExtras", "plugin"}.isdisjoint(receipt))
        self.assertNotIn("stage-pet", self.runtime.events)
        self.assertFalse(self.pet.parent.exists())
        self.assertEqual(receipt["stages"], ["prepared", "app-published", "verified", "launched"])

    def test_app_only_deployment_ignores_conflicting_pet_bytes(self):
        self.make_pet()
        (self.pet / "pet.json").write_bytes(b"user-owned custom cat")
        before = self.files.tree_digest(self.pet)
        inode = self.pet.stat().st_ino
        self.run_deploy()
        self.assertEqual(self.files.tree_digest(self.pet), before)
        self.assertEqual(self.pet.stat().st_ino, inode)

    def test_app_only_runtime_has_no_native_pet_staging_entry(self):
        self.assertFalse(hasattr(self.runtime_module.Runtime, "stage_pet"))

    def legacy_receipt(self, status="complete"):
        run_id = "a" * 32
        value = {"schemaVersion": 1, "runID": run_id, "sourceRevision": self.revision,
                 "configFingerprint": self.files.fingerprint(self.config),
                 "targets": {"app": str(self.app), "pet": str(self.pet)},
                 "appDigest": self.files.tree_digest(self.app), "petDigest": "b" * 64,
                 "petAction": "install", "petExtras": [],
                 "plugin": {"sourceVersion": "1.0.0", "refreshed": False}, "status": status,
                 "backupDirectory": str(self.repo / (".local/deployment-" + run_id)),
                 "stages": ["prepared", "app-published", "pet-published", "verified", "launched"],
                 "error": "", "recoveryErrors": []}
        raw = (json.dumps(value, indent=4) + "\n\n").encode()
        path = self.repo / ".local/deployment-receipt.json"
        path.write_bytes(raw)
        path.chmod(0o600)
        return value, raw

    def test_v2_receipt_supports_repeat_deployment(self):
        first = self.run_deploy()
        self.assertEqual(self.files.read_receipt(self.repo / ".local", self.config), first)
        second = self.run_deploy()
        self.assertEqual(second["schemaVersion"], 2)
        self.assertNotEqual(first["runID"], second["runID"])

    def test_v2_config_migrates_legacy_receipt_using_exact_config_backup(self):
        _, raw = self.legacy_receipt()
        self.config = {key: value for key, value in self.config.items() if key != "codexHome"}
        self.config["schemaVersion"] = 2
        write_config(self.config, repository=self.repo, home=self.home)
        receipt = self.run_deploy()
        self.assertEqual(receipt["status"], "complete")
        self.assertEqual((Path(receipt["backupDirectory"]) / "previous-receipt.json").read_bytes(), raw)
        self.assertFalse(self.pet.exists())

    def test_fresh_v2_deployment_needs_no_codex_directory(self):
        self.config = {key: value for key, value in self.config.items() if key != "codexHome"}
        self.config["schemaVersion"] = 2
        write_config(self.config, repository=self.repo, home=self.home)
        (self.home / ".codex").write_bytes(b"unrelated file")
        self.assertEqual(self.run_deploy()["status"], "complete")
        self.assertEqual(self.run_deploy()["status"], "complete")
        self.assertEqual((self.home / ".codex").read_bytes(), b"unrelated file")

    def test_v2_config_does_not_bypass_legacy_recovery_blocker(self):
        self.legacy_receipt("recovery-failed")
        self.config = {key: value for key, value in self.config.items() if key != "codexHome"}
        self.config["schemaVersion"] = 2
        write_config(self.config, repository=self.repo, home=self.home)
        with self.assertRaisesRegex(ValueError, "recovery"):
            self.run_deploy()
        self.assertNotIn("build", self.runtime.events)

    def test_v2_legacy_migration_refuses_missing_or_untrusted_backup(self):
        self.legacy_receipt()
        self.config = {key: value for key, value in self.config.items() if key != "codexHome"}
        self.config["schemaVersion"] = 2
        write_config(self.config, repository=self.repo, home=self.home)
        backup = next((self.repo / ".local").glob("deploy.json.backup-*"))
        original = backup.read_bytes()
        backup.chmod(0o644)
        with self.assertRaises(ValueError):
            self.run_deploy()
        backup.chmod(0o600)
        backup.write_bytes(original.replace(b".codex", b".other"))
        with self.assertRaisesRegex(ValueError, "matching v1"):
            self.run_deploy()
        backup.unlink()
        backup.symlink_to(self.repo / ".local/deploy.json")
        with self.assertRaises((ValueError, OSError)):
            self.run_deploy()
        backup.unlink()
        with self.assertRaisesRegex(ValueError, "matching v1"):
            self.run_deploy()
        self.assertNotIn("build", self.runtime.events)

    def test_legacy_receipt_migration_archives_exact_bytes_without_touching_pet(self):
        self.make_pet()
        before = self.files.tree_digest(self.pet)
        _, raw = self.legacy_receipt()
        result = self.run_deploy()
        self.assertEqual(result["schemaVersion"], 2)
        self.assertEqual((Path(result["backupDirectory"]) / "previous-receipt.json").read_bytes(), raw)
        self.assertEqual(self.files.tree_digest(self.pet), before)

    def test_legacy_incomplete_receipts_block_even_after_album_config_change(self):
        for status in ("prepared", "recovery-failed"):
            with self.subTest(status=status):
                value, _ = self.legacy_receipt(status)
                changed = dict(self.config, dataRoot=str(self.home / "another-album"))
                with self.assertRaisesRegex(ValueError, "recovery"):
                    self.files.read_receipt(self.repo / ".local", changed)
                with self.assertRaisesRegex(ValueError, "recovery"):
                    self.run_deploy()
                self.assertNotIn("build", self.runtime.events)

    def test_legacy_failure_does_not_restore_unverified_pet_authority(self):
        self.legacy_receipt()
        self.runtime.fail = "launch"
        with self.assertRaisesRegex(RuntimeError, "launch"):
            self.run_deploy()
        self.assert_old()
        active = self.files.read_receipt(self.repo / ".local", self.config)
        self.assertEqual(active["schemaVersion"], 2)
        self.assertEqual(active["status"], "rolled-back")

    def test_legacy_receipt_validation_is_not_weakened_by_migration(self):
        initial, _ = self.legacy_receipt()
        path = self.repo / ".local/deployment-receipt.json"
        for changes in ({"schemaVersion": True}, {"petDigest": "bad"}, {"petAction": "unknown"},
                        {"targets": {"app": str(self.app), "pet": str(self.home / "unknown")}},
                        {"stages": ["prepared", "app-published", "verified", "launched"]},
                        {"plugin": {"sourceVersion": "1.0.0", "refreshed": True}},
                        {"petExtras": ["../outside"]}, {"unexpected": True}):
            with self.subTest(changes=changes):
                path.write_text(json.dumps(dict(initial, **changes)))
                with self.assertRaisesRegex(ValueError, "receipt"):
                    self.run_deploy()
        self.assertNotIn("build", self.runtime.events)

    def test_prior_receipt_backup_failure_stops_before_build_and_keeps_authority(self):
        _, raw = self.legacy_receipt()
        with mock.patch.object(self.deploy, "_write_exclusive", side_effect=OSError("backup write failed")):
            with self.assertRaisesRegex(OSError, "backup write failed"):
                self.run_deploy()
        self.assertEqual((self.repo / ".local/deployment-receipt.json").read_bytes(), raw)
        self.assertNotIn("build", self.runtime.events)
        self.assertNotIn("stop", self.runtime.events)
        self.assert_old()

    def test_app_install_and_private_receipt_leave_missing_pet_absent(self):
        receipt = self.run_deploy()
        self.assertEqual((self.app / "payload").read_bytes(), b"new")
        self.assertFalse(self.pet.exists())
        self.assertEqual(receipt["sourceRevision"], self.revision)
        self.assertEqual(receipt["status"], "complete")
        self.assertNotIn("plugin", receipt)
        self.assertEqual((self.repo / ".local/deployment-receipt.json").stat().st_mode & 0o777, 0o600)
        self.assertFalse(Path(self.config["dataRoot"]).exists())

    def test_same_pet_is_untouched_with_extra_backup(self):
        self.make_pet()
        extra = self.pet / "rollback-v1/kept"
        extra.parent.mkdir()
        extra.write_bytes(b"preserve")
        (self.pet / ".DS_Store").write_bytes(b"desktop")
        before = self.files.tree_digest(self.pet)
        inode = self.pet.stat().st_ino
        receipt = self.run_deploy()
        self.assertNotIn("petAction", receipt)
        self.assertEqual(self.pet.stat().st_ino, inode)
        self.assertEqual(self.files.tree_digest(self.pet), before)

    def test_unmanaged_pet_conflict_does_not_block_app_install(self):
        self.make_pet()
        (self.pet / "pet.json").write_bytes(b"unknown")
        self.run_deploy()
        self.assertEqual((self.pet / "pet.json").read_bytes(), b"unknown")
        self.assertEqual((self.app / "payload").read_bytes(), b"new")

    def test_dirty_and_untracked_refused(self):
        for name in ("Package.swift", "unknown.txt"):
            with self.subTest(name=name):
                path = self.repo / name
                prior = path.read_bytes() if path.exists() else None
                path.write_bytes(b"change")
                with self.assertRaisesRegex(Exception, "clean|uncommitted|未提交"):
                    self.run_deploy()
                if prior is None:
                    path.unlink()
                else:
                    path.write_bytes(prior)
        self.assertNotIn("build", self.runtime.events)

    def test_head_change_during_build_refused(self):
        self.runtime.after_build = lambda: git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "changed")
        with self.assertRaisesRegex(Exception, "HEAD|revision|提交"):
            self.run_deploy()
        self.assertNotIn("stop", self.runtime.events)
        self.assert_old()

    def test_config_change_during_build_refused(self):
        def change():
            changed = dict(self.config, dataRoot=str(self.home / "other-album"))
            write_config(changed, repository=self.repo, home=self.home)
        self.runtime.after_build = change
        with self.assertRaisesRegex(Exception, "config|配置"):
            self.run_deploy()
        self.assertNotIn("stop", self.runtime.events)

    def test_tools_audit_build_and_candidate_failures_leave_old_app(self):
        for failure in ("tools", "audit", "build", "revision", "asset", "stop"):
            with self.subTest(failure=failure):
                self.runtime.fail = failure
                with self.assertRaises(Exception):
                    self.run_deploy()
                self.assert_old()
                self.assertFalse(self.pet.exists())

    def test_bad_existing_signature_or_identifier_precedes_build(self):
        (self.app / "bad-signature").write_bytes(b"bad")
        with self.assertRaisesRegex(Exception, "signature"):
            self.run_deploy()
        (self.app / "bad-signature").unlink()
        self.change_plist(self.app, CFBundleIdentifier="unknown")
        with self.assertRaisesRegex(Exception, "identifier"):
            self.run_deploy()
        self.assertNotIn("build", self.runtime.events)

    def test_explicit_album_change_refused_without_confirmation(self):
        self.change_plist(self.app, TravelCatDataRoot=str(self.home / "legacy-album"))
        with self.assertRaisesRegex(Exception, "album|相册"):
            self.run_deploy()
        self.assertNotIn("build", self.runtime.events)

    def test_launch_failure_rolls_back_app_and_missing_pet(self):
        self.runtime.fail = "launch"
        with self.assertRaises(Exception):
            self.run_deploy()
        self.assert_old()
        self.assertFalse(self.pet.exists())
        receipt = json.loads((self.repo / ".local/deployment-receipt.json").read_text())
        self.assertEqual(receipt["status"], "rolled-back")

    def test_recovery_failure_is_honest_and_backups_remain(self):
        self.runtime.fail = "recovery"
        with self.assertRaises(Exception):
            self.run_deploy()
        receipt = json.loads((self.repo / ".local/deployment-receipt.json").read_text())
        self.assertEqual(receipt["status"], "recovery-failed")
        self.assertTrue(receipt["recoveryErrors"])
        self.assertTrue((Path(receipt["backupDirectory"]) / "app/payload").exists())

    def test_publication_failure_rolls_back_completed_stages(self):
        original = self.files.Publication.publish
        for failure in ("app",):
            with self.subTest(failure=failure):
                def failing(publication):
                    if publication.label == failure:
                        raise OSError("publication failed")
                    return original(publication)
                with mock.patch.object(self.files.Publication, "publish", failing):
                    with self.assertRaises(Exception):
                        self.run_deploy()
                self.assert_old()
                self.assertFalse(self.pet.exists())

    def test_bundled_pet_upgrade_leaves_existing_codex_pet_untouched(self):
        self.make_pet()
        self.run_deploy()
        (self.repo / "Sources/TravelUI/Resources/pet.json").write_bytes(b'{"name":"new-cat"}')
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "new pet")
        receipt = self.run_deploy()
        self.assertNotIn("petAction", receipt)
        self.assertEqual((self.pet / "pet.json").read_bytes(), b'{"name":"cat"}')
        self.assertEqual((self.app / "Contents/Resources/TravelCat_TravelUI.bundle/pet.json").read_bytes(), b'{"name":"new-cat"}')

    def test_invalid_app_receipt_target_is_refused(self):
        self.run_deploy()
        receipt_path = self.repo / ".local/deployment-receipt.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["targets"]["app"] = str(self.home / "unknown")
        receipt_path.write_text(json.dumps(receipt))
        with self.assertRaisesRegex(Exception, "receipt|记录"):
            self.run_deploy()
        receipt["targets"]["app"] = str(self.app)
        receipt_path.write_text(json.dumps(receipt))
        self.run_deploy()

    def test_lock_contention_and_symlink_refused(self):
        with self.files.DeploymentLock(self.repo / ".local"):
            with self.assertRaisesRegex(Exception, "lock|部署"):
                self.run_deploy()
        lock = self.repo / ".local/deployment.lock"
        lock.unlink()
        lock.symlink_to(self.repo / ".local/deploy.json")
        with self.assertRaises(Exception):
            self.run_deploy()
        self.assertNotIn("build", self.runtime.events)

    def test_owned_cleanup_refuses_changed_identity(self):
        owned = self.files.OwnedDirectory(self.base)
        old = owned.path.with_name(owned.path.name + "-moved")
        owned.path.rename(old)
        owned.path.mkdir()
        marker = owned.path / "unowned"
        marker.write_bytes(b"keep")
        with self.assertRaises(Exception):
            owned.cleanup()
        self.assertEqual(marker.read_bytes(), b"keep")

    def test_owned_cleanup_removes_immutable_pinned_build_directories(self):
        owned = self.files.OwnedDirectory(self.base)
        pinned = owned.path / "swift-scratch/travelcatctl-pinned"
        artifact = pinned / ("a" * 64)
        artifact.mkdir(parents=True)
        helper = artifact / "travelcatctl"
        helper.write_bytes(b"private build artifact")
        helper.chmod(0o555)
        artifact.chmod(0o555)
        pinned.chmod(0o555)
        self.assertEqual(artifact.stat().st_mode & 0o777, 0o555)
        owned.cleanup()
        self.assertFalse(owned.path.exists())

    def test_owned_cleanup_does_not_chmod_or_follow_external_readonly_symlink(self):
        external = self.base / "external-readonly"
        external.mkdir()
        marker = external / "keep"
        marker.write_bytes(b"external must remain unchanged")
        marker.chmod(0o444)
        external.chmod(0o555)
        owned = self.files.OwnedDirectory(self.base)
        pinned = owned.path / "pinned"
        pinned.mkdir()
        (pinned / "external-link").symlink_to(external, target_is_directory=True)
        pinned.chmod(0o555)
        owned.cleanup()
        self.assertFalse(owned.path.exists())
        self.assertEqual(external.stat().st_mode & 0o777, 0o555)
        self.assertEqual(marker.stat().st_mode & 0o777, 0o444)
        self.assertEqual(marker.read_bytes(), b"external must remain unchanged")

    def test_owned_cleanup_never_chmods_the_external_parent(self):
        parent = self.base / "readonly-parent"
        parent.mkdir()
        owned = self.files.OwnedDirectory(parent)
        parent.chmod(0o555)
        with self.assertRaises(PermissionError):
            owned.cleanup()
        self.assertEqual(parent.stat().st_mode & 0o777, 0o555)
        self.assertTrue(owned.path.exists())

    def test_environment_strips_all_travel_overrides(self):
        actual = self.runtime_module.build_environment({"PATH": "/bin", "TRAVEL_CAT_DATA_ROOT": "bad", "TRAVEL_CAT_RELEASE": "bad"}, self.base / "scratch")
        self.assertEqual(actual, {"PATH": "/bin", "TRAVEL_CAT_SCRATCH_ROOT": str(self.base / "scratch")})

    def test_exclusive_rename_never_overwrites_an_empty_directory(self):
        source, target = self.base / "move-source", self.base / "move-target"
        source.mkdir()
        target.mkdir()
        (source / "ours").write_bytes(b"ours")
        self.assertTrue(hasattr(self.files, "exclusive_rename"), "publication needs an exclusive directory rename")
        with self.assertRaises(FileExistsError):
            self.files.exclusive_rename(source, target)
        self.assertTrue((source / "ours").exists())
        self.assertEqual(list(target.iterdir()), [])

    def test_failure_between_displacement_and_publish_restores_old(self):
        self.assertTrue(hasattr(self.files, "exclusive_rename"), "publication needs an exclusive directory rename")
        original = self.files.exclusive_rename
        def failing(source, target):
            if Path(source).name == "candidate" and Path(target) == self.app:
                raise OSError("injected move failure")
            return original(source, target)
        with mock.patch.object(self.files, "exclusive_rename", failing):
            with self.assertRaisesRegex(Exception, "move failure"):
                self.run_deploy()
        self.assert_old()
        self.assertFalse(self.pet.exists())

    def test_corrupt_configuration_stops_before_build(self):
        (self.repo / ".local/deploy.json").write_bytes(b"not JSON")
        with self.assertRaises(Exception):
            self.run_deploy()
        self.assertNotIn("build", self.runtime.events)
        self.assert_old()

    def test_receipt_rejects_unknown_fields_permissions_and_symlinks(self):
        self.run_deploy()
        path = self.repo / ".local/deployment-receipt.json"
        original = path.read_bytes()
        value = json.loads(original)
        value["unknown"] = True
        path.write_text(json.dumps(value))
        with self.assertRaises(Exception):
            self.run_deploy()
        path.write_bytes(original)
        path.chmod(0o644)
        with self.assertRaises(Exception):
            self.run_deploy()
        path.chmod(0o600)
        path.unlink()
        path.symlink_to(self.repo / ".local/deploy.json")
        with self.assertRaises(Exception):
            self.run_deploy()

    def test_changed_old_target_during_build_stops_before_stop(self):
        def change():
            (self.app / "payload").write_bytes(b"externally-changed")
        self.runtime.after_build = change
        with self.assertRaisesRegex(Exception, "target changed"):
            self.run_deploy()
        self.assertNotIn("stop", self.runtime.events)
        self.assertEqual((self.app / "payload").read_bytes(), b"externally-changed")
        self.assertEqual(list(self.app.parent.glob(".travel-cat-stage-*")), [])

    def test_postpublication_failure_restores_app_and_preserves_external_pet(self):
        self.make_pet()
        self.run_deploy()
        old_app = self.files.tree_digest(self.app)
        old_pet = self.files.tree_digest(self.pet)
        (self.repo / "Sources/TravelUI/Resources/pet.json").write_bytes(b'{"name":"upgrade"}')
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "upgrade")
        original = self.runtime.verify_app
        def failing(app, *args):
            if app == self.app:
                raise ValueError("published app verification failure")
            return original(app, *args)
        with mock.patch.object(self.runtime, "verify_app", failing):
            with self.assertRaisesRegex(Exception, "verification failure"):
                self.run_deploy()
        self.assertEqual(self.files.tree_digest(self.app), old_app)
        self.assertEqual(self.files.tree_digest(self.pet), old_pet)

    def test_helper_provenance_and_linked_bundles_are_refused(self):
        with tempfile.TemporaryDirectory(dir=self.base) as temporary:
            candidate = Path(temporary) / "candidate.app"
            self.make_app(candidate, revision=self.revision)
            provenance = candidate / "Contents/Resources/travelcatctl-release.provenance"
            provenance.write_bytes(b"wrong provenance")
            with self.assertRaisesRegex(Exception, "provenance"):
                self.runtime.verify_app(candidate, self.repo, self.revision, self.config)
            (candidate / "unexpected-link").symlink_to(self.repo)
            with self.assertRaisesRegex(Exception, "link|directory"):
                self.runtime.inspect_app(candidate)

    def test_app_deployment_does_not_require_plugin_source(self):
        (self.repo / "Plugins/travel-cat/.codex-plugin/plugin.json").unlink()
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "remove plugin fixture")
        self.assertEqual(self.run_deploy()["status"], "complete")

    def test_signature_boundary_checks_signing_identifier(self):
        boundary = self.runtime_module.Runtime()
        with mock.patch.object(boundary, "run", side_effect=["", "Identifier=wrong.bundle\n"]):
            with self.assertRaisesRegex(Exception, "identifier"):
                boundary.verify_signature(self.app)

    def test_partial_stop_failure_recovers_original_running_state(self):
        def partial_stop(app):
            self.runtime.running = False
            raise RuntimeError("probe failed after graceful exit")
        with mock.patch.object(self.runtime, "stop", partial_stop):
            with self.assertRaisesRegex(Exception, "probe failed"):
                self.run_deploy()
        self.assert_old()
        self.assertTrue(self.runtime.running, "old running app must be relaunched after a partial stop")

    def test_stop_failure_does_not_duplicate_still_running_app(self):
        self.runtime.fail = "stop"
        with self.assertRaises(Exception):
            self.run_deploy()
        self.assertTrue(self.runtime.running)
        self.assertNotIn("launch", self.runtime.events)

    def test_copy_boundary_preserves_macos_metadata(self):
        boundary = self.runtime_module.Runtime()
        self.assertTrue(hasattr(boundary, "copy_tree"), "macOS backups need a metadata preserving copy adapter")
        with mock.patch.object(boundary, "run", return_value="") as call:
            boundary.copy_tree(self.app, self.base / "copy.app")
        args = call.call_args.args[0]
        self.assertEqual(args[0], "/usr/bin/ditto")
        self.assertIn("--rsrc", args)
        self.assertIn("--extattr", args)
        self.assertNotIn("--noqtn", args)

    def test_symlinked_pet_parent_is_not_followed_or_changed(self):
        destination = self.base / "unmanaged-pets"
        destination.mkdir()
        self.pet.parent.parent.mkdir(parents=True)
        self.pet.parent.symlink_to(destination)
        self.run_deploy()
        self.assertTrue(self.pet.parent.is_symlink())
        self.assertEqual(list(destination.iterdir()), [])

    def test_real_build_adapter_exports_extracts_and_only_outer_signs(self):
        import zipfile
        import types
        package = self.runtime_module.import_script(SCRIPTS / "package-project.py", "fixture_package_helpers")
        exporter = types.SimpleNamespace()
        def export(repository, archive):
            with zipfile.ZipFile(archive, "w") as output:
                paths = [path for path in repository.rglob("*") if path.is_file() and ".git" not in path.parts and ".local" not in path.parts]
                members = {path.relative_to(repository).as_posix(): path.read_bytes() for path in paths}
                members.update({"README.md": b"fixture", "Scripts/package-app.sh": b"#!/bin/sh\nexit 0\n"})
                for name, value in members.items():
                    info = zipfile.ZipInfo("TravelCat/" + name)
                    info.external_attr = (0o100755 if name.endswith(".sh") else 0o100644) << 16
                    output.writestr(info, value)
            return archive
        exporter.export = export
        boundary = self.runtime_module.Runtime()
        calls = []
        def run(arguments, **kwargs):
            calls.append((arguments, kwargs))
            if str(arguments[0]).endswith("package-app.sh"):
                source = Path(arguments[0]).parents[1]
                self.make_app(source / "dist/Travel Cat.app")
            if "--verbose=4" in arguments:
                return "Identifier=com.nebulae.travelcat\n"
            return ""
        with tempfile.TemporaryDirectory(dir=self.base) as temporary:
            workspace = Path(temporary)
            with mock.patch.object(self.runtime_module, "import_script", side_effect=[exporter, package]):
                with mock.patch.object(boundary, "run", side_effect=run):
                    with mock.patch.dict(os.environ, {"TRAVEL_CAT_DATA_ROOT": "wrong", "TRAVEL_CAT_PINNED_ROOT": "wrong"}):
                        app = boundary.build(self.repo, self.revision, self.config, workspace, None)
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            self.assertEqual(info["TravelCatSourceRevision"], self.revision)
            build_call = next(call for call in calls if str(call[0][0]).endswith("package-app.sh"))
            self.assertEqual(build_call[0][1:], ["--data-root", self.config["dataRoot"]])
            self.assertNotIn("TRAVEL_CAT_DATA_ROOT", build_call[1]["env"])
            self.assertEqual(build_call[1]["env"]["TRAVEL_CAT_SCRATCH_ROOT"], str(workspace / "swift-scratch"))
            signing = [args for args, _ in calls if "--sign" in args]
            self.assertEqual(signing, [["/usr/bin/codesign", "--force", "--sign", "-", app]])
            self.assertFalse((self.repo / "dist").exists())

    def test_regenerated_album_config_can_deploy_without_old_pet_authority(self):
        self.run_deploy()
        self.config = dict(self.config, dataRoot=str(self.home / "new-album"))
        write_config(self.config, repository=self.repo, home=self.home)
        prompts = []
        receipt = self.deploy.deploy(self.repo, self.config, home=self.home, runtime=self.runtime,
                                     output_fn=lambda _: None,
                                     confirm_album_change=lambda old, new: prompts.append((old, new)) or True)
        self.assertEqual(len(prompts), 1)
        self.assertNotIn("petAction", receipt)
        self.assertFalse(Path(self.config["dataRoot"]).exists())

    def test_changed_config_cannot_authorize_managed_pet_replacement(self):
        self.make_pet()
        old_pet = self.files.tree_digest(self.pet)
        self.run_deploy()
        self.config = dict(self.config, dataRoot=str(self.home / "new-album"))
        write_config(self.config, repository=self.repo, home=self.home)
        (self.repo / "Sources/TravelUI/Resources/pet.json").write_bytes(b'{"name":"upgrade"}')
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "upgrade")
        self.deploy.deploy(self.repo, self.config, home=self.home, runtime=self.runtime,
                           output_fn=lambda _: None, confirm_album_change=lambda old, new: True)
        self.assertEqual(self.files.tree_digest(self.pet), old_pet)

    def test_complete_receipt_requires_consistent_success_semantics(self):
        initial = self.run_deploy()
        path = self.repo / ".local/deployment-receipt.json"
        contradictions = [
            {"stages": []}, {"stages": ["prepared"]},
            {"stages": ["prepared", "app-published", "pet-published", "verified", "launched"]},
            {"stages": ["prepared", "pet-published", "app-published", "verified", "launched"]},
            {"stages": initial["stages"] + ["launched"]},
            {"error": "launch failed"}, {"recoveryErrors": ["old app not restored"]},
            {"petAction": "unchanged"},
        ]
        for changes in contradictions:
            with self.subTest(changes=changes):
                path.write_text(json.dumps(dict(initial, **changes)))
                with self.assertRaisesRegex(Exception, "receipt|记录"):
                    self.files.read_receipt(self.repo / ".local", self.config)

    def test_failed_managed_update_restores_authority_and_can_retry(self):
        self.make_pet()
        initial = self.run_deploy()
        old_app = self.files.tree_digest(self.app)
        old_pet = self.files.tree_digest(self.pet)
        (self.repo / "Sources/TravelUI/Resources/pet.json").write_bytes(b'{"name":"upgrade"}')
        git(self.repo, "add", ".")
        git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "upgrade")
        verify = self.runtime.verify_app
        def fail_published(app, *args):
            if app == self.app:
                raise ValueError("published app verification failed")
            return verify(app, *args)
        with mock.patch.object(self.runtime, "verify_app", fail_published):
            with self.assertRaisesRegex(Exception, "verification failed"):
                self.run_deploy()
        self.assertEqual(self.files.tree_digest(self.app), old_app)
        self.assertEqual(self.files.tree_digest(self.pet), old_pet)
        active = json.loads((self.repo / ".local/deployment-receipt.json").read_text())
        self.assertEqual(active, initial, "full rollback must restore the previous successful authority")
        history = [json.loads(path.read_text()) for path in (self.repo / ".local").glob("deployment-*/receipt.json")]
        failures = [entry for entry in history if entry["status"] == "rolled-back"]
        self.assertEqual(len(failures), 1)
        self.assertIn("verification failed", failures[0]["error"])
        result = self.run_deploy()
        self.assertNotIn("petAction", result)
        self.assertEqual((self.pet / "pet.json").read_bytes(), b'{"name":"cat"}')

    def test_receipt_write_failure_never_restores_success_authority(self):
        self.run_deploy()
        write = self.deploy.write_receipt
        injected = []
        def failing(local, receipt, lock):
            if receipt["status"] == "prepared" and "app-published" in receipt["stages"] and not injected:
                injected.append(True)
                raise OSError("receipt storage failed")
            return write(local, receipt, lock)
        with mock.patch.object(self.deploy, "write_receipt", failing):
            with self.assertRaisesRegex(Exception, "receipt storage failed"):
                self.run_deploy()
        receipt = json.loads((self.repo / ".local/deployment-receipt.json").read_text())
        self.assertEqual(receipt["status"], "recovery-failed")
        with self.assertRaisesRegex(Exception, "recovery"):
            self.run_deploy()

    def test_demoted_config_authority_is_not_restored_after_rollback(self):
        initial = self.run_deploy()
        self.config = dict(self.config, dataRoot=str(self.home / "new-album"))
        write_config(self.config, repository=self.repo, home=self.home)
        verify = self.runtime.verify_app
        def fail_published(app, *args):
            if app == self.app:
                raise ValueError("published app verification failed")
            return verify(app, *args)
        with mock.patch.object(self.runtime, "verify_app", fail_published):
            with self.assertRaisesRegex(Exception, "verification failed"):
                self.deploy.deploy(self.repo, self.config, home=self.home, runtime=self.runtime,
                                   output_fn=lambda _: None, confirm_album_change=lambda old, new: True)
        active = json.loads((self.repo / ".local/deployment-receipt.json").read_text())
        self.assertEqual(active["status"], "rolled-back")
        self.assertNotEqual(active["runID"], initial["runID"])

    def test_failed_receipt_restoration_leaves_fatal_marker(self):
        initial = self.run_deploy()
        write = self.deploy.write_receipt
        verify = self.runtime.verify_app
        def fail_published(app, *args):
            if app == self.app:
                raise ValueError("published app verification failed")
            return verify(app, *args)
        def fail_restore(local, receipt, lock):
            if receipt["runID"] == initial["runID"]:
                raise OSError("old receipt restore failed")
            return write(local, receipt, lock)
        with mock.patch.object(self.runtime, "verify_app", fail_published):
            with mock.patch.object(self.deploy, "write_receipt", fail_restore):
                with self.assertRaisesRegex(Exception, "verification failed"):
                    self.run_deploy()
        active = json.loads((self.repo / ".local/deployment-receipt.json").read_text())
        self.assertEqual(active["status"], "recovery-failed")
        self.assertNotEqual(active["runID"], initial["runID"])
        with self.assertRaisesRegex(Exception, "recovery"):
            self.run_deploy()

    def test_incomplete_receipts_remain_fatal_when_config_changes(self):
        initial = self.run_deploy()
        self.config = dict(self.config, dataRoot=str(self.home / "new-album"))
        write_config(self.config, repository=self.repo, home=self.home)
        path = self.repo / ".local/deployment-receipt.json"
        for status in ("prepared", "recovery-failed"):
            with self.subTest(status=status):
                path.write_text(json.dumps(dict(initial, status=status)))
                with self.assertRaisesRegex(Exception, "recovery"):
                    self.files.read_receipt(self.repo / ".local", self.config)

    def test_launcher_is_directory_independent(self):
        launcher = SCRIPTS.parent / "Deploy Local.command"
        self.assertTrue(launcher.exists())
        self.assertEqual(launcher.stat().st_mode & 0o777, 0o755)
        result = subprocess.run([str(launcher), "--help"], cwd=str(self.base), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--reuse-existing", result.stdout)


if __name__ == "__main__":
    unittest.main()
