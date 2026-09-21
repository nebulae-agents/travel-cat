"""Regressions for shell behavior that differs between macOS releases."""

import hashlib
import fcntl
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[2]


class PortableShellTests(unittest.TestCase):
    def test_optional_plist_probe_does_not_leak_missing_key_diagnostic(self):
        source = (PROJECT_ROOT / "Scripts/run-bundled-travelcatctl.sh").read_text()
        probe = re.search(r"^if /usr/bin/plutil -extract TravelCatDataRoot .*; then$", source, re.M)
        self.assertIsNotNone(probe)
        # Older plutil releases emit this expected missing-key error on stdout.
        script = (
            "probe_plutil() { echo 'No value at that key path'; return 1; }\n"
            "PLIST=unused\n"
            + probe.group().replace("/usr/bin/plutil", "probe_plutil")
            + "\n echo configured\nelse\n echo default\nfi\n"
        )
        result = subprocess.run(["/bin/sh", "-c", script], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "default\n")

    @unittest.skipUnless(sys.platform == "darwin", "publisher uses macOS tools")
    def test_publisher_moves_writable_staging_then_seals_and_reuses(self):
        with tempfile.TemporaryDirectory(prefix="travelcat-publisher-") as temp:
            root = Path(temp)
            canonical = root / "canonical"
            canonical.write_text("#!/bin/sh\nexit 0\n")
            canonical.chmod(0o755)
            pinned_root = root / "pinned"
            source = (PROJECT_ROOT / "Scripts/publish-pinned-travelcatctl.sh").read_text()
            # Model macOS 15's refusal to rename a read-only source directory.
            guarded = source.replace(
                '/bin/mv -n -- "$STAGING" "$PINNED_DIR"',
                '[ "$(/usr/bin/stat -f %Lp "$STAGING")" = 700 ] || exit 77\n'
                '/bin/mv -n -- "$STAGING" "$PINNED_DIR"',
            )
            self.assertNotEqual(guarded, source)
            publisher = root / "publisher.sh"
            publisher.write_text(guarded)
            pinned = pinned_root / hashlib.sha256(canonical.read_bytes()).hexdigest() / "travelcatctl"
            try:
                first = subprocess.run(
                    ["/bin/sh", str(publisher), str(canonical), str(pinned_root)],
                    capture_output=True, text=True,
                )
                self.assertEqual(first.returncode, 0, first.stderr)
                self.assertEqual(first.stdout.strip(), str(pinned))
                self.assertEqual(pinned.read_bytes(), canonical.read_bytes())
                self.assertEqual(pinned.stat().st_mode & 0o777, 0o555)
                self.assertEqual(pinned.parent.stat().st_mode & 0o777, 0o555)
                before = pinned.stat().st_mtime_ns
                second = subprocess.run(
                    ["/bin/sh", str(publisher), str(canonical), str(pinned_root)],
                    capture_output=True, text=True,
                )
                self.assertEqual(second.returncode, 0, second.stderr)
                self.assertEqual(pinned.stat().st_mtime_ns, before)
                self.assertFalse(list(pinned_root.glob(".staging.*")))
                lock = pinned_root / (".publish-lock." + pinned.parent.name)
                with lock.open("a") as held:
                    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    busy = subprocess.run(
                        ["/bin/sh", str(publisher), str(canonical), str(pinned_root)],
                        capture_output=True, text=True,
                    )
                    self.assertEqual(busy.returncode, 75)
                    self.assertEqual(busy.stdout, "")
                self.assertEqual(pinned.read_bytes(), canonical.read_bytes())
                # A leftover lock file is harmless once its process releases it.
                recovered = subprocess.run(
                    ["/bin/sh", str(publisher), str(canonical), str(pinned_root)],
                    capture_output=True, text=True,
                )
                self.assertEqual(recovered.returncode, 0, recovered.stderr)
            finally:
                # Only unlock this test's temporary directories for cleanup.
                for directory in root.rglob("*"):
                    if directory.is_dir():
                        directory.chmod(0o700)

    @unittest.skipUnless(sys.platform == "darwin", "publisher uses macOS tools")
    def test_interruption_after_rename_seals_only_owned_artifact(self):
        with tempfile.TemporaryDirectory(prefix="travelcat-interrupted-") as temp:
            root = Path(temp)
            canonical = root / "canonical"
            canonical.write_text("#!/bin/sh\nexit 0\n")
            canonical.chmod(0o755)
            pinned_root = root / "pinned"
            source = (PROJECT_ROOT / "Scripts/publish-pinned-travelcatctl.sh").read_text()
            interrupted = source.replace(
                '/bin/mv -n -- "$STAGING" "$PINNED_DIR"',
                '/bin/mv -n -- "$STAGING" "$PINNED_DIR"\n    kill -TERM $$',
            )
            publisher = root / "publisher.sh"
            publisher.write_text(interrupted)
            pinned = pinned_root / hashlib.sha256(canonical.read_bytes()).hexdigest() / "travelcatctl"
            try:
                first = subprocess.run(
                    ["/bin/sh", str(publisher), str(canonical), str(pinned_root)],
                    capture_output=True, text=True,
                )
                self.assertNotEqual(first.returncode, 0)
                self.assertEqual(first.stdout, "")
                self.assertEqual(pinned.read_bytes(), canonical.read_bytes())
                self.assertEqual(pinned.parent.stat().st_mode & 0o777, 0o555)
                retry = subprocess.run(
                    ["/bin/sh", str(publisher), str(canonical), str(pinned_root)],
                    capture_output=True, text=True,
                )
                self.assertEqual(retry.returncode, 0, retry.stderr)
            finally:
                for directory in root.rglob("*"):
                    if directory.is_dir():
                        directory.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
