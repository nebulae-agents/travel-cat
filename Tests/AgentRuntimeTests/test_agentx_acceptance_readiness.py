import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pilot_fixture', REPO / 'Scripts/run-agentx-pi-pilot-acceptance.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

class TestReadiness(unittest.TestCase):
    def test_cold_handshake_may_take_more_than_eight_seconds(self):
        with tempfile.TemporaryDirectory() as d:
            endpoint = Path(d)/'endpoint'; endpoint.write_bytes(b'old')
            clock = [0.0]
            def advance(seconds):
                clock[0] += seconds
                if clock[0] >= 9: endpoint.write_bytes(b'new')
            with patch.object(fixture.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(fixture.time, 'sleep', side_effect=advance):
                fixture.await_daemon_ready(endpoint, b'old', Mock(poll=Mock(return_value=None)))
            self.assertGreaterEqual(clock[0], 9)

    def test_stale_endpoint_does_not_bypass_deadline(self):
        with tempfile.TemporaryDirectory() as d:
            endpoint=Path(d)/'endpoint';endpoint.write_bytes(b'old');clock=[0.0]
            def advance(seconds): clock[0] += seconds
            with patch.object(fixture.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(fixture.time, 'sleep', side_effect=advance):
                with self.assertRaisesRegex(RuntimeError, 'readiness timed out'):
                    fixture.await_daemon_ready(endpoint,b'old',Mock(poll=Mock(return_value=None)),timeout=.2)
            self.assertLess(clock[0], .3)
