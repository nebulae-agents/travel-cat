"""Artifact evidence is bounded, runtime-owned, and never claims authorship."""
import hashlib
import os
import threading
import time
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'Sources/TravelCatApp/Resources/AgentRuntime'))
import test_codex_native as fixtures
import workspace_io as workspace
import sidecar
import test_runtime

class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
    def manifest(self): return workspace.perform({'method':'manifest'}, self.root)
    def test_same_size_content_has_distinct_sha(self):
        path = self.root / 'result.md'; path.write_bytes(b'first')
        first = self.manifest(); path.write_bytes(b'newer'); second = self.manifest()
        self.assertTrue(first['inventoryComplete']); self.assertTrue(first['hashComplete'])
        self.assertNotEqual(first['files'][0]['sha256'], second['files'][0]['sha256'])
        self.assertEqual(second['files'][0]['sha256'], hashlib.sha256(b'newer').hexdigest())
    def test_budget_and_unsafe_presence_are_unknown_not_missing(self):
        target = self.root / 'result.md'; target.write_bytes(b'abc')
        (self.root / 'link.md').symlink_to(target); os.link(target, self.root / 'hard.md')
        (self.root / 'huge.bin').write_bytes(b'x' * (4*1024*1024+1))
        result = self.manifest(); by_path = {v['path']:v for v in result['files']}
        self.assertTrue(result['inventoryComplete']); self.assertFalse(result['hashComplete'])
        for path in ('link.md','hard.md','result.md','huge.bin'):
            self.assertIn(path, by_path); self.assertNotIn('sha256', by_path[path])
        target.unlink(); (self.root / 'plain.md').write_bytes(b'abcd')
        with patch.object(workspace, 'MANIFEST_TOTAL_LIMIT', 2):
            limited = self.manifest()
        self.assertFalse(limited['hashComplete'])
        self.assertTrue(all('sha256' not in v for v in limited['files']))
    def test_discovery_limit_is_partial_inventory(self):
        for n in range(4): (self.root / ('file%d.md' % n)).write_bytes(b'a')
        with patch.object(workspace, 'MANIFEST_FILE_LIMIT', 2): result = self.manifest()
        self.assertEqual(len(result['files']),2); self.assertFalse(result['inventoryComplete'])
    def test_changed_during_hash_is_unknown(self):
        (self.root / 'result.md').write_bytes(b'first')
        real = workspace.os.read
        def changed(fd, count):
            data = real(fd,count)
            (self.root / 'result.md').write_bytes(b'newer')
            return data
        with patch.object(workspace.os,'read',changed): result = self.manifest()
        self.assertFalse(result['hashComplete']); self.assertNotIn('sha256',result['files'][0])

    def test_root_swap_after_read_rejected(self):
        (self.root/'result.md').write_bytes(b'first')
        original=workspace.manifest
        def swapped(fd):
            result=original(fd)
            saved=self.root.with_name(self.root.name+'-old')
            self.root.rename(saved); self.root.mkdir()
            self.addCleanup(lambda: __import__('shutil').rmtree(saved))
            return result
        with patch.object(workspace,'manifest',swapped):
            with self.assertRaises((ValueError,OSError)):self.manifest()
    def test_baseline_missing_hash_and_missing_inventory_never_claim_new(self):
        current={'files':[{'path':'old.txt','size':2,'sha256':'b'*64},{'path':'new.txt','size':1,'sha256':'c'*64}],'inventoryComplete':True,'hashComplete':True}
        prior={'files':[{'path':'old.txt','size':2,'reason':'unsafe_file'}],'inventoryComplete':False,'hashComplete':False,'checkedAt':1}
        result=workspace.changes(current,prior,'binding','exec')
        self.assertEqual([v['change'] for v in result['files']],['unknown','unknown'])

    def test_incomplete_inventory_never_attributes_a_hashed_entry(self):
        old={'files':[{'path':'r.txt','size':1,'sha256':'a'*64}],'inventoryComplete':True,'hashComplete':True,'checkedAt':1}
        current={'files':[{'path':'r.txt','size':1,'sha256':'b'*64}],'inventoryComplete':False,'hashComplete':True}
        self.assertEqual(workspace.changes(current,old,'binding','exec')['files'][0]['change'],'unknown')

    def test_export_rechecks_relative_ancestor_after_read(self):
        folder=self.root/'sub';folder.mkdir();(folder/'result.md').write_bytes(b'first')
        real=workspace.os.stat;swapped=False
        def stat_after(path,*args,**kwargs):
            nonlocal swapped
            if path=='result.md' and not swapped and 'dir_fd' in kwargs:
                swapped=True;folder.rename(self.root/'saved');folder.mkdir();(folder/'result.md').write_bytes(b'newer')
            return real(path,*args,**kwargs)
        with patch.object(workspace.os,'stat',side_effect=stat_after):
            with self.assertRaises((ValueError,OSError)):workspace.perform({'method':'export','path':'sub/result.md'},self.root)
        self.assertTrue(swapped)

