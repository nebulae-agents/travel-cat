"""Read-only artifacts stay bound to verified native workspace descriptors."""
import base64
import os
from pathlib import Path
import unittest
import test_codex_native as fixtures
native = fixtures.native

class NativeArtifactTests(unittest.TestCase):
    setUp = fixtures.NativeControllerTests.setUp
    start = fixtures.NativeControllerTests.start
    def test_artifacts_use_bound_root_and_export_actual_bytes(self):
        self.start()
        (self.workspace / 'result.md').write_text('真实结果')
        other = self.root / 'other'; other.mkdir(); (other / 'foreign.txt').write_text('foreign')
        args = {'taskId': 'task-1', 'workspace': str(other), 'root': str(other)}
        self.assertEqual(self.controller.handle('native_artifacts', args), {'files': [{'path':'result.md','size':12}]})
        exported = self.controller.handle('native_export', {**args, 'path':'result.md'})
        self.assertEqual(exported['name'], 'result.md')
        self.assertEqual(base64.b64decode(exported['base64']), '真实结果'.encode())
        self.assertTrue(self.connected['capabilities']['artifacts'])

    def test_unbound_disconnected_and_forged_task_are_denied(self):
        for task in ('task-1', 'forged'):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_artifacts', {'taskId':task})
        self.start(); self.controller.instances[self.instance]['connected'] = False
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_export', {'taskId':'task-1','path':'a.txt'})

    def test_unsafe_files_never_escape_or_appear(self):
        self.start()
        (self.workspace / 'ok.txt').write_text('ok')
        secret = self.root / 'outside.txt'; secret.write_text('private')
        (self.workspace / 'alias.txt').symlink_to(secret)
        os.link(secret, self.workspace / 'hard.txt')
        (self.workspace / '.hidden').write_text('hidden')
        (self.workspace / 'access-token.txt').write_text('secret')
        (self.workspace / 'large.bin').write_bytes(b'x' * (4*1024*1024+1))
        self.assertEqual(self.controller.handle('native_artifacts', {'taskId':'task-1'})['files'], [{'path':'ok.txt','size':2}])
        for path in ('../outside.txt', str(secret), 'alias.txt','hard.txt','.hidden','access-token.txt','large.bin'):
            with self.subTest(path=path), self.assertRaises(native.NativeFailure):
                self.controller.handle('native_export', {'taskId':'task-1','path':path})

    def test_directory_replaced_with_symlink_and_listing_limits_fail_closed(self):
        self.start()
        folder = self.workspace / 'sub'; folder.mkdir(); (folder / 'result.txt').write_text('safe')
        folder.rename(self.workspace / 'old'); folder.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_export', {'taskId':'task-1','path':'sub/outside.txt'})
        folder.unlink()
        for n in range(201): (self.workspace / ('file%d.txt' % n)).write_text('x')
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_artifacts', {'taskId':'task-1'})

    def test_replaced_workspace_ancestor_does_not_retarget_reads(self):
        self.start()
        self.workspace.rename(self.root / 'saved-workspace')
        parent = self.root / 'parent'; parent.mkdir()
        self.workspace = parent / 'workspace'; self.workspace.mkdir()
        self.controller.instances[self.instance]['config']['workspace'] = str(self.workspace)
        replacement = self.root / 'replacement'; replacement.mkdir()
        (replacement / 'workspace').mkdir(); (replacement / 'workspace' / 'foreign.txt').write_text('foreign')
        parent.rename(self.root / 'saved-parent'); parent.symlink_to(replacement, target_is_directory=True)
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_artifacts', {'taskId':'task-1'})

    def test_reconnected_instance_requires_current_generation_resume_before_reads(self):
        self.start()
        (self.workspace / 'result.md').write_text('verified result')
        original_generation = self.controller.tasks['task-1']['generation']
        self.transport.event('connection/lost', {})
        self.controller.handle('native_connect', self.params)
        self.assertNotEqual(original_generation, self.controller.instances[self.instance]['generation'])
        for method in ('native_artifacts', 'native_export'):
            with self.subTest(method=method), self.assertRaises(native.NativeFailure):
                self.controller.handle(method, {'taskId':'task-1', 'path':'result.md'})
        self.controller.handle('native_resume', {'instanceId':self.instance, 'taskId':'task-1', 'threadId':'thread-1'})
        self.assertEqual(self.controller.handle('native_artifacts', {'taskId':'task-1'})['files'], [{'path':'result.md', 'size':15}])
        self.assertEqual(base64.b64decode(self.controller.handle('native_export', {'taskId':'task-1', 'path':'result.md'})['base64']), b'verified result')
