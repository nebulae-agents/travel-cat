import io
import pathlib
import sys
import unittest
import uuid
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'Sources/TravelCatApp/Resources/AgentRuntime'))
import sidecar


IMAGE = 'localhost:5000/codex-acp@sha256:' + 'a' * 64
CONTEXT = 'colima-safe'


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.controller = sidecar.Controller()
        self.output = []
        self.controller.emit = self.output.append
        self.probe_id = str(uuid.uuid4())
        self.inventory = {'tools': [], 'contexts': [{'name': CONTEXT, 'local': True, 'available': True}],
                          'images': [{'context': CONTEXT, 'ref': IMAGE}], 'containers': []}

    def command(self, **changes):
        params = dict(probeId=self.probe_id, dockerContext=CONTEXT, image=IMAGE, command=['codex-acp'])
        params.update(changes)
        return {'id': 'call', 'method': 'probe', 'params': params}

    def test_success_handshake_and_confirmed_cleanup(self):
        calls = []
        class FakeTask:
            created = True
            name = 'travelcat-agent-fake'
            def __init__(self, task_id, instance, provider, emit, files=None, audit=None, model_policy='review'):
                self.task_id = task_id
                calls.append(('init', instance, files, type(audit).__name__, provider.url.geturl()))
            def start(self):
                calls.append(('start',))
                return {'sessionId': 'session'}
            def stop(self):
                calls.append(('stop',))
                self.created = False
                return {'stopped': True}
        with patch.object(sidecar.runtime_discovery, 'scan_local', return_value=self.inventory), \
             patch.object(sidecar, 'Task', FakeTask):
            self.controller.handle(self.command())
        result = self.output[-1]['result']
        self.assertEqual(result['probeId'], self.probe_id)
        self.assertTrue(result['compatible'])
        self.assertTrue(result['cleanupConfirmed'])
        self.assertEqual([x[0] for x in calls], ['init', 'start', 'stop'])
        self.assertEqual(calls[0][1], {'image': IMAGE, 'command': ['codex-acp'], 'dockerContext': CONTEXT})
        self.assertEqual(calls[0][3], 'RejectingBroker')
        self.assertEqual(calls[0][4], 'https://127.0.0.1/v1')
        self.assertEqual(self.controller.probes, {})

    def test_start_failure_with_unconfirmed_removal_is_retryable(self):
        class FakeTask:
            created = True
            name = 'travelcat-agent-retained'
            def __init__(self, *args, **kwargs): pass
            def start(self): raise sidecar.RuntimeFailure('unsupported ACP protocol version')
            def stop(self):
                self.created = False
                return {'stopped': True}
        with patch.object(sidecar.runtime_discovery, 'scan_local', return_value=self.inventory), \
             patch.object(sidecar, 'Task', FakeTask):
            self.controller.handle(self.command())
            result = self.output[-1]['result']
            self.assertFalse(result['compatible'])
            self.assertFalse(result['cleanupConfirmed'])
            self.assertEqual(result['containerName'], 'travelcat-agent-retained')
            self.assertIn(self.probe_id, self.controller.probes)
            self.controller.handle({'id': 'cleanup', 'method': 'probe_cleanup', 'params': {'probeId': self.probe_id}})
        self.assertTrue(self.output[-1]['result']['cleanupConfirmed'])
        self.assertEqual(self.controller.probes, {})

    def test_start_failure_with_confirmed_cleanup_is_not_retained(self):
        class FakeTask:
            created = False
            name = 'travelcat-agent-cleaned'
            def __init__(self, *args, **kwargs): pass
            def start(self): raise sidecar.RuntimeFailure('unsupported ACP protocol version')
        with patch.object(sidecar.runtime_discovery, 'scan_local', return_value=self.inventory), \
             patch.object(sidecar, 'Task', FakeTask):
            self.controller.handle(self.command())
        result = self.output[-1]['result']
        self.assertFalse(result['compatible'])
        self.assertTrue(result['cleanupConfirmed'])
        self.assertEqual(self.controller.probes, {})

    def test_controller_eof_retries_retained_probe_cleanup(self):
        stops = []
        class RetainedProbe:
            def stop(self):
                stops.append('stop')
                return {'stopped': True}
        self.controller.probes[self.probe_id] = RetainedProbe()
        stream = type('FakeStdin', (), {'buffer': io.BytesIO(b'')})()
        with patch.object(sidecar.sys, 'stdin', stream):
            self.controller.run()
        self.assertEqual(stops, ['stop'])

    def test_remote_or_unlisted_image_is_never_started(self):
        self.inventory['contexts'][0]['local'] = False
        with patch.object(sidecar.runtime_discovery, 'scan_local', return_value=self.inventory), \
             patch.object(sidecar, 'Task') as task:
            self.controller.handle(self.command())
        task.assert_not_called()
        self.assertIn('error', self.output[-1])