class NativeVersionTests(unittest.TestCase):
    setUp = fixtures.NativeControllerTests.setUp
    start = fixtures.NativeControllerTests.start
    def test_true_baseline_precedes_prompt_same_size_change_and_resume_unknown(self):
        self.start(); path=self.workspace/'result.md'; path.write_bytes(b'first')
        seen=[]
        def prompt(params):
            seen.append(self.controller.tasks['task-1'].get('artifactBaseline'))
            path.write_bytes(b'newer')
            return {'turn':{'id':'turn-1','status':'inProgress'}}
        self.transport.results['turn/start']=prompt
        self.controller.handle('native_prompt',{'taskId':'task-1','text':'change','clientUserMessageId':'m'})
        self.assertIsNotNone(seen[0]); self.assertEqual(seen[0]['files'][0]['sha256'],hashlib.sha256(b'first').hexdigest())
        result=self.controller.handle('native_artifact_changes',{'taskId':'task-1'})
        self.assertEqual(result['files'][0]['change'],'modified'); self.assertTrue(result['bindingId']); self.assertTrue(result['executionId'])
        self.assertNotIn('author',str(result).lower())
        self.controller.handle('native_resume',{'instanceId':self.instance,'taskId':'task-1','threadId':'thread-1'})
        resumed=self.controller.handle('native_artifact_changes',{'taskId':'task-1'})
        self.assertEqual(resumed['files'][0]['change'],'unknown'); self.assertIsNone(resumed['baselineCapturedAt'])
        self.assertNotEqual(result['bindingId'],resumed['bindingId'])
    def test_root_replaced_denied_and_slow_read_does_not_hold_control(self):
        self.start(); (self.workspace/'result.md').write_bytes(b'first')
        original=fixtures.native._workspace_module.perform
        def mutate(request,root):
            self.controller.tasks['task-1']['executionId']='newer-execution'
            self.assertTrue(self.controller.operations.acquire(False))
            self.controller.operations.release()
            return original(request,root)
        with patch.object(fixtures.native._workspace_module,'perform',side_effect=mutate) as observed:
            with self.assertRaises(fixtures.native.NativeFailure): self.controller.handle('native_artifact_changes',{'taskId':'task-1'})
            observed.assert_called_once()
        self.workspace.rename(self.root/'saved'); self.workspace.mkdir(); (self.workspace/'foreign.md').write_bytes(b'foreign')
        with self.assertRaises(fixtures.native.NativeFailure): self.controller.handle('native_artifact_changes',{'taskId':'task-1'})
    def test_completion_before_response_does_not_reactivate_execution(self):
        self.start()
        def prompt(params):
            self.transport.event('turn/completed',{'threadId':'thread-1','turn':{'id':'early','status':'completed'}})
            return {'turn':{'id':'early','status':'inProgress'}}
        self.transport.results['turn/start']=prompt
        self.controller.handle('native_prompt',{'taskId':'task-1','text':'hello','clientUserMessageId':'m'})
        self.assertIsNone(self.controller.tasks['task-1']['turnId'])
        self.assertEqual(self.controller.handle('native_artifact_changes',{'taskId':'task-1'})['turnId'],'early')

    def test_export_rejects_caller_previous_binding_and_execution(self):
        self.start(); (self.workspace/'result.md').write_bytes(b'first')
        task=self.controller.tasks['task-1']
        for extra in ({'bindingId':'old'},{'bindingId':task['bindingId'],'executionId':'old'}):
            with self.assertRaises(fixtures.native.NativeFailure):self.controller.handle('native_export',{'taskId':'task-1','path':'result.md',**extra})
    def test_read_slot_never_queues_and_no_status_poll_scans(self):
        self.start()
        self.controller.background_status_slot.acquire()
        try:
            with self.assertRaises(fixtures.native.NativeFailure):self.controller.handle('native_artifact_changes',{'taskId':'task-1'})
        finally:self.controller.background_status_slot.release()
        with patch.object(fixtures.native._workspace_module,'perform',side_effect=AssertionError('poll scanned files')):
            self.controller.handle('native_background_status',{'taskId':'task-1'})

    def test_artifact_scope_lock_wait_uses_observation_deadline(self):
        self.start()
        for phase in ('initial','after-read'):
            entered,release=threading.Event(),threading.Event();errors=[]
            real=fixtures.native._workspace_module.perform
            def read_files(request,root):
                value=real(request,root);entered.set();release.wait(.4);return value
            def read():
                try:self.controller.handle('native_artifact_changes',{'taskId':'task-1'})
                except fixtures.native.NativeFailure as error:errors.append(error)
            worker=threading.Thread(target=read,daemon=True)
            with patch.object(fixtures.native,'BACKGROUND_STATUS_SECONDS',.04),patch.object(fixtures.native._workspace_module,'perform',side_effect=read_files):
                if phase=='initial':self.controller.lock.acquire()
                worker.start()
                if phase=='after-read':self.assertTrue(entered.wait(.3));self.controller.lock.acquire()
                try:
                    release.set();worker.join(.2);self.assertFalse(worker.is_alive())
                finally:self.controller.lock.release();worker.join(1)
                self.assertEqual(len(errors),1)
    def test_native_baseline_audit_contains_only_scope_and_coverage_metadata(self):
        self.start();(self.workspace/'result.md').write_text('private content')
        records=[]
        class Audit:
            def record(self,*args,**kwargs):records.append((args,kwargs))
        self.controller.audit=Audit()
        self.controller.handle('native_prompt',{'taskId':'task-1','text':'private prompt','clientUserMessageId':'m'})
        self.assertEqual(records[0][0][1],'operation.artifactBaseline')
        for forbidden in ('private content','private prompt','result.md','base64'):
            self.assertNotIn(forbidden,str(records))

    def test_failed_native_baseline_cannot_reuse_previous_execution_evidence(self):
        self.start();path=self.workspace/'result.md';path.write_bytes(b'first')
        self.controller.handle('native_prompt',{'taskId':'task-1','text':'first','clientUserMessageId':'first-message'})
        self.transport.event('turn/completed',{'threadId':'thread-1','turn':{'id':'turn-1','status':'completed'}})
        task=self.controller.tasks['task-1'];previous_execution=task['executionId']
        self.assertIsNotNone(task['artifactBaseline'])
        submitted=sum(method=='turn/start' for method,_ in self.transport.calls)
        path.write_bytes(b'newer')
        with patch.object(self.controller,'_workspace_read',side_effect=fixtures.native.NativeFailure('transient baseline read failure')):
            with self.assertRaises(fixtures.native.NativeFailure):
                self.controller.handle('native_prompt',{'taskId':'task-1','text':'second','clientUserMessageId':'second-message'})
        self.assertNotEqual(task['executionId'],previous_execution)
        self.assertEqual(sum(method=='turn/start' for method,_ in self.transport.calls),submitted)
        changes=self.controller.handle('native_artifact_changes',{'taskId':'task-1'})
        self.assertIsNone(changes['baselineCapturedAt'])
        self.assertEqual(changes['files'][0]['change'],'unknown')
        self.assertIsNone(task['artifactBaseline'])

