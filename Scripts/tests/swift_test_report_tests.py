import importlib.util
import json
import os
import signal
import time
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('swift_test_report', ROOT / 'Scripts/swift_test_report.py')
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)

class SwiftTestReportTests(unittest.TestCase):
    def collector(self, limit=5000):
        return REPORT.ResultCollector({'FixtureTests.testExample'}, limit=limit)
    def test_only_static_public_identity_outcome_and_duration_survive(self):
        c = self.collector()
        c.consume("Test Case '-[Fixture.FixtureTests testExample]' failed (0.125 seconds).")
        c.consume('/private/home/person.swift:42: error: token=canary-private-value')
        c.consume("Test Case '-[Fixture.FixtureTests secretCanary]' failed (1.0 seconds).")
        c.consume('Test Case malicious body token=canary-private-value')
        self.assertEqual(c.tests, [{'name': 'FixtureTests.testExample', 'outcome': 'failed', 'durationSeconds': 0.125}])
        self.assertNotIn('canary', json.dumps(c.tests))
    def test_skips_ansi_and_swift_testing_aggregate(self):
        c = self.collector()
        c.consume("\x1b[32mTest Case '-[Fixture.FixtureTests testExample]' skipped (0.001 seconds).\x1b[0m")
        c.consume('✔ Test run with 36 tests in 6 suites passed after 0.123 seconds.')
        self.assertEqual(c.tests[0]['outcome'], 'skipped')
        self.assertEqual(c.swift_testing, {'testCount': 36, 'outcome': 'passed'})
        c.consume('✘ Test run with 36 tests failed after 0.123 seconds with 1 issue.')
        self.assertEqual(c.swift_testing, {'testCount': 72, 'outcome': 'failed'})
    def test_bounded_duplicate_or_malformed_results(self):
        c = self.collector(limit=1)
        for _ in range(4): c.consume("Test Case '-[Fixture.FixtureTests testExample]' passed (0.1 seconds).")
        c.consume("Test Case '-[Fixture.FixtureTests testExample]' failed (nan seconds).")
        self.assertEqual(len(c.tests), 1)
        self.assertTrue(c.truncated)
    def test_static_name_allowlist_comes_from_sources(self):
        names = REPORT.public_test_names(ROOT)
        self.assertIn('AgentWorkbenchRecoveryTests.testKeychainDenialOffersInAppRetry', names)
        self.assertNotIn('FixtureTests.secretCanary', names)
    def test_failed_process_preserves_exit_and_discards_sensitive_output(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'safe.json'
            code = "print(\"Test Case '-[Fixture.FixtureTests testExample]' failed (0.1 seconds).\");print('private-token-canary');raise SystemExit(7)"
            status = REPORT.run_tests([sys.executable, '-c', code], out, {'FixtureTests.testExample'}, metadata={'timezone': 'UTC', 'sourceRevision': 'private-canary', 'unknown': 'private-canary'})
            self.assertEqual(status, 7)
            data = json.loads(out.read_text())
            self.assertEqual(data['exitCode'], 7)
            self.assertEqual(data['tests'][0]['outcome'], 'failed')
            self.assertNotIn('canary', out.read_text())
            self.assertEqual(data['environment'], {'timezone': 'UTC'})
    def test_timeout_and_no_results_still_publish_bounded_report(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'safe.json'
            status = REPORT.run_tests([sys.executable, '-c', 'import time; time.sleep(20)'], out, set(), timeout=0.1)
            self.assertEqual(status, 124)
            self.assertEqual(json.loads(out.read_text())['reportStatus'], 'timedOut')
            status = REPORT.run_tests([sys.executable, '-c', 'raise SystemExit(3)'], out, set())
            self.assertEqual(status, 3)
            self.assertEqual(json.loads(out.read_text())['reportStatus'], 'resultsUnavailable')
    def test_timeout_cleans_descendant_after_group_leader_exits(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'safe.json'
            marker = Path(d) / 'ticks'
            pid_file = Path(d) / 'owned-child'
            child = "import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path(" + repr(str(pid_file)) + ").write_text(str(os.getpid()));p=Path(" + repr(str(marker)) + ");exec('while True: p.write_text(str(time.monotonic())); time.sleep(0.03)')"
            parent = "import subprocess,sys,time;subprocess.Popen([sys.executable,'-c'," + repr(child) + "],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);time.sleep(20)"
            try:
                self.assertEqual(REPORT.run_tests([sys.executable, '-c', parent], out, set(), timeout=0.5), 124)
                before = marker.read_text()
                time.sleep(0.2)
                self.assertEqual(marker.read_text(), before, 'Owned descendant must stop even after its parent exits')
            finally:
                if pid_file.exists():
                    try: os.kill(int(pid_file.read_text()), signal.SIGKILL)
                    except ProcessLookupError: pass

    def test_nested_interrupt_during_group_cleanup_returns_controlled_nonzero_report(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'safe.json'
            code = """
import importlib.util,os,signal,sys,threading
from pathlib import Path
spec=importlib.util.spec_from_file_location('report',sys.argv[1])
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
original=m.os.killpg
injected=False
def nested(pid,sig):
    global injected
    if not injected:
        injected=True
        os.kill(os.getpid(),signal.SIGINT)
    original(pid,sig)
m.os.killpg=nested
threading.Timer(0.1,lambda:os.kill(os.getpid(),signal.SIGINT)).start()
sys.exit(m.run_tests([sys.executable,'-c','import time;time.sleep(1)'],Path(sys.argv[2]),set()))
"""
            result = subprocess.run([sys.executable, '-c', code, str(ROOT / 'Scripts/swift_test_report.py'), str(out)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            self.assertEqual(result.returncode, 130)
            self.assertEqual(json.loads(out.read_text())['reportStatus'], 'interrupted')
            self.assertEqual(json.loads(out.read_text())['exitCode'], 130)

    def test_report_write_failure_does_not_echo_private_path_or_reuse_old_results(self):
        with tempfile.TemporaryDirectory() as d:
            bad = Path(d) / 'private-canary'
            bad.mkdir()
            from contextlib import redirect_stdout
            from io import StringIO
            printed = StringIO()
            with redirect_stdout(printed):
                status = REPORT.run_tests([sys.executable, '-c', 'raise SystemExit(0)'], bad, set())
            self.assertEqual(status, 73)
            self.assertNotIn('private-canary', printed.getvalue())

    def test_launch_failure_and_oversized_lines_never_echo_paths(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'safe.json'
            status = REPORT.run_tests(['/missing/private-canary/program'], out, set())
            self.assertEqual(status, 127)
            self.assertNotIn('private-canary', out.read_text())
            status = REPORT.run_tests([sys.executable, '-c', "print('sensitive-canary'*10000)"], out, set())
            self.assertEqual(status, 0)
            self.assertLess(out.stat().st_size, 4096)
            self.assertNotIn('canary', out.read_text())

if __name__ == '__main__': unittest.main()
