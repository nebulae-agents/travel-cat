import importlib.util
import stat
import tempfile
import unittest
import warnings
import os
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "package-project.py"


class CandidateAssemblyTests(unittest.TestCase):
    def test_candidate_requires_public_license_and_notice(self):
        for name in ("LICENSE", "NOTICE"):
            self.assertIn(name, self.module.REQUIRED_CANDIDATE)
        self.assertNotIn("LICENSE_STATUS.md", self.module.REQUIRED_CANDIDATE)

    def test_app_only_candidate_needs_no_external_pet_or_plugin(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"; candidate = root / "candidate"
            self.make_candidate_fixture(source, candidate)
            for legacy in ("Plugins", "Pet", "Install Default Pet.command"):
                self.assertFalse((candidate / legacy).exists())
            self.module.verify_candidate_layout(source, candidate)

    def test_app_only_candidate_rejects_legacy_distribution_extras(self):
        for legacy in ("Plugins", "Pet", "Install Default Pet.command"):
            with self.subTest(legacy=legacy), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / "source"; candidate = root / "candidate"
                self.make_candidate_fixture(source, candidate)
                (candidate / legacy).write_bytes(b"legacy")
                with self.assertRaises(ValueError):
                    self.module.verify_candidate_layout(source, candidate)

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("package_project", SCRIPT)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_safe_extract_preserves_regular_modes_and_bytes(self):
        with tempfile.TemporaryDirectory(prefix="candidate fixture ") as temporary:
            root = Path(temporary)
            archive = root / "source.zip"
            with zipfile.ZipFile(archive, "w") as output:
                for name, mode, data in [("TravelCat/README.md", 0o100644, b"readme"),
                                         ("TravelCat/Scripts/run.sh", 0o100755, b"#!/bin/sh\n")]:
                    info = zipfile.ZipInfo(name)
                    info.create_system = 3
                    info.external_attr = mode << 16
                    output.writestr(info, data)
            destination = root / "fresh source with spaces"
            self.module.safe_extract(archive, destination)
            self.assertEqual((destination / "TravelCat/README.md").read_bytes(), b"readme")
            self.assertEqual(stat.S_IMODE((destination / "TravelCat/Scripts/run.sh").stat().st_mode), 0o755)

    def test_safe_extract_rejects_traversal_links_duplicates_and_bad_modes(self):
        cases = [
            [("../escape", 0o100644)],
            [("TravelCat/link", 0o120777)],
            [("TravelCat/a", 0o100644), ("TravelCat/a", 0o100644)],
            [("TravelCat/device", 0o060644)],
        ]
        for entries in cases:
            with self.subTest(entries=entries), tempfile.TemporaryDirectory() as temporary:
                archive = Path(temporary) / "bad.zip"
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    with zipfile.ZipFile(archive, "w") as output:
                        for name, mode in entries:
                            info = zipfile.ZipInfo(name); info.create_system = 3; info.external_attr = mode << 16
                            output.writestr(info, b"x")
                with self.assertRaises(ValueError):
                    self.module.safe_extract(archive, Path(temporary) / "out")

    def test_verify_candidate_layout_requires_members_bytes_modes_and_no_links(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"; candidate = root / "candidate"
            self.make_candidate_fixture(source, candidate)
            self.module.verify_candidate_layout(source, candidate)
            (candidate / "Travel Cat.app/Contents/Resources/TravelCat_TravelUI.bundle/pet.json").write_bytes(b"changed")
            with self.assertRaises(ValueError):
                self.module.verify_candidate_layout(source, candidate)
            import shutil
            shutil.rmtree(candidate)
            self.make_candidate_fixture(source, candidate)
            (candidate / "INSTALLATION.md").unlink()
            with self.assertRaises(ValueError):
                self.module.verify_candidate_layout(source, candidate)
            shutil.rmtree(candidate)
            self.make_candidate_fixture(source, candidate)
            (candidate / "Install Default Pet.command").write_bytes(b"legacy")
            with self.assertRaises(ValueError):
                self.module.verify_candidate_layout(source, candidate)
            shutil.rmtree(candidate)
            self.make_candidate_fixture(source, candidate)
            (candidate / "Travel Cat.app/Contents/Helpers/travelcatctl").unlink()
            with self.assertRaises(ValueError):
                self.module.verify_candidate_layout(source, candidate)
            shutil.rmtree(candidate)
            self.make_candidate_fixture(source, candidate)
            (candidate / "Travel Cat.app/Contents/Resources/travelcatctl-release.provenance").unlink()
            with self.assertRaises(ValueError):
                self.module.verify_candidate_layout(source, candidate)
            shutil.rmtree(candidate)
            self.make_candidate_fixture(source, candidate)
            (candidate / "Travel Cat.app/Contents/Helpers/travelcatctl").chmod(0o755)
            with self.assertRaises(ValueError):
                self.module.verify_candidate_layout(source, candidate)
            shutil.rmtree(candidate)
            self.make_candidate_fixture(source, candidate)
            resource = candidate / "Travel Cat.app/Contents/Resources/TravelCat_TravelUI.bundle"
            resource.rename(candidate / "resource-real")
            resource.symlink_to(candidate / "resource-real", target_is_directory=True)
            with self.assertRaises(ValueError):
                self.module.verify_candidate_layout(source, candidate)

    def make_candidate_fixture(self, source, candidate):
        source.mkdir(exist_ok=True); candidate.mkdir()
        pet_source = source / "Sources/TravelUI/Resources"
        pet_source.mkdir(parents=True, exist_ok=True)
        (pet_source / "pet.json").write_bytes(b"pet")
        (pet_source / "cute-black-cat-spritesheet.webp").write_bytes(b"sprite")
        for path, data, mode in [
            ("Travel Cat.app/Contents/Info.plist", b"plist", 0o644),
            ("Travel Cat.app/Contents/Resources/TravelCat_TravelUI.bundle/pet.json", b"pet", 0o644),
            ("Travel Cat.app/Contents/Resources/TravelCat_TravelUI.bundle/cute-black-cat-spritesheet.webp", b"sprite", 0o644),
            ("Travel Cat.app/Contents/Helpers/travelcatctl", b"helper", 0o555),
            ("Travel Cat.app/Contents/Resources/travelcatctl-release.provenance", b"provenance", 0o444),
            ("README.md", b"candidate", 0o644),
            ("LICENSE", b"Apache License", 0o644),
            ("NOTICE", b"Travel Cat", 0o644),
            ("THIRD_PARTY_NOTICES.md", b"notices", 0o644),
            ("OFL.txt", b"ofl", 0o644),
            ("INSTALLATION.md", b"install", 0o644),
        ]:
            target = candidate / path; target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data); target.chmod(mode)

    def test_reserve_output_rejects_repo_relative_existing_and_nonabsolute_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary) / "repo"; repo.mkdir()
            outside = Path(temporary) / "deliverable"
            with self.assertRaises(ValueError): self.module.reserve_output(repo, Path("relative"))
            with self.assertRaises(ValueError): self.module.reserve_output(repo, repo / "inside")
            outside.mkdir()
            with self.assertRaises(ValueError): self.module.reserve_output(repo, outside)

    def test_candidate_zip_preserves_helper_mode_and_rejects_fifo(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); tree = root / "tree"; tree.mkdir()
            helper = tree / "helper"; helper.write_bytes(b"binary"); helper.chmod(0o555)
            archive = self.module.write_zip(tree, root / "candidate.zip", "Candidate")
            extracted = self.module.safe_extract(archive, root / "extracted")
            self.assertEqual(stat.S_IMODE((extracted / "Candidate/helper").stat().st_mode), 0o555)
            fifo = tree / "unsafe-fifo"; os.mkfifo(fifo)
            with self.assertRaises(ValueError): self.module.reject_links_and_unsafe_modes(tree)

    def test_build_environment_drops_live_and_ambient_travel_cat_overrides(self):
        parent = {"PATH": "/bin", "TRAVEL_CAT_LIVE_JOURNEY_ACCEPTANCE": "1",
                  "TRAVEL_CAT_LIVE_RENDER_SESSION": "yes", "TRAVEL_CAT_LIVE_PRODUCTION_ROOT": "/live",
                  "TRAVEL_CAT_DATA": "/production", "TRAVEL_CAT_SCRATCH_ROOT": "/old"}
        result = self.module.build_environment(parent, Path("/tmp/owned scratch"))
        self.assertEqual(result["PATH"], "/bin")
        self.assertEqual(result["TRAVEL_CAT_SCRATCH_ROOT"], "/tmp/owned scratch")
        self.assertEqual([key for key in result if key.startswith("TRAVEL_CAT_")], ["TRAVEL_CAT_SCRATCH_ROOT"])

    def test_extracted_source_rejects_missing_members_and_private_or_runtime_trees(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "TravelCat"
            for name in ("Package.swift", "README.md", "Scripts/package-app.sh",
                         "Plugins/travel-cat/.codex-plugin/plugin.json",
                         "Sources/TravelUI/Resources/pet.json",
                         "Sources/TravelUI/Resources/cute-black-cat-spritesheet.webp"):
                path = source / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b"safe")
            self.module.verify_extracted_source(source)
            forbidden = source / "TravelPetData/state.json"
            forbidden.parent.mkdir(); forbidden.write_bytes(b"private")
            with self.assertRaises(ValueError): self.module.verify_extracted_source(source)
            forbidden.unlink(); forbidden.parent.rmdir()
            (source / "Package.swift").unlink()
            with self.assertRaises(ValueError): self.module.verify_extracted_source(source)

    def test_source_checksum_must_match_digest_and_exact_archive_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "TravelCat-Source.zip"
            archive.write_bytes(b"source")
            checksum = Path(str(archive) + ".sha256")
            checksum.write_text(f"{self.module.digest(archive)}  {archive.name}\n", encoding="utf-8")
            self.module.verify_checksum(archive)
            checksum.write_text(f"{self.module.digest(archive)}  renamed.zip\n", encoding="utf-8")
            with self.assertRaises(ValueError): self.module.verify_checksum(archive)
            checksum.write_text(f"{'0' * 64}  {archive.name}\n", encoding="utf-8")
            with self.assertRaises(ValueError): self.module.verify_checksum(archive)
        packaged_script = SCRIPT.read_bytes()
        self.assertNotIn(b"/" + b"Users" + b"/", packaged_script)


if __name__ == "__main__":
    unittest.main()
