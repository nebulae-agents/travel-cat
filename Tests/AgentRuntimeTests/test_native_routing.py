import io
import pathlib
import sys
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'Sources/TravelCatApp/Resources/AgentRuntime'))
import sidecar


class NativeRoutingTests(unittest.TestCase):
    def test_native_command_uses_controller_not_docker_or_provider(self):
        controller = sidecar.Controller()
        events = []
        controller.emit = events.append
        native = Mock()
        native.handle.return_value = {'connected': True}
        controller.native = native
        controller.handle({'id': '1', 'method': 'native_connect', 'params': {'instanceId': 'test'}})
        native.handle.assert_called_once_with('native_connect', {'instanceId': 'test'})
        self.assertEqual(events, [{'id': '1', 'result': {'connected': True}}])
        self.assertEqual(controller.tasks, {})
        controller.native.close()

    def test_shutdown_closes_native_transport_without_docker_task(self):
        controller = sidecar.Controller()
        native = Mock()
        controller.native = native
        with patch.object(sidecar.sys, 'stdin', io.TextIOWrapper(io.BytesIO(b''))):
            controller.run()
        native.close.assert_called_once_with()

    def test_native_failure_message_is_sanitized_at_boundary(self):
        controller = sidecar.Controller()
        events = []
        controller.emit = events.append
        native = Mock()
        native.handle.side_effect = ValueError('secret from untrusted server')
        controller.native = native
        controller.handle({'id': '1', 'method': 'native_connect', 'params': {}})
        self.assertEqual(events[0]['error'], 'runtime command failed')
        controller.native.close()
