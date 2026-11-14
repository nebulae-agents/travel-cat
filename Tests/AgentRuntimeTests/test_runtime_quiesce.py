import pathlib, sys, unittest, threading, time
from unittest.mock import Mock
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'Sources/TravelCatApp/Resources/AgentRuntime'))
import sidecar

class RuntimeQuiesceTests(unittest.TestCase):
    def test_quiesce_retains_failed_owned_cleanup_and_retries_while_sealed(self):
        controller = sidecar.Controller()
        replies = []; controller.emit = replies.append
        task = Mock(); task.stop.side_effect = [{'stopped': False}, {'stopped': True}]
        probe = Mock(); probe.stop.return_value = {'stopped': True}
        controller.tasks['task'] = task; controller.probes['probe'] = probe
        controller.handle({'id':'first','method':'runtime_quiesce','params':{}})
        self.assertFalse(replies[-1]['result']['stopped'])
        self.assertIn('task', controller.tasks)
        self.assertNotIn('probe', controller.probes)
        controller.handle({'id':'blocked','method':'native_connect','params':{}})
        self.assertIn('error', replies[-1])
        controller.handle({'id':'retry','method':'runtime_quiesce','params':{}})
        self.assertTrue(replies[-1]['result']['stopped'])
        self.assertEqual(task.stop.call_count, 2)

    def test_native_quiesce_retry_does_not_unseal_execution(self):
        native = sidecar.codex_native.CodexNativeController(lambda _: None)
        native.instances['x'] = {'pendingStart': True}
        with self.assertRaises(sidecar.codex_native.NativeFailure): native.handle('native_quiesce', {})
        native.instances.clear()
        self.assertEqual(native.handle('native_quiesce', {}), {'stopped': True})
        with self.assertRaises(sidecar.codex_native.NativeFailure): native.handle('native_connect', {})

    def test_stop_waits_for_admitted_start_before_confirming_cleanup(self):
        task = sidecar.Task.__new__(sidecar.Task)
        task.lifecycle_lock = threading.RLock(); task.lock = threading.RLock()
        task.admission_lock = threading.Lock(); task.stopped = threading.Event()
        task.permissions = {}; task.pending = {}; task.created = False
        task.process = None; task.relay = None
        entered = threading.Event(); release = threading.Event(); result = []
        def start():
            entered.set(); release.wait(2); task.created = True
        def cleanup(): task.created = False
        task._start = start; task.cleanup = cleanup
        starter = threading.Thread(target=task.start); starter.start()
        self.assertTrue(entered.wait(1))
        stopper = threading.Thread(target=lambda: result.append(task.stop())); stopper.start()
        self.assertTrue(task.stopped.wait(1))
        self.assertEqual(result, [])
        release.set(); starter.join(2); stopper.join(2)
        self.assertEqual(result, [{'stopped': True}]); self.assertFalse(task.created)

    def test_native_quiesce_stops_idle_background_and_pending_login(self):
        native = sidecar.codex_native.CodexNativeController(lambda _: None)
        native.tasks['task'] = {'taskId':'task','instanceId':'instance','threadId':'thread'}
        native.instances['instance'] = {'config':{}, 'loginId':'login'}
        native._list_background = Mock(return_value=[{'id':'background'}])
        native._stop_background = Mock(return_value={'stopped':True})
        native._login_cancel = Mock(side_effect=lambda params: native.instances['instance'].update(loginId=None))
        from unittest.mock import patch
        with patch.object(sidecar.codex_native._transport_module, 'stop_managed_daemon'):
            self.assertEqual(native.handle('native_quiesce', {}), {'stopped': True})
        native._stop_background.assert_called_once()
        native._login_cancel.assert_called_once_with({'instanceId':'instance','loginId':'login'})

    def test_native_partial_daemon_stop_receipts_survive_retry(self):
        native = sidecar.codex_native.CodexNativeController(lambda _: None)
        native.tasks['task'] = {'taskId':'task','instanceId':'first','threadId':'thread'}
        native.instances = {'first': {'config': {'name':'first'}}, 'second': {'config': {'name':'second'}}}
        native._stop_background = Mock(return_value={'stopped':True})
        from unittest.mock import patch
        with patch.object(sidecar.codex_native._transport_module, 'stop_managed_daemon', side_effect=[None, RuntimeError('temporary'), None]) as stop:
            with self.assertRaises(RuntimeError): native.handle('native_quiesce', {})
            self.assertEqual(native.handle('native_quiesce', {}), {'stopped':True})
            self.assertEqual([call.args[0]['name'] for call in stop.call_args_list], ['first','second','second'])
        native._stop_background.assert_called_once()

    def test_live_exec_child_prevents_positive_stop_receipt(self):
        task = sidecar.Task.__new__(sidecar.Task)
        task.lifecycle_lock = threading.RLock(); task.lock = threading.RLock()
        task.admission_lock = threading.Lock(); task.stopped = threading.Event()
        task.permissions = {}; task.pending = {}; task.created = False
        task.process = None; task.relay = None
        task.process = Mock(); task.process.poll.return_value = None; task.relay = None
        task.cleanup = Mock()
        self.assertFalse(task.stop()['stopped'])
