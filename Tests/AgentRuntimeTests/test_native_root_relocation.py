"""Offline relocation fixtures never start Codex, access keychains, or touch user profiles."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / 'Sources/TravelCatApp/Resources/AgentRuntime'
spec = importlib.util.spec_from_file_location('relocation_transport', RUNTIME / 'codex_native_transport.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


def socket_dir(profile):
    base = Path('/private/tmp' if Path('/private/tmp').is_dir() else '/tmp')
    return base / ('tc-native-' + str(os.getuid()) + '-' + hashlib.sha256(str(profile).encode()).hexdigest()[:24])


class RootRelocationTests(unittest.TestCase):
    def test_stop_reaps_its_real_owned_child_before_confirming_absence(self):
        child = subprocess.Popen(['/bin/sleep', '30'])
        self.addCleanup(lambda: child.wait(timeout=2) if child.poll() is not None else (child.kill(), child.wait(timeout=2)))
        self.old_receipt['pid'] = child.pid
        (self.old_profile / 'travelcat-daemon.json').write_text(json.dumps(self.old_receipt))
        signaled = []
        real_kill = os.kill
        def kill(pid, value):
            if value == transport.signal.SIGTERM: signaled.append(pid)
            return real_kill(pid, value)
        with patch.object(transport, '_DAEMONS', [child]), patch.object(transport, '_process_identity', side_effect=lambda _: None if signaled else self.old_receipt['processIdentity']), patch.object(transport, '_socket_info') as info, patch.object(transport.os, 'kill', side_effect=kill):
            info.return_value.st_ino = 101
            transport.stop_managed_daemon(self.old)
        self.assertEqual(child.returncode, -transport.signal.SIGTERM)
        with self.assertRaises(ProcessLookupError): real_kill(child.pid, 0)

    def test_host_uppercase_uuid_profile_is_valid(self):
        profile = self.old_root / 'apps/workbench/state/runtime/native-runtime/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
        self.assertEqual(transport._managed_profile_root(profile), self.old_root)

    def test_stop_requires_exact_process_identity(self):
        with patch.object(transport, '_process_identity', return_value='replacement'), patch.object(transport.os, 'kill') as kill:
            with self.assertRaises(transport.NativeFailure):
                transport.stop_managed_daemon(self.old)
            kill.assert_not_called()

    def test_stop_confirms_absence_and_preserves_receipt(self):
        before = (self.old_profile / 'travelcat-daemon.json').read_bytes()
        with patch.object(transport, '_confirmed_absent', side_effect=[False, True]), patch.object(transport, '_process_identity', return_value=self.old_receipt['processIdentity']), patch.object(transport, '_socket_info') as info, patch.object(transport.os, 'kill') as kill:
            info.return_value.st_ino = 101
            transport.stop_managed_daemon(self.old)
            kill.assert_called_once_with(1234567, transport.signal.SIGTERM)
        self.assertEqual(before, (self.old_profile / 'travelcat-daemon.json').read_bytes())

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.old_root, self.new_root = base / 'old', base / 'new'
        self.relative = Path('apps/workbench/state/runtime/native-runtime/11111111-1111-1111-1111-111111111111')
        self.old_profile, self.profile = self.old_root / self.relative, self.new_root / self.relative
        self.old_profile.mkdir(parents=True, mode=0o700)
        self.old = {'profileRoot': str(self.old_profile), 'workspace': str(self.old_root / 'apps/workbench/workspace/project'), 'executable': '/fixture/codex'}
        self.config = {**self.old, 'profileRoot': str(self.profile), 'workspace': str(self.new_root / 'apps/workbench/workspace/project')}
        self.old_content = transport._config_text(self.old, socket_dir(self.old_profile))
        self.old_receipt = {'profileRoot': self.old['profileRoot'], 'workspace': self.old['workspace'], 'executable': self.old['executable'],
            'socket': str(socket_dir(self.old_profile) / 'server.sock'), 'configHash': hashlib.sha256(self.old_content).hexdigest(),
            'pid': 1234567, 'processIdentity': 'fixture /fixture/codex app-server --listen unix://' + str(socket_dir(self.old_profile) / 'server.sock'), 'socketInode': 101}
        (self.old_profile / 'config.toml').write_bytes(self.old_content)
        (self.old_profile / 'travelcat-daemon.json').write_text(json.dumps(self.old_receipt))
        (self.old_profile / 'auth.json').write_bytes(b'opaque-login-fixture')
        (self.old_profile / 'sessions').mkdir()
        (self.old_profile / 'sessions/history').write_bytes(b'opaque-session-fixture')
        shutil.copytree(self.old_profile, self.profile)
        self.profile.chmod(0o700)
        self.marker = self.new_root / 'manager/root-relocation.json'
        self.marker.parent.mkdir(parents=True)
        self.marker.write_text(json.dumps({'version': 1, 'sourceRoot': str(self.old_root), 'destinationRoot': str(self.new_root)}))

    def rebind(self):
        with patch.object(transport, '_process_identity', return_value=None), patch.object(transport.os, 'kill', side_effect=ProcessLookupError):
            return transport._rebind_relocated_profile(self.config, socket_dir(self.profile))

    def test_verified_offline_relocation_rebuilds_only_generated_binding(self):
        self.assertTrue(self.rebind())
        self.assertEqual((self.profile / 'config.toml').read_bytes(), transport._config_text(self.config, socket_dir(self.profile)))
        self.assertFalse((self.profile / 'travelcat-daemon.json').exists())
        self.assertEqual((self.profile / 'auth.json').read_bytes(), b'opaque-login-fixture')
        self.assertEqual((self.profile / 'sessions/history').read_bytes(), b'opaque-session-fixture')
        self.assertEqual((self.old_profile / 'config.toml').read_bytes(), self.old_content)
        self.assertEqual(json.loads((self.old_profile / 'travelcat-daemon.json').read_text()), self.old_receipt)
        self.assertTrue(list((self.profile / 'travelcat-relocations').glob('*.json')))

    def test_missing_or_wrong_root_authorization_preserves_original_files(self):
        self.marker.unlink()
        with self.assertRaises(transport.NativeFailure): self.rebind()
        self.assertEqual((self.profile / 'config.toml').read_bytes(), self.old_content)
        self.assertTrue((self.profile / 'travelcat-daemon.json').exists())
        self.marker.write_text(json.dumps({'version': 1, 'sourceRoot': '/wrong', 'destinationRoot': str(self.new_root)}))
        with self.assertRaises(transport.NativeFailure): self.rebind()

    def test_live_or_unverified_daemon_cannot_be_rebound(self):
        with patch.object(transport, '_process_identity', return_value='still alive'):
            with self.assertRaises(transport.NativeFailure): transport._rebind_relocated_profile(self.config, socket_dir(self.profile))
        with patch.object(transport, '_process_identity', return_value=None), patch.object(transport.os, 'kill', return_value=None):
            with self.assertRaises(transport.NativeFailure): transport._rebind_relocated_profile(self.config, socket_dir(self.profile))
        self.assertEqual((self.profile / 'config.toml').read_bytes(), self.old_content)

    def test_changed_workspace_executable_or_configuration_is_not_authorized(self):
        original = dict(self.config)
        for field, value in [('workspace', str(self.new_root / 'apps/workbench/workspace/other')), ('workspace', '/outside'), ('executable', '/different/codex')]:
            self.config = {**original, field: value}
            with self.assertRaises(transport.NativeFailure): self.rebind()
        self.config = original
        (self.profile / 'config.toml').write_bytes(self.old_content + b'network = true\n')
        with self.assertRaises(transport.NativeFailure): self.rebind()

    def test_interrupted_generated_config_rewrite_can_resume_without_losing_backup(self):
        (self.profile / 'config.toml').write_bytes(transport._config_text(self.config, socket_dir(self.profile)))
        self.assertTrue(self.rebind())
        self.assertEqual((self.profile / 'sessions/history').read_bytes(), b'opaque-session-fixture')
        self.assertFalse((self.profile / 'travelcat-daemon.json').exists())

    def test_linked_receipt_cannot_authorize_relocation(self):
        receipt = self.profile / 'travelcat-daemon.json'
        other = self.new_root / 'receipt-backup'
        os.link(receipt, other)
        with self.assertRaises(transport.NativeFailure): self.rebind()
        self.assertEqual((self.profile / 'config.toml').read_bytes(), self.old_content)


if __name__ == '__main__':
    unittest.main()
