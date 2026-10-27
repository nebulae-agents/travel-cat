"""Refuse cleanup unless first ownership, terminal state and all daemon identities match."""
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('acceptance_cleanup', Path(__file__).resolve().parents[1] / 'cleanup-native-acceptance.py')
cleanup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleanup)

class NativeAcceptanceCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); instance = '12345678-1234-4234-8234-123456789abc'
        self.profile = self.root / 'store/native-runtime' / instance; self.profile.mkdir(parents=True)
        socket_dir = Path('/private/tmp') / ('tc-native-' + str(cleanup.os.getuid()) + '-' + hashlib.sha256(str(self.profile).encode()).hexdigest()[:24])
        sock = socket_dir / 'server.sock'
        self.params = {'instanceId': instance, 'profileRoot': str(self.profile), 'workspace': str(self.root / 'workspace'), 'executable': '/fixture/codex'}
        config = cleanup.transport._config_text(self.params, socket_dir)
        self.receipt = {'profileRoot': str(self.profile), 'workspace': self.params['workspace'], 'executable': '/fixture/codex', 'socket': str(sock),
            'configHash': hashlib.sha256(config).hexdigest(), 'pid': 12345, 'processIdentity': 'fixture-start /fixture/codex app-server --listen unix://' + str(sock), 'socketInode': 17}
        receipt_bytes = json.dumps(self.receipt, sort_keys=True).encode()
        (self.profile / 'config.toml').write_bytes(config); (self.profile / 'travelcat-daemon.json').write_bytes(receipt_bytes)
        self.owner = {'firstLaunchOwned': True, 'parameters': self.params, 'receiptSHA256': hashlib.sha256(receipt_bytes).hexdigest(), 'receipt': self.receipt}
        self.metadata = {'clientDetached': True, 'sidecarExitConfirmed': True, 'recordedAt': time.time(), 'instanceId': instance,
            'tasks': [{'instanceId': instance, 'status': 'cancelled', 'backgroundCount': 0, 'threadId': 'thread-1', 'turnStatuses': {'turn-1': 'interrupted'}}]}
        self.write('fixture.json', {'instanceId': instance, 'executable': '/fixture/codex', 'workspace': self.params['workspace']})
        self.write('daemon-ownership.json', self.owner); self.write('acceptance-metadata.json', self.metadata)
        self.identity = patch.object(cleanup.transport, '_process_identity', return_value=self.receipt['processIdentity']); self.identity.start(); self.addCleanup(self.identity.stop)
        self.socket = patch.object(cleanup.transport, '_socket_info', return_value=SimpleNamespace(st_ino=17)); self.socket.start(); self.addCleanup(self.socket.stop)
    def write(self, name, value): (self.root / name).write_text(json.dumps(value))
    def test_exact_owned_terminal_daemon_can_be_checked_without_signalling(self):
        with patch.object(cleanup.os, 'kill') as kill:
            self.assertEqual(cleanup.verify(self.root), self.receipt)
            kill.assert_not_called()
    def test_actual_first_connection_executable_is_bound_after_operator_selection(self):
        # The setup form can replace its initially detected program before connecting.
        self.write('fixture.json', {'instanceId': self.params['instanceId'], 'workspace': self.params['workspace'], 'executable': '/initially/detected/codex'})
        try: verified = cleanup.verify(self.root)
        except ValueError: self.fail('Actual successfully connected executable must supersede the initial UI candidate')
        self.assertEqual(verified, self.receipt)
    def test_reused_or_changed_receipt_is_refused(self):
        self.owner['firstLaunchOwned'] = False; self.write('daemon-ownership.json', self.owner)
        with self.assertRaisesRegex(ValueError, 'ownership'): cleanup.verify(self.root)
        self.owner['firstLaunchOwned'] = True; self.write('daemon-ownership.json', self.owner)
        (self.profile / 'travelcat-daemon.json').write_text('{}')
        with self.assertRaisesRegex(ValueError, 'receipt changed'): cleanup.verify(self.root)
    def test_active_background_unknown_and_undetached_are_refused(self):
        for field, value in [('status', 'running'), ('backgroundCount', -1), ('backgroundCount', 1), ('turnStatuses', {'turn-1': 'inProgress'})]:
            original = self.metadata['tasks'][0][field]; self.metadata['tasks'][0][field] = value; self.write('acceptance-metadata.json', self.metadata)
            with self.assertRaises(ValueError): cleanup.verify(self.root)
            self.metadata['tasks'][0][field] = original
        self.metadata['clientDetached'] = False; self.write('acceptance-metadata.json', self.metadata)
        with self.assertRaisesRegex(ValueError, 'detach'): cleanup.verify(self.root)
    def test_replaced_pid_or_socket_or_config_is_refused(self):
        with patch.object(cleanup.transport, '_process_identity', return_value=self.receipt['processIdentity'] + ' changed-start'):
            with self.assertRaisesRegex(ValueError, 'process identity'): cleanup.verify(self.root)
        with patch.object(cleanup.transport, '_socket_info', return_value=SimpleNamespace(st_ino=99)):
            with self.assertRaisesRegex(ValueError, 'socket identity'): cleanup.verify(self.root)
        (self.profile / 'config.toml').write_text('changed')
        with self.assertRaisesRegex(ValueError, 'config changed'): cleanup.verify(self.root)
    def test_detached_flag_without_observed_sidecar_exit_is_refused(self):
        for observed in (False, None):
            if observed is None: self.metadata.pop('sidecarExitConfirmed', None)
            else: self.metadata['sidecarExitConfirmed'] = observed
            self.write('acceptance-metadata.json', self.metadata)
            with patch.object(cleanup.os, 'kill') as kill:
                with self.assertRaisesRegex(ValueError, 'sidecar exit'): cleanup.verify(self.root)
                kill.assert_not_called()
    def test_stale_metadata_is_refused(self):
        self.metadata['recordedAt'] = time.time() - 121; self.write('acceptance-metadata.json', self.metadata)
        with self.assertRaisesRegex(ValueError, 'stale'): cleanup.verify(self.root)

if __name__ == '__main__': unittest.main()
