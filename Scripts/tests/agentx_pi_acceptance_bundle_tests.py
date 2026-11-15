import plistlib
import runpy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


HARNESS = runpy.run_path(str(Path(__file__).resolve().parents[1] / "run-agentx-pi-pilot-acceptance.py"))


class AcceptanceBundleTests(unittest.TestCase):
    def setUp(self):
        staged = tempfile.TemporaryDirectory(dir="/private/tmp", prefix="agentxd-pi-e2e-")
        self.addCleanup(staged.cleanup)
        self.workspace = Path(staged.name)
        HARNESS["configure"](self.workspace, 50000)
        scratch = self.workspace / "scratch"
        debug = scratch / "debug"
        debug.mkdir(parents=True)
        (debug / "TravelCatApp").write_bytes(b"test executable")
        for name in ("TravelCat_TravelUI.bundle", "TravelCat_TravelCatApp.bundle"):
            (debug / name).mkdir()
        mock = patch("subprocess.check_output", return_value=str(scratch))
        mock.start()
        self.addCleanup(mock.stop)

    def test_native_reopen_also_gets_both_isolated_directories(self):
        binary = HARNESS["temporary_app"](self.workspace)
        info = plistlib.loads((binary.parent.parent / "Info.plist").read_bytes())
        self.assertEqual(info["LSEnvironment"], {
            "AGENTX_ROOT": str(self.workspace / "root"), "AGENTX_HOST_DIRECTORY": str(self.workspace / "host")})

    def test_foreign_bundle_rejected_before_any_metadata_write(self):
        app = self.workspace / "AgentX Pi Run Acceptance.app"
        contents = app / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "MacOS/TravelCatApp").write_bytes(b"test executable")
        info = contents / "Info.plist"
        before = plistlib.dumps({"CFBundleIdentifier": "other.application"})
        info.write_bytes(before)
        with self.assertRaises(RuntimeError):
            HARNESS["temporary_app"](self.workspace)
        self.assertEqual(info.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