class ACPVersionTests(unittest.TestCase):
    def task(self):
        return sidecar.Task('00000000-0000-4000-8000-000000000001',dict(image='x@sha256:'+'a'*64,command=['agent']),sidecar.Provider(dict(baseURL='https://example.com/v1',apiKey='canary',model='m',api='responses')),lambda e:None,audit=test_runtime.acknowledged_test_broker())
    def test_baseline_captured_after_import_before_rpc_and_audit_metadata_only(self):
        task=self.task(); task.session='session'; order=[]; records=[]
        task.audit.record=lambda *args,**kw: records.append((args,kw))
        manifest={'files':[{'path':'input.txt','size':3,'sha256':'a'*64}], 'inventoryComplete':True,'hashComplete':True,'checkedAt':1,'rootIdentity':[1,2]}
        def read(method,**kwargs): order.append(method); return manifest
        task.workspace=read
        def rpc(*args): order.append('prompt'); self.assertIsNotNone(task.artifact_baseline); return {'stopReason':'end_turn'}
        task.rpc=rpc
        task.prompt('private prompt body')
        self.assertEqual(order,['manifest','prompt'])
        changes=task.artifact_changes()
        self.assertEqual(changes['files'][0]['change'],'unchanged')
        self.assertNotIn('private prompt body',str(records)); self.assertNotIn('input.txt',str(records))
        self.assertTrue(any(args[1]=='operation.artifactBaseline' for args,_ in records))

    def test_acp_previous_execution_late_result_and_nonqueued_read_are_denied(self):
        task=self.task();task.execution_id='first'
        task.workspace=lambda *args,**kwargs: {}
        with self.assertRaises(sidecar.RuntimeFailure):task.artifact_read('export',expected=(task.binding_id,'old'))
        def changed(*args,**kwargs):task.execution_id='next';return {}
        task.workspace=changed
        with self.assertRaises(sidecar.RuntimeFailure):task.artifact_read('export')
        task.artifact_read_slot.acquire()
        try:
            with self.assertRaises(sidecar.RuntimeFailure):task.artifact_changes()
        finally:task.artifact_read_slot.release()

    def test_new_prompt_clears_previous_baseline_before_capturing(self):
        task=self.task();task.session='session';task.artifact_baseline={'files':[],'checkedAt':1}
        def capture(*args,**kwargs):
            self.assertIsNone(task.artifact_baseline,'previous execution evidence cannot label new execution')
            return {'files':[],'inventoryComplete':True,'hashComplete':True,'checkedAt':2,'rootIdentity':[1,2]}
        task.workspace=capture;task.rpc=lambda *args:{'stopReason':'end_turn'}
        task.prompt('next prompt')

if __name__=='__main__': unittest.main()
