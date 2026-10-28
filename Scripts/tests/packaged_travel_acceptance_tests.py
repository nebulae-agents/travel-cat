"""The packaged acceptance harness must fail closed without echoing subprocess data."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("packaged_travel_acceptance", Path(__file__).resolve().parents[1] / "run-packaged-travel-acceptance.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PackagedTravelAcceptanceHarnessTests(unittest.TestCase):
    def probe(self, body, timeout=5):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            executable = root / "probe"
            executable.write_text("#!" + sys.executable + "\n" + body)
            executable.chmod(0o700)
            return MODULE.run_probe(executable, root, {}, timeout=timeout)

    def test_probe_reads_exact_structured_output(self):
        result = self.probe("print(" + repr(json.dumps({"schemaVersion": 1, "status": "failed", "code": "missingResource"})) + ")\nraise SystemExit(1)")
        self.assertEqual(result, (1, {"schemaVersion": 1, "status": "failed", "code": "missingResource"}))

    def test_timeout_is_bounded_and_fixed(self):
        with self.assertRaisesRegex(MODULE.AcceptanceFailure, "^probeTimedOut$"):
            self.probe("import time\ntime.sleep(30)", timeout=0.05)

    def test_non_json_output_is_rejected_without_exposing_it(self):
        with self.assertRaisesRegex(MODULE.AcceptanceFailure, "^invalidReport$"):
            self.probe("print('private-provider-output')")

    def test_success_requires_actual_lifecycle_and_resources(self):
        report = {"schemaVersion": 1, "status": "ok", "packagedResourceCount": 6,
                  "copiedResourceCount": 6, "pendingObserved": True, "readyObserved": True,
                  "readbackVerified": True, "narrativeCalls": 5, "imageCalls": 1}
        MODULE.verify_success(0, report)
        for name, value in [("packagedResourceCount", 5), ("copiedResourceCount", 5),
                            ("pendingObserved", False), ("readyObserved", False),
                            ("readbackVerified", False), ("imageCalls", 0)]:
            with self.subTest(field=name), self.assertRaises(MODULE.AcceptanceFailure):
                MODULE.verify_success(0, dict(report, **{name: value}))
        with self.assertRaises(MODULE.AcceptanceFailure):
            MODULE.verify_success(1, report)
        with self.assertRaises(MODULE.AcceptanceFailure):
            MODULE.verify_success(0, dict(report, privateDebugOutput="must not reach CI artifact"))


if __name__ == "__main__":
    unittest.main()
