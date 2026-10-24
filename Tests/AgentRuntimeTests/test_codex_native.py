"""Native protocol tests never contact a model or use the user's Codex profile."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest.mock import patch

RUNTIME = Path(__file__).resolve().parents[2] / 'Sources/TravelCatApp/Resources/AgentRuntime'
spec = importlib.util.spec_from_file_location('codex_native', RUNTIME / 'codex_native.py')
native = importlib.util.module_from_spec(spec)
if spec.loader and (RUNTIME / 'codex_native.py').exists():
    spec.loader.exec_module(native)


class FakeTransport:
    def __init__(self, config, callback):
        self.config, self.callback = config, callback
        self.calls, self.answers = [], []
        self.deadlines = []
        self.closed = False
        self.results = {}
    def request(self, method, params, *, deadline=None):
        self.calls.append((method, params))
        self.deadlines.append(deadline)
        if method in self.results:
            result = self.results[method]
            return result(params) if callable(result) else result
        if method == 'initialize':
            return {'userAgent': 'codex/0.158.0', 'codexHome': self.config['profileRoot']}
        if method == 'account/read':
            return {'account': {'type': 'chatgpt', 'email': 'private@example.test', 'planType': 'plus'}}
        if method == 'model/list':
            return {'data': [{'id': 'test', 'model': 'test', 'displayName': 'Test', 'isDefault': True}], 'nextCursor': None}
        if method in ('thread/start', 'thread/resume'):
            return {'thread': {'id': params.get('threadId', 'thread-1'), 'sessionId': 'session-1', 'status': {'type': 'idle'}, 'turns': []}, 'activePermissionProfile': {'id': 'travelcat-native'}, 'approvalPolicy': 'untrusted', 'approvalsReviewer': 'user', 'cwd': self.config['workspace'], 'runtimeWorkspaceRoots': [self.config['workspace']], 'sandbox': {'type': 'workspaceWrite', 'networkAccess': False, 'writableRoots': [], 'excludeTmpdirEnvVar': True, 'excludeSlashTmp': True}}
        if method == 'turn/start':
            self.event('turn/started', {'threadId': params['threadId'], 'turn': {'id': 'turn-1', 'status': 'inProgress'}})
            return {'turn': {'id': 'turn-1', 'status': 'inProgress'}}
        if method == 'turn/interrupt':
            self.event('turn/completed', {'threadId': params['threadId'], 'turn': {'id': params['turnId'], 'status': 'interrupted'}})
            return {}
        if method == 'thread/backgroundTerminals/terminate': return {'terminated': True}
        if method in ('thread/turns/list', 'thread/items/list', 'thread/backgroundTerminals/list'): return {'data': [], 'nextCursor': None}
        if method == 'account/login/start': return {'type': 'chatgpt', 'loginId': 'login-1', 'authUrl': 'https://auth.openai.com/oauth/authorize?state=example'}
        return {}
    def notify(self, method, params): self.calls.append((method, params))
    def respond(self, request_id, result=None, error=None): self.answers.append({'id': request_id, 'result': result, 'error': error})
    def event(self, method, params): self.callback({'method': method, 'params': params})
    def approval(self, **overrides):
        params = {'threadId': 'thread-1', 'turnId': 'turn-1', 'itemId': 'item-1', 'command': 'echo safe', 'cwd': self.config['workspace'], 'startedAtMs': 1, 'availableDecisions': ['accept', 'acceptForSession', 'decline', 'cancel']}
        params.update(overrides)
        self.callback({'id': 99, 'method': 'item/commandExecution/requestApproval', 'params': params})
    def close(self): self.closed = True


class NativeControllerTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(hasattr(native, 'CodexNativeController'), 'native controller is not implemented')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.workspace = self.root / 'workspace'; self.workspace.mkdir()
        self.instance = str(uuid.uuid4())
        self.events = []
        self.controller = native.CodexNativeController(self.events.append)
        self.addCleanup(self.controller.close)
        self.factory = patch.object(native, 'NativeTransport', FakeTransport)
        self.factory.start(); self.addCleanup(self.factory.stop)
        self.params = {'instanceId': self.instance, 'executable': sys.executable, 'workspace': str(self.workspace), 'profileRoot': str(self.root / 'profiles' / self.instance)}
        self.connected = self.controller.handle('native_connect', self.params)
        self.transport = self.controller.instances[self.instance]['transport']
    def start(self):
        return self.controller.handle('native_start', {'instanceId': self.instance, 'taskId': 'task-1', 'model': 'test'})
    def prompt(self):
        self.start()
        return self.controller.handle('native_prompt', {'taskId': 'task-1', 'text': 'hello', 'clientUserMessageId': 'message-1'})
    def permission(self, **overrides):
        p = self.events[-1]['data']['params']
        args = {'taskId': 'task-1', 'requestId': p['requestId'], 'requestHash': p['requestHash'], 'optionId': 'accept'}
        args.update(overrides)
        return self.controller.handle('native_permission', args)
    def test_account_sanitized_and_model_catalog_returned(self):
        self.assertEqual(self.connected['account'], {'authenticated': True, 'authMode': 'chatgpt', 'planType': 'plus'})
        self.assertNotIn('email', json.dumps(self.connected))
        self.assertEqual(self.connected['models'][0]['model'], 'test')
    def test_start_has_restricted_named_profile_and_does_not_prompt(self):
        self.assertEqual(self.start(), {'threadId': 'thread-1', 'sessionId': 'session-1'})
        method, p = self.transport.calls[-1]
        self.assertEqual(method, 'thread/start'); self.assertEqual(p['permissions'], 'travelcat-native')
        self.assertEqual(p['approvalPolicy'], 'untrusted'); self.assertEqual(p['approvalsReviewer'], 'user')
        self.assertFalse(any(m == 'turn/start' for m, _ in self.transport.calls))
    def test_completed_turn_does_not_revive_from_late_started_or_accept_old_approval(self):
        self.prompt()
        self.transport.event('turn/completed',{'threadId':'thread-1','turn':{'id':'turn-1','status':'completed'}})
        self.transport.event('turn/started',{'threadId':'thread-1','turn':{'id':'turn-1','status':'inProgress'}})
        task=self.controller.tasks['task-1']
        self.assertIsNone(task['turnId'],'an observed terminal turn cannot become active again')
        self.assertEqual(task['status'],{'type':'idle'})
        self.transport.approval()
        self.assertEqual(self.transport.answers[-1]['result'],{'decision':'cancel'})
        self.assertEqual(self.events[-1]['data']['method'],'turn/started','raw stale notifications remain observable')
        self.transport.event('turn/started',{'threadId':'thread-1','turn':{'id':'new-turn','status':'inProgress'}})
        self.assertEqual(task['turnId'],'new-turn')
        self.transport.approval()
        self.assertEqual(self.transport.answers[-1]['result'],{'decision':'cancel'})

    def test_confirmed_terminal_guard_is_bounded_and_uses_official_resume_evidence(self):
        self.start()
        self.transport.results['thread/turns/list']={'data':[{'id':'old-turn','status':'completed'}],'nextCursor':None}
        self.controller.handle('native_resume',{'instanceId':self.instance,'taskId':'task-1','threadId':'thread-1'})
        task=self.controller.tasks['task-1']
        self.transport.event('turn/started',{'threadId':'thread-1','turn':{'id':'old-turn','status':'inProgress'}})
        self.assertIsNone(task['turnId'])
        with patch.object(native,'MAX_HISTORY',2):
            for n in range(4): self.transport.event('turn/completed',{'threadId':'thread-1','turn':{'id':'turn-'+str(n),'status':'completed'}})
        self.assertLessEqual(len(task['terminalTurns']),2)
        self.transport.event('turn/started',{'threadId':'thread-1','turn':{'id':'turn-3','status':'inProgress'}})
        self.assertIsNone(task['turnId'])

    def test_invalid_turn_completion_never_creates_terminal_control_evidence(self):
        self.prompt()
        self.transport.event('turn/completed',{'threadId':'thread-1','turn':{'id':'turn-1','status':'bogus'}})
        self.assertEqual(self.controller.tasks['task-1']['turnId'],'turn-1')
        self.transport.event('turn/started',{'threadId':'thread-1','turn':{'id':'turn-1','status':'inProgress'}})
        self.assertEqual(self.controller.tasks['task-1']['turnId'],'turn-1')

    def test_wrong_active_profile_blocks_prompt(self):
        self.transport.results['thread/start'] = {'thread': {'id': 'thread-1'}, 'activePermissionProfile': {'id': ':danger-full-access'}}
        with self.assertRaises(native.NativeFailure): self.start()
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_prompt', {'taskId': 'task-1', 'text': 'hello', 'clientUserMessageId': 'm'})
    def test_prompt_and_event_identity(self):
        self.assertEqual(self.prompt(), {'turnId': 'turn-1'})
        self.assertEqual(self.events[-1]['taskId'], 'task-1')
        self.assertEqual(self.events[-1]['data']['method'], 'turn/started')
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_prompt', {'taskId': 'task-1', 'text': 'again', 'clientUserMessageId': 'message-2'})
    def test_cancel_waits_for_official_completion_and_empty_background_readback(self):
        self.prompt()
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'stale'})
        result = self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'turn-1'})
        self.assertEqual(result, {'requested': True, 'backgroundStopped': True, 'terminatedCount': 0, 'turnStatus': 'interrupted'})
        calls = [m for m, _ in self.transport.calls]
        self.assertLess(calls.index('turn/interrupt'), calls.index('thread/backgroundTerminals/list'))
        self.assertEqual(calls[-2:], ['thread/backgroundTerminals/list', 'thread/backgroundTerminals/list'])
        self.assertTrue(any(e['data']['method'] == 'turn/completed' for e in self.events))

    def test_reconciled_terminal_proof_rejects_late_approval_but_new_turn_is_approvable(self):
        self.prompt()
        self.transport.results['thread/turns/list']={'data':[{'id':'turn-1','status':'completed'}],'nextCursor':None}
        self.reconcile()
        self.assertEqual(self.controller.tasks['task-1']['turnId'],'turn-1','query preserves raw current-turn binding')
        self.transport.approval()
        self.assertFalse(self.controller.approvals,'a terminal-proven turn cannot offer new approval authority')
        self.assertFalse(any(event['data']['method']=='permission' for event in self.events))
        self.assertNotIn({'decision':'accept'},[answer['result'] for answer in self.transport.answers])
        self.transport.event('turn/started',{'threadId':'thread-1','turn':{'id':'next-turn','status':'inProgress'}})
        self.transport.approval(turnId='next-turn',itemId='new-item')
        self.assertEqual(self.permission(),{'sent':True})
        self.assertEqual(self.transport.answers[-1]['result'],{'decision':'accept'})

    def test_reconciled_terminal_proof_blocks_saved_decisions_without_query_side_effects(self):
        self.prompt(); self.transport.approval()
        request=self.events[-1]['data']['params'].copy()
        pending={key:dict(value) for key,value in self.controller.approvals.items()}
        task=self.controller.tasks['task-1']
        original_turn,original_status=task['turnId'],dict(task['status'])
        self.transport.results['thread/turns/list']={'data':[{'id':'turn-1','status':'completed'}],'nextCursor':None}
        self.reconcile()
        self.assertEqual(self.controller.approvals,pending,'query leaves original approvals untouched')
        self.assertEqual(self.transport.answers,[],'query never responds to a server approval')
        self.assertEqual(task['turnId'],original_turn)
        self.assertEqual(task['status'],original_status)
        for decision in ('accept','decline','cancel'):
            with self.subTest(decision=decision),self.assertRaises(native.NativeFailure):
                self.controller.handle('native_permission',{'taskId':'task-1','requestId':request['requestId'],'requestHash':request['requestHash'],'optionId':decision})
        self.assertEqual(self.controller.approvals,pending,'rejected stale decisions do not erase the preserved record')
        self.assertEqual(self.transport.answers,[],'no decision is sent after terminal proof')

    def test_approval_hash_task_scope_and_single_use(self):
        self.prompt(); self.transport.approval()
        self.assertEqual([o['id'] for o in self.events[-1]['data']['params']['options']], ['accept', 'decline', 'cancel'])
        with self.assertRaises(native.NativeFailure): self.permission(requestHash='wrong')
        with self.assertRaises(native.NativeFailure): self.permission(taskId='other-task')
        self.assertEqual(self.permission(), {'sent': True})
        self.assertEqual(self.transport.answers[-1]['result'], {'decision': 'accept'})
        with self.assertRaises(native.NativeFailure): self.permission()
    def test_current_cli_local_environment_approval_is_single_use(self):
        self.prompt()
        self.transport.approval(environmentId='local', additionalPermissions=None,
            availableDecisions=['accept', {'acceptWithExecpolicyAmendment': {'execpolicy_amendment': ['/bin/zsh', '-lc', 'printf probe > file']}}, 'cancel'])
        requests = [event for event in self.events if event['data']['method'] == 'permission']
        self.assertEqual(len(requests), 1)
        self.assertEqual([option['id'] for option in requests[0]['data']['params']['options']], ['accept', 'cancel'])
        self.assertEqual(self.permission(), {'sent': True})
        self.assertEqual(self.transport.answers[-1]['result'], {'decision': 'accept'})

    def test_nonlocal_execution_environment_stays_rejected(self):
        self.prompt()
        self.transport.approval(environmentId='remote-environment')
        self.assertFalse(any(event['data']['method'] == 'permission' for event in self.events))
        self.assertEqual(self.transport.answers[-1]['result'], {'decision': 'cancel'})

    def test_expired_approval_denied(self):
        self.prompt(); self.transport.approval()
        with patch.object(native.time, 'time', return_value=10**12):
            with self.assertRaises(native.NativeFailure): self.permission()
        self.assertNotIn({'decision': 'accept'}, [x['result'] for x in self.transport.answers])
    def test_approval_invalidated_by_turn_completion(self):
        self.prompt(); self.transport.approval(); args = self.events[-1]['data']['params'].copy()
        self.transport.event('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'completed'}})
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_permission', {'taskId': 'task-1', 'requestId': args['requestId'], 'requestHash': args['requestHash'], 'optionId': 'accept'})
    def test_permission_escalation_and_unknown_requests_fail_closed(self):
        self.prompt()
        for extra in ({'additionalPermissions': {'network': {'enabled': True}}}, {'networkApprovalContext': {'host': 'x'}}, {'cwd': '/'}):
            self.transport.approval(**extra)
            self.assertNotEqual(self.transport.answers[-1]['result'], {'decision': 'accept'})
        self.transport.callback({'id': 100, 'method': 'item/permissions/requestApproval', 'params': {}})
        self.assertEqual(self.transport.answers[-1]['id'], 100)
        self.assertIsNotNone(self.transport.answers[-1]['error'])
    def test_file_grant_root_rejected(self):
        self.prompt(); self.transport.callback({'id': 101, 'method': 'item/fileChange/requestApproval', 'params': {'threadId': 'thread-1', 'turnId': 'turn-1', 'itemId': 'file-1', 'grantRoot': '/'}})
        self.assertNotEqual(self.transport.answers[-1]['result'], {'decision': 'accept'})
    def test_detach_does_not_kill_daemon_or_report_stopped(self):
        self.prompt()
        self.assertEqual(self.controller.handle('native_detach', {'taskId': 'task-1'}), {'detached': True})
        self.assertFalse(self.transport.closed)
        self.transport.event('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'completed'}})
        self.assertFalse(self.events[-1]['data']['method'] == 'turn/completed')
    def test_resume_paginates_without_replaying_prompt(self):
        pages = iter([{'data': [{'id': 'old', 'status': 'completed'}], 'nextCursor': 'page2'}, {'data': [{'id': 'live', 'status': 'inProgress'}], 'nextCursor': None}])
        self.transport.results['thread/turns/list'] = lambda _: next(pages)
        self.transport.results['thread/items/list'] = {'data': [{'turnId': 'old', 'item': {'id': 'item', 'type': 'agentMessage', 'text': 'done'}}], 'nextCursor': None}
        result = self.controller.handle('native_resume', {'instanceId': self.instance, 'taskId': 'recovered', 'threadId': 'thread-1'})
        self.assertEqual(result['turnId'], 'live'); self.assertEqual(len(result['turns']), 2); self.assertEqual(len(result['items']), 1)
        self.assertFalse(any(m == 'turn/start' for m, _ in self.transport.calls))
    def test_resume_repeated_cursor_fails_explicitly(self):
        self.transport.results['thread/turns/list'] = {'data': [], 'nextCursor': 'same'}
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_resume', {'instanceId': self.instance, 'taskId': 'recovered', 'threadId': 'thread-1'})
    def test_login_url_validation_and_cancellation(self):
        result = self.controller.handle('native_login', {'instanceId': self.instance})
        self.assertEqual(result['loginId'], 'login-1')
        self.controller.handle('native_login_cancel', {'instanceId': self.instance, 'loginId': 'login-1'})
        self.assertEqual(self.transport.calls[-1][0], 'account/login/cancel')
        self.transport.results['account/login/start'] = {'type': 'chatgpt', 'loginId': 'bad', 'authUrl': 'https://auth.openai.com.attacker.test/'}
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_login', {'instanceId': self.instance})
    def test_profile_cannot_overlap_workspace_or_default_codex_home(self):
        for p in (str(self.workspace / self.instance), str(Path.home() / '.codex' / self.instance)):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_connect', {**self.params, 'profileRoot': p})
    def test_executable_symlink_preserves_node_launcher_directory(self):
        target = self.root / 'lib' / 'codex.js'; target.parent.mkdir(); target.write_text('#!/usr/bin/env node\n'); target.chmod(0o700)
        launcher = self.root / 'bin' / 'codex'; launcher.parent.mkdir(); launcher.symlink_to(target)
        config = native._configuration({**self.params, 'executable': str(launcher)})
        env = native._transport_module._environment(config)
        self.assertEqual(env['PATH'].split(':')[0], str(launcher.parent))

    def test_reconnect_rebinds_same_task_without_replaying_prompt(self):
        self.prompt(); self.transport.event('connection/lost', {})
        self.controller.handle('native_connect', self.params)
        new = self.controller.instances[self.instance]['transport']
        result = self.controller.handle('native_resume', {'instanceId': self.instance, 'taskId': 'task-1', 'threadId': 'thread-1'})
        self.assertEqual(result['threadId'], 'thread-1')
        self.assertFalse(any(m == 'turn/start' for m, _ in new.calls))
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_resume', {'instanceId': self.instance, 'taskId': 'task-1', 'threadId': 'different-thread'})
    def test_resume_reconciles_completion_after_history_snapshot(self):
        self.transport.results['thread/turns/list'] = {'data': [{'id': 'live', 'status': 'inProgress'}], 'nextCursor': None}
        def finish(_):
            self.transport.event('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'live', 'status': 'completed'}})
            return {'data': [], 'nextCursor': None}
        self.transport.results['thread/items/list'] = finish
        result = self.controller.handle('native_resume', {'instanceId': self.instance, 'taskId': 'task-1', 'threadId': 'thread-1'})
        self.assertIsNone(result['turnId'])
        self.assertEqual(result['turns'][0]['status'], 'completed')
    def test_detach_close_and_connection_loss_do_not_send_user_cancellation(self):
        self.prompt(); self.transport.approval()
        self.controller.handle('native_detach', {'taskId': 'task-1'})
        self.assertEqual(self.transport.answers, [])
        self.controller.handle('native_resume', {'instanceId': self.instance, 'taskId': 'task-1', 'threadId': 'thread-1'})
        self.transport.event('turn/started', {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'inProgress'}})
        self.transport.approval(); self.transport.event('connection/lost', {})
        self.assertEqual(self.transport.answers, [])
    def test_item_completion_invalidates_approval_in_ui(self):
        self.prompt(); self.transport.approval()
        request_id = self.events[-1]['data']['params']['requestId']
        self.transport.event('item/completed', {'threadId': 'thread-1', 'turnId': 'turn-1', 'item': {'id': 'item-1'}})
        invalidated = [e for e in self.events if e['data']['method'] == 'permission/invalidated']
        self.assertEqual(invalidated[-1]['data']['params']['requestId'], request_id)

    def test_connect_refreshes_account_without_replacing_active_transport(self):
        self.start()
        self.transport.results['account/read'] = {'account': None}
        fresh = self.controller.handle('native_connect', self.params)
        self.assertFalse(fresh['account']['authenticated'])
        self.assertIs(self.controller.instances[self.instance]['transport'], self.transport)
        self.assertEqual(sum(m == 'initialize' for m, _ in self.transport.calls), 1)

    def test_resume_buffers_pending_approval_until_scope_is_verified(self):
        self.transport.results['thread/turns/list'] = {'data': [{'id': 'turn-1', 'status': 'inProgress'}], 'nextCursor': None}
        def pending(_):
            self.transport.approval()
            return {'data': [], 'nextCursor': None}
        self.transport.results['thread/items/list'] = pending
        self.controller.handle('native_resume', {'instanceId': self.instance, 'taskId': 'task-1', 'threadId': 'thread-1'})
        self.assertEqual(self.events[-1]['data']['method'], 'permission')
        self.assertEqual(self.transport.answers, [])
        self.permission()
        self.assertEqual(self.transport.answers[-1]['result'], {'decision': 'accept'})
    def test_duplicate_server_approval_has_only_one_local_authority(self):
        self.prompt(); self.transport.approval(); self.transport.approval()
        self.assertEqual(len(self.controller.approvals), 1)
    def test_malformed_available_decisions_cannot_grant_accept(self):
        self.prompt(); self.transport.approval(availableDecisions='acceptForSession')
        self.assertFalse(self.controller.approvals)
        self.assertIsNotNone(self.transport.answers[-1]['error'])
    def test_profile_symlink_is_rejected(self):
        real = self.root / 'other' / self.instance; real.mkdir(parents=True, mode=0o700)
        alias = self.root / 'alias' / self.instance; alias.parent.mkdir(); alias.symlink_to(real)
        with self.assertRaises(native.NativeFailure): native._configuration({**self.params, 'profileRoot': str(alias)})

    def test_incomplete_or_widened_effective_sandbox_is_rejected(self):
        original = self.transport.request('thread/start', {})
        for patch_value in ({'type': 'unknown'}, {'excludeSlashTmp': False}, {'excludeTmpdirEnvVar': False}, {'writableRoots': ['/']}):
            self.transport.results['thread/start'] = {**original, 'sandbox': {**original['sandbox'], **patch_value}}
            with self.assertRaises(native.NativeFailure): self.start()

    def background_process(self, process_id='process-1', **extra):
        return {'processId': process_id, 'itemId': 'command-' + process_id, 'cwd': str(self.workspace), 'command': 'sleep 30', 'osPid': 1, **extra}

    def test_background_status_reads_completed_turn_without_mutating_or_terminating(self):
        self.prompt()
        self.transport.event('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'completed'}})
        task = self.controller.tasks['task-1']
        before = dict(task)
        self.transport.results['thread/backgroundTerminals/list'] = {'data': [self.background_process()], 'nextCursor': None}
        calls = len(self.transport.calls)
        result = self.controller.handle('native_background_status', {'taskId': 'task-1'})
        self.assertEqual(result, {'threadId': 'thread-1', 'count': 1, 'itemIds': ['command-process-1']})
        self.assertEqual(task, before)
        self.assertEqual([m for m, _ in self.transport.calls[calls:]], ['thread/backgroundTerminals/list'])

    def test_background_status_accepts_only_bound_task_identifier(self):
        self.start()
        calls = len(self.transport.calls)
        for params in ({'taskId': 'foreign'}, {'taskId': 'task-1', 'threadId': 'thread-1'}, {'taskId': 'task-1', 'instanceId': self.instance}, {'taskId': 'task-1', 'processId': 'p'}):
            with self.subTest(params=params), self.assertRaises(native.NativeFailure):
                self.controller.handle('native_background_status', params)
        self.controller.handle('native_detach', {'taskId': 'task-1'})
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_status', {'taskId': 'task-1'})
        self.assertEqual(len(self.transport.calls), calls)

    def test_background_status_paginates_and_returns_authoritative_empty(self):
        self.start()
        pages = iter([{'data': [self.background_process('p1')], 'nextCursor': 'next'}, {'data': [self.background_process('p2')], 'nextCursor': None}])
        self.transport.results['thread/backgroundTerminals/list'] = lambda _: next(pages)
        self.assertEqual(self.controller.handle('native_background_status', {'taskId': 'task-1'})['itemIds'], ['command-p1', 'command-p2'])
        self.transport.results['thread/backgroundTerminals/list'] = {'data': [], 'nextCursor': None}
        self.assertEqual(self.controller.handle('native_background_status', {'taskId': 'task-1'}), {'threadId': 'thread-1', 'count': 0, 'itemIds': []})
        self.assertFalse(any(m == 'thread/backgroundTerminals/terminate' for m, _ in self.transport.calls))

    def test_background_status_rejects_stale_binding_during_every_page(self):
        self.start()
        original_task = self.controller.tasks['task-1']
        instance = self.controller.instances[self.instance]
        for mutation in ('disconnect', 'generation', 'replacement', 'thread', 'instance'):
            for page_number in (1, 2):
                with self.subTest(mutation=mutation, page=page_number):
                    self.controller.tasks['task-1'] = original_task
                    original_task['threadId'] = 'thread-1'
                    instance['connected'] = True
                    instance['generation'] = original_task['generation']
                    self.controller.instances[self.instance] = instance
                    calls = []
                    def listed(_):
                        calls.append(1)
                        if len(calls) == page_number:
                            if mutation == 'disconnect': instance['connected'] = False
                            elif mutation == 'generation': instance['generation'] = 'new-generation'
                            elif mutation == 'replacement': self.controller.tasks['task-1'] = dict(original_task)
                            elif mutation == 'thread': original_task['threadId'] = 'changed'
                            elif mutation == 'instance': self.controller.instances[self.instance] = dict(instance)
                        return {'data': [], 'nextCursor': 'second' if len(calls) == 1 else None}
                    self.transport.results['thread/backgroundTerminals/list'] = listed
                    with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_status', {'taskId': 'task-1'})
                    self.assertEqual(len(calls), page_number)
        self.controller.tasks['task-1'] = original_task
        self.controller.instances[self.instance] = instance

    def test_background_status_preserves_list_limits_and_identity_validation(self):
        self.start()
        for page in ({'data': []}, {'data': [self.background_process(threadId='foreign')], 'nextCursor': None}, {'data': [self.background_process(), self.background_process()], 'nextCursor': None}, {'data': [], 'nextCursor': 'same'}):
            self.transport.results['thread/backgroundTerminals/list'] = page
            with self.subTest(page=page), self.assertRaises(native.NativeFailure): self.controller.handle('native_background_status', {'taskId': 'task-1'})
        self.transport.results['thread/backgroundTerminals/list'] = {'data': [self.background_process()], 'nextCursor': None}
        with patch.object(native, 'MAX_BACKGROUND_PROCESSES', 0):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_status', {'taskId': 'task-1'})
        self.assertFalse(any(m == 'thread/backgroundTerminals/terminate' for m, _ in self.transport.calls))

    def reconcile(self, params=None):
        try:
            return self.controller.handle('native_reconcile', params or {'taskId': 'task-1'})
        except native.NativeFailure as error:
            self.fail('scoped reconciliation must succeed: ' + str(error))

    def test_reconcile_reads_official_history_without_resume_or_control_mutation(self):
        self.start()
        turns = [{'id':'turn-1','status':'completed'}]
        items = [{'turnId':'turn-1','item':{'id':'command','type':'commandExecution','status':'completed'}}]
        self.transport.results['thread/turns/list'] = {'data':turns,'nextCursor':None}
        self.transport.results['thread/items/list'] = {'data':items,'nextCursor':None}
        task = {key:value for key,value in self.controller.tasks['task-1'].items() if key!='terminalTurns'}
        before = len(self.transport.calls)
        deadline_before = len(self.transport.deadlines)
        result = self.reconcile()
        self.assertEqual(result,{'threadId':'thread-1','turns':turns,'items':items})
        self.assertEqual({key:value for key,value in self.controller.tasks['task-1'].items() if key!='terminalTurns'},task)
        self.assertEqual([m for m,_ in self.transport.calls[before:]],['thread/turns/list','thread/items/list'])
        self.assertEqual(len(set(self.transport.deadlines[deadline_before:])),1)
        self.assertIsNotNone(self.transport.deadlines[-1])

    def test_reconcile_rejects_caller_authority_and_stale_binding_each_page(self):
        self.start()
        for params in ({'taskId':'task-1','threadId':'foreign'},{'taskId':'missing'},{'taskId':'task-1','instanceId':self.instance}):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',params)
        for phase in ('turns','items'):
            def change(_):
                self.controller.tasks['task-1'] = dict(self.controller.tasks['task-1'])
                return {'data':[],'nextCursor':None}
            method = 'thread/turns/list' if phase == 'turns' else 'thread/items/list'
            self.transport.results[method] = change
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',{'taskId':'task-1'})
            self.transport.results.pop(method)

    def test_reconcile_shares_deadline_across_turns_and_items_and_all_pages(self):
        self.start()
        clock = [100.0]
        def slow(_):
            clock[0] += 3.0
            return {'data':[],'nextCursor':None}
        self.transport.results['thread/turns/list'] = slow
        self.transport.results['thread/items/list'] = slow
        before = len(self.transport.deadlines)
        with patch.object(native.time,'monotonic',side_effect=lambda:clock[0]):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',{'taskId':'task-1'})
        self.assertEqual(self.transport.deadlines[before:],[105.0,105.0])
        self.assertTrue(self.controller.instances[self.instance]['connected'])

    def test_reconcile_never_queues_behind_controls_or_background_reads(self):
        self.start()
        for lock in (self.controller.operations,self.controller.background_status_slot):
            lock.acquire()
            errors=[]
            def read():
                try: self.controller.handle('native_reconcile',{'taskId':'task-1'})
                except native.NativeFailure as error: errors.append(error)
            worker=threading.Thread(target=read,daemon=True)
            try:
                worker.start(); worker.join(0.2)
                self.assertFalse(worker.is_alive())
            finally:
                lock.release(); worker.join(1)
            self.assertEqual(len(errors),1)
        self.assertFalse(any(m in ('thread/turns/list','thread/items/list') for m,_ in self.transport.calls))

    def test_reconcile_checks_scope_and_deadline_after_every_page(self):
        self.start()
        original=self.controller.tasks['task-1']
        for mutation in ('task','generation','thread','turn','disconnect'):
            instance=self.controller.instances[self.instance]
            generation=instance['generation']
            self.controller.tasks['task-1']=original
            original.update(threadId='thread-1',turnId=None,generation=generation)
            instance['connected']=True
            pages=[]
            def page(_):
                pages.append(self.transport.deadlines[-1])
                if len(pages)==2:
                    if mutation=='task': self.controller.tasks['task-1']=dict(original)
                    elif mutation=='generation': instance['generation']='other'
                    elif mutation=='thread': original['threadId']='other'
                    elif mutation=='turn': original['turnId']='new-turn'
                    else: instance['connected']=False
                return {'data':[],'nextCursor':'second' if len(pages)==1 else None}
            self.transport.results['thread/turns/list']=page
            with self.subTest(mutation=mutation),self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',{'taskId':'task-1'})
            self.assertEqual(len(pages),2)
            self.assertEqual(len(set(pages)),1)
            instance.update(generation=generation,connected=True)
        self.controller.tasks['task-1']=original

    def test_reconcile_scope_lock_wait_uses_total_read_deadline(self):
        self.start()
        for phase in ('initial','after-page'):
            entered,release=threading.Event(),threading.Event()
            errors=[]
            def page(_):
                entered.set(); release.wait(0.5)
                return {'data':[],'nextCursor':None}
            self.transport.results['thread/turns/list']=page
            def read():
                try: self.controller.handle('native_reconcile',{'taskId':'task-1'})
                except native.NativeFailure as error: errors.append(error)
            worker=threading.Thread(target=read,daemon=True)
            with self.subTest(phase=phase),patch.object(native,'BACKGROUND_STATUS_SECONDS',0.04):
                if phase=='initial': self.controller.lock.acquire()
                worker.start()
                if phase=='after-page':
                    self.assertTrue(entered.wait(0.3)); self.controller.lock.acquire()
                try:
                    release.set(); worker.join(0.2)
                    self.assertFalse(worker.is_alive())
                finally:
                    self.controller.lock.release(); worker.join(1)
                self.assertEqual(len(errors),1)

    def test_reconcile_terminal_evidence_prevents_old_started_without_changing_controls(self):
        self.start()
        self.transport.results['thread/turns/list']={'data':[{'id':'old-turn','status':'completed'},{'id':'bad','status':'bogus'}],'nextCursor':None}
        task=self.controller.tasks['task-1']
        task['turnId']='current-turn'
        original={key:value for key,value in task.items() if key!='terminalTurns'}
        before=len(self.transport.calls)
        self.reconcile()
        self.assertEqual({key:value for key,value in task.items() if key!='terminalTurns'},original)
        self.assertEqual([method for method,_ in self.transport.calls[before:]],['thread/turns/list','thread/items/list'])
        self.transport.event('turn/started',{'threadId':'thread-1','turn':{'id':'old-turn','status':'inProgress'}})
        self.assertEqual(task['turnId'],'current-turn','scoped official terminal proof must prevent resurrection')
        self.assertNotIn('bad',task['terminalTurns'])
        self.assertEqual(self.events[-1]['data']['method'],'turn/started')

    def test_reconcile_never_caches_partial_or_stale_terminal_proof_and_cache_stays_bounded(self):
        self.start()
        task=self.controller.tasks['task-1']
        self.transport.results['thread/turns/list']={'data':[{'id':'old','status':'completed'}],'nextCursor':None}
        def failed(_): raise native.NativeFailure('fixture missing items page')
        self.transport.results['thread/items/list']=failed
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',{'taskId':'task-1'})
        self.assertEqual(task['terminalTurns'],{})
        def stale(_):
            task['turnId']='different-turn'
            return {'data':[],'nextCursor':None}
        self.transport.results['thread/items/list']=stale
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',{'taskId':'task-1'})
        self.assertEqual(task['terminalTurns'],{})
        self.transport.results['thread/items/list']={'data':[],'nextCursor':None}
        with patch.object(native,'MAX_HISTORY',2):
            for n in range(4):
                self.transport.results['thread/turns/list']={'data':[{'id':'done-'+str(n),'status':'completed'}],'nextCursor':None}
                self.reconcile()
        self.assertEqual(set(task['terminalTurns']),{'done-2','done-3'})
        self.assertEqual(task['turnId'],'different-turn')

    def test_reconcile_accounts_for_full_page_bytes_and_cursor_size(self):
        self.start()
        self.transport.results['thread/turns/list']={'data':[],'nextCursor':'x'*5000}
        before=len(self.transport.calls)
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',{'taskId':'task-1'})
        self.assertEqual(len(self.transport.calls)-before,1,'reject oversized page metadata before another page')

    def test_reconcile_validates_pages_identity_count_and_cursor_before_publish(self):
        self.start()
        for page in ({'data':[]},{'data':[{'threadId':'foreign','id':'turn'}],'nextCursor':None},{'data':['bad'],'nextCursor':None},{'data':[],'nextCursor':'same'}):
            self.transport.results['thread/turns/list']=page
            with self.subTest(page=page),self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',{'taskId':'task-1'})
        self.transport.results['thread/turns/list']={'data':[{'id':'turn'}],'nextCursor':None}
        with patch.object(native,'MAX_HISTORY',0):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_reconcile',{'taskId':'task-1'})

    def test_background_status_all_pages_share_total_deadline_and_late_page_is_not_published(self):
        self.start()
        clock = [100.0]
        pages = []
        def slow_page(_):
            pages.append(self.transport.deadlines[-1])
            clock[0] += 3.0
            return {'data': [], 'nextCursor': 'page-' + str(len(pages)) if len(pages) < 3 else None}
        self.transport.results['thread/backgroundTerminals/list'] = slow_page
        with patch.object(native.time, 'monotonic', side_effect=lambda: clock[0]), patch.object(native, 'BACKGROUND_STATUS_SECONDS', 5, create=True):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_status', {'taskId': 'task-1'})
        self.assertEqual(pages,[105.0,105.0], 'all pages share one deadline; no third page after expiry')
        self.assertTrue(self.controller.instances[self.instance]['connected'])

    def test_background_status_busy_operation_never_waits_in_queue_or_sends_after_unlock(self):
        self.start()
        results = []
        def read():
            try: results.append(self.controller.handle('native_background_status', {'taskId': 'task-1'}))
            except native.NativeFailure as error: results.append(error)
        self.controller.operations.acquire()
        worker = threading.Thread(target=read,daemon=True)
        try:
            worker.start(); worker.join(0.2)
            finished_while_busy = not worker.is_alive()
        finally:
            self.controller.operations.release(); worker.join(1)
        self.assertTrue(finished_while_busy,'read-only polls must fail promptly rather than queue behind controls')
        self.assertTrue(results and isinstance(results[0],native.NativeFailure))
        self.assertFalse(any(m == 'thread/backgroundTerminals/list' for m, _ in self.transport.calls))

    def test_background_status_contention_does_not_accumulate_reads_ahead_of_stop(self):
        self.start()
        entered, release = threading.Event(), threading.Event()
        original = self.transport.request
        first = [True]
        def slow_request(method, params, *, deadline=None):
            if method == 'thread/backgroundTerminals/list' and first[0]:
                first[0] = False; entered.set()
                delay = max(0, deadline-time.monotonic()) if deadline is not None else 0.4
                if not release.wait(delay): raise native.NativeFailure('fixture read deadline')
            return original(method,params,deadline=deadline)
        self.transport.request = slow_request
        results, stopped = [], []
        def read():
            try: results.append(self.controller.handle('native_background_status', {'taskId': 'task-1'}))
            except native.NativeFailure as error: results.append(error)
        def stop():
            stopped.append(self.controller.handle('native_background_stop', {'taskId': 'task-1'}))
        with patch.object(native,'BACKGROUND_STATUS_SECONDS',0.08,create=True):
            active = threading.Thread(target=read,daemon=True); active.start()
            self.assertTrue(entered.wait(0.3))
            queued = [threading.Thread(target=read,daemon=True) for _ in range(8)]
            for worker in queued: worker.start()
            stopper = threading.Thread(target=stop,daemon=True); stopper.start()
            try:
                stopper.join(0.25)
                stopped_within_budget = not stopper.is_alive()
                polls_rejected = all(not worker.is_alive() for worker in queued)
            finally:
                release.set(); active.join(1); stopper.join(1)
                for worker in queued: worker.join(1)
        self.assertTrue(stopped_within_budget,'stop can wait only for the current bounded read')
        self.assertTrue(polls_rejected,'additional reads never accumulate behind the operation lock')
        self.assertEqual(stopped,[{'stopped':True,'terminatedCount':0}])
        self.assertEqual(len(results),9)
        self.assertTrue(all(isinstance(result,native.NativeFailure) for result in results))

    def test_background_status_scope_lock_wait_obeys_same_deadline_before_and_after_page(self):
        self.start()
        for phase in ('initial','after-page'):
            entered, resume = threading.Event(), threading.Event()
            results = []
            def listed(_):
                entered.set(); resume.wait(0.5)
                return {'data':[],'nextCursor':None}
            self.transport.results['thread/backgroundTerminals/list'] = listed
            def read():
                try: results.append(self.controller.handle('native_background_status', {'taskId':'task-1'}))
                except native.NativeFailure as error: results.append(error)
            worker = threading.Thread(target=read,daemon=True)
            with self.subTest(phase=phase), patch.object(native,'BACKGROUND_STATUS_SECONDS',0.05):
                if phase == 'initial': self.controller.lock.acquire()
                worker.start()
                if phase == 'after-page':
                    self.assertTrue(entered.wait(0.3)); self.controller.lock.acquire()
                try:
                    resume.set(); worker.join(0.2)
                    finished = not worker.is_alive()
                finally:
                    self.controller.lock.release(); worker.join(1)
                self.assertTrue(finished,'status cannot wait behind an approval callback holding the scope lock')
                self.assertTrue(results and isinstance(results[0],native.NativeFailure))
                self.assertTrue(self.controller.background_status_slot.acquire(False))
                self.controller.background_status_slot.release()
                self.assertTrue(self.controller.operations.acquire(False))
                self.controller.operations.release()

    def test_background_status_slot_is_released_after_query_error_and_shutdown(self):
        self.start()
        def failed(_): raise native.NativeFailure('fixture EOF')
        self.transport.results['thread/backgroundTerminals/list'] = failed
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_status', {'taskId':'task-1'})
        self.transport.results['thread/backgroundTerminals/list'] = {'data':[],'nextCursor':None}
        self.assertEqual(self.controller.handle('native_background_status', {'taskId':'task-1'})['count'],0)
        self.controller.close()
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_status', {'taskId':'task-1'})
        self.assertTrue(self.controller.background_status_slot.acquire(False))
        self.controller.background_status_slot.release()

    def test_background_stop_paginates_terminates_only_bound_thread_and_verifies_empty(self):
        self.start()
        pages = iter([{'data': [self.background_process('p1')], 'nextCursor': 'next'}, {'data': [self.background_process('p2')], 'nextCursor': None}, {'data': [], 'nextCursor': None}])
        self.transport.results['thread/backgroundTerminals/list'] = lambda _: next(pages)
        with patch.object(native.os, 'kill') as kill:
            result = self.controller.handle('native_background_stop', {'taskId': 'task-1'})
            kill.assert_not_called()
        self.assertEqual(result, {'stopped': True, 'terminatedCount': 2})
        terminated = [p for m, p in self.transport.calls if m == 'thread/backgroundTerminals/terminate']
        self.assertEqual(terminated, [{'threadId': 'thread-1', 'processId': 'p1'}, {'threadId': 'thread-1', 'processId': 'p2'}])
        self.assertEqual(self.transport.calls[-1][0], 'thread/backgroundTerminals/list')

    def test_background_stop_rejects_unbound_foreign_or_detached_task(self):
        self.start()
        before = len(self.transport.calls)
        for params in ({'taskId': 'foreign'}, {'taskId': 'task-1', 'threadId': 'foreign-thread'}, {'taskId': 'task-1', 'instanceId': 'foreign-instance'}):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_stop', params)
        self.controller.handle('native_detach', {'taskId': 'task-1'})
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_stop', {'taskId': 'task-1'})
        self.assertEqual(len(self.transport.calls), before)

    def test_background_stop_rejects_unknown_termination_and_nonempty_readback(self):
        self.start()
        self.transport.results['thread/backgroundTerminals/list'] = {'data': [self.background_process()], 'nextCursor': None}
        for result in ({}, {'terminated': False}, {'terminated': 'true'}, {'terminated': None}):
            self.transport.results['thread/backgroundTerminals/terminate'] = result
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_stop', {'taskId': 'task-1'})
        self.transport.results['thread/backgroundTerminals/terminate'] = {'terminated': True}
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_stop', {'taskId': 'task-1'})

    def test_background_list_validates_all_pages_before_any_termination(self):
        self.start()
        malformed_pages = ({'data': []}, {'data': [self.background_process(threadId='foreign')], 'nextCursor': None}, {'data': [{'processId': 'p'}], 'nextCursor': None}, {'data': [self.background_process(), self.background_process()], 'nextCursor': None})
        for page in malformed_pages:
            self.transport.results['thread/backgroundTerminals/list'] = page
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_stop', {'taskId': 'task-1'})
        self.assertFalse(any(m == 'thread/backgroundTerminals/terminate' for m, _ in self.transport.calls))

    def test_background_list_has_count_and_cursor_limits(self):
        self.start()
        self.transport.results['thread/backgroundTerminals/list'] = {'data': [self.background_process('p1'), self.background_process('p2')], 'nextCursor': None}
        with patch.object(native, 'MAX_BACKGROUND_PROCESSES', 1, create=True):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_stop', {'taskId': 'task-1'})
        self.transport.results['thread/backgroundTerminals/list'] = {'data': [], 'nextCursor': 'same'}
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_stop', {'taskId': 'task-1'})
        self.assertFalse(any(m == 'thread/backgroundTerminals/terminate' for m, _ in self.transport.calls))

    def test_resume_reports_background_count_without_terminating(self):
        self.transport.results['thread/backgroundTerminals/list'] = {'data': [self.background_process()], 'nextCursor': None}
        result = self.controller.handle('native_resume', {'instanceId': self.instance, 'taskId': 'task-1', 'threadId': 'thread-1'})
        self.assertEqual(result['backgroundCount'], 1)
        self.assertTrue(self.connected['capabilities']['backgroundTerminals'])
        self.assertFalse(any(m == 'thread/backgroundTerminals/terminate' for m, _ in self.transport.calls))

    def test_cancel_waits_for_matching_thread_and_turn_before_cleanup(self):
        import threading, time
        self.prompt()
        requested = threading.Event()
        self.transport.results['turn/interrupt'] = lambda _: (requested.set() or {})
        results = []
        def cancel():
            try: results.append(self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'turn-1'}))
            except native.NativeFailure as error: results.append(error)
        with patch.object(native, 'CANCEL_COMPLETION_SECONDS', 0.5, create=True):
            worker = threading.Thread(target=cancel, daemon=True); worker.start()
            self.assertTrue(requested.wait(0.3))
            self.transport.event('turn/completed', {'threadId': 'foreign', 'turn': {'id': 'turn-1', 'status': 'interrupted'}})
            self.transport.event('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'foreign', 'status': 'interrupted'}})
            time.sleep(0.03)
            self.assertFalse(results)
            self.assertFalse(any(m == 'thread/backgroundTerminals/list' for m, _ in self.transport.calls))
            self.transport.event('turn/completed', {'threadId': 'thread-1', 'turn': {'id': 'turn-1', 'status': 'interrupted'}})
            worker.join(1)
        self.assertEqual(results, [{'requested': True, 'backgroundStopped': True, 'terminatedCount': 0, 'turnStatus': 'interrupted'}])

    def test_cancel_completion_timeout_is_unknown_and_does_not_resend(self):
        self.prompt(); self.transport.results['turn/interrupt'] = {}
        with patch.object(native, 'CANCEL_COMPLETION_SECONDS', 0.02, create=True):
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'turn-1'})
            with self.assertRaises(native.NativeFailure): self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'turn-1'})
        self.assertEqual(sum(m == 'turn/interrupt' for m, _ in self.transport.calls), 1)
        self.assertFalse(any(m == 'thread/backgroundTerminals/list' for m, _ in self.transport.calls))

    def test_cancel_natural_completion_race_preserves_official_status(self):
        self.prompt()
        def completed(p):
            self.transport.event('turn/completed', {'threadId': p['threadId'], 'turn': {'id': p['turnId'], 'status': 'completed'}})
            return {}
        self.transport.results['turn/interrupt'] = completed
        result = self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'turn-1'})
        self.assertEqual(result['turnStatus'], 'completed')
        self.assertTrue(result['backgroundStopped'])

    def test_cancel_cleanup_failure_does_not_claim_background_stopped(self):
        self.prompt()
        self.transport.results['thread/backgroundTerminals/list'] = {'data': [self.background_process()], 'nextCursor': None}
        self.transport.results['thread/backgroundTerminals/terminate'] = {'terminated': False}
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'turn-1'})
        self.assertTrue(any(e['data']['method'] == 'turn/completed' for e in self.events))

    def test_cancel_stops_background_processes_only_after_official_completion(self):
        self.prompt()
        pages = iter([{'data': [self.background_process()], 'nextCursor': None}, {'data': [], 'nextCursor': None}])
        def listed(_):
            self.assertTrue(any(e['data']['method'] == 'turn/completed' for e in self.events))
            return next(pages)
        self.transport.results['thread/backgroundTerminals/list'] = listed
        result = self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'turn-1'})
        self.assertEqual(result, {'requested': True, 'backgroundStopped': True, 'terminatedCount': 1, 'turnStatus': 'interrupted'})
        self.assertEqual([p for m, p in self.transport.calls if m == 'thread/backgroundTerminals/terminate'], [{'threadId': 'thread-1', 'processId': 'process-1'}])

    def test_cancel_connection_loss_is_unknown_without_background_mutation(self):
        self.prompt()
        def disconnected(_):
            self.transport.event('connection/lost', {})
            return {}
        self.transport.results['turn/interrupt'] = disconnected
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_cancel', {'taskId': 'task-1', 'turnId': 'turn-1'})
        self.assertFalse(any(m.startswith('thread/backgroundTerminals/') for m, _ in self.transport.calls))

    def test_background_stop_rejects_previous_connection_generation(self):
        self.start(); self.transport.event('connection/lost', {})
        self.controller.handle('native_connect', self.params)
        current = self.controller.instances[self.instance]['transport']
        before = len(current.calls)
        with self.assertRaises(native.NativeFailure): self.controller.handle('native_background_stop', {'taskId': 'task-1'})
        self.assertEqual(len(current.calls), before)

    def test_close_detaches_transport(self):
        self.controller.close(); self.assertTrue(self.transport.closed)


class NativeTransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.instance = str(uuid.uuid4())
        self.workspace = self.root / 'workspace'; self.workspace.mkdir()
        self.executable = self.root / 'mock-codex'
        self.executable.write_text('#!' + sys.executable + '\n' + MOCK_SERVER)
        self.executable.chmod(0o700)
        self.config = {'instanceId': self.instance, 'workspace': str(self.workspace), 'profileRoot': str(self.root / self.instance), 'executable': str(self.executable)}
        self.events = []
        self.transports = []
        self.addCleanup(self.cleanup_owned_daemons)
    def connect(self):
        self.assertTrue(hasattr(native._transport_module.NativeTransport, 'request'), 'native transport is not implemented')
        t = native._transport_module.NativeTransport(self.config, self.events.append)
        self.transports.append(t)
        return t
    def cleanup_owned_daemons(self):
        import os, signal, time, shutil
        for t in self.transports: t.close()
        for daemon in native._transport_module._DAEMONS:
            if daemon.args[0] == str(self.executable) and daemon.poll() is None:
                os.killpg(daemon.pid, signal.SIGTERM); daemon.wait(timeout=2)
        receipt = Path(self.config['profileRoot']) / 'travelcat-daemon.json'
        if receipt.exists():
            r = json.loads(receipt.read_text())
            # Only the exact mock server created by this temporary fixture is ours.
            if r.get('executable') == str(self.executable):
                if native._transport_module._process_identity(r['pid']) == r.get('processIdentity'):
                    try: os.kill(r['pid'], signal.SIGTERM)
                    except ProcessLookupError: pass
                try: os.waitpid(r['pid'], 0)
                except ChildProcessError: pass
                socket_dir = Path(r['socket']).parent
                if socket_dir.name.startswith('tc-native-') and socket_dir.exists(): shutil.rmtree(socket_dir)
    def test_transport_roundtrip_and_daemon_survives_close(self):
        import os
        t = self.connect()
        self.assertEqual(t.request('initialize', {})['codexHome'], self.config['profileRoot'])
        receipt = json.loads((Path(self.config['profileRoot']) / 'travelcat-daemon.json').read_text())
        t.close(); os.kill(receipt['pid'], 0)
        t2 = self.connect()
        self.assertEqual(t2.request('initialize', {})['codexHome'], self.config['profileRoot'])
        self.assertEqual(json.loads((Path(self.config['profileRoot']) / 'travelcat-daemon.json').read_text())['pid'], receipt['pid'])
    def test_credentials_are_not_inherited_and_profile_is_private(self):
        import os, stat
        with patch.dict(os.environ, {'OPENAI_API_KEY': 'test-secret', 'CODEX_HOME': '/do-not-use', 'HTTPS_PROXY': 'http://unsafe.test'}):
            t = self.connect()
            result = t.request('environment/check', {})
        self.assertEqual(result, {'credential': False, 'proxy': False, 'profile': self.config['profileRoot']})
        config = (Path(self.config['profileRoot']) / 'config.toml').read_text()
        self.assertIn('cli_auth_credentials_store = "keyring"', config)
        self.assertNotIn('approval_policy = "untrusted"', config)
        self.assertIn('":root" = "deny"', config)
        self.assertIn('enabled = false', config)
        self.assertEqual(stat.S_IMODE(Path(self.config['profileRoot']).stat().st_mode), 0o700)
    def test_timeout_does_not_resend_and_loses_connection(self):
        t = self.connect()
        with patch.object(native._transport_module, 'REQUEST_SECONDS', 0.08):
            with self.assertRaises(native.NativeFailure): t.request('never/respond', {})
        self.assertTrue(any(e.get('method') == 'connection/lost' for e in self.events))
        with self.assertRaises(native.NativeFailure): t.request('initialize', {})
    def test_read_deadline_covers_writer_wait_and_expired_request_sends_nothing(self):
        t = self.connect()
        t.writer.acquire()
        started = time.monotonic()
        try:
            with self.assertRaises(native.NativeFailure): t.request('thread/backgroundTerminals/list', {}, deadline=started+0.04)
        finally: t.writer.release()
        self.assertLess(time.monotonic()-started,0.2)
        self.assertFalse(t.closed,'waiting for a writer did not put partial bytes on the socket')
        with patch.object(t,'_send',wraps=t._send) as send:
            with self.assertRaises(native.NativeFailure): t.request('thread/backgroundTerminals/list', {}, deadline=time.monotonic()-1)
            send.assert_not_called()
        self.assertEqual(t.request('initialize', {})['codexHome'], self.config['profileRoot'])
        self.assertFalse(t.pending)

    def test_official_history_read_deadlines_cover_writer_and_late_response_without_control_timeout(self):
        t=self.connect()
        for method in ('thread/turns/list','thread/items/list'):
            with self.subTest(method=method):
                t.writer.acquire()
                started=time.monotonic()
                try:
                    with self.assertRaises(native.NativeFailure): t.request(method,{},deadline=started+0.03)
                finally: t.writer.release()
                self.assertLess(time.monotonic()-started,0.2)
                started=time.monotonic()
                with self.assertRaises(native.NativeFailure): t.request(method,{'fixture':'late'},deadline=started+0.03)
                self.assertLess(time.monotonic()-started,0.2)
                self.assertFalse(t.closed)
                self.assertEqual(t.request('initialize',{})['codexHome'],self.config['profileRoot'])
                self.assertFalse(t.pending)
        for method in ('thread/resume','turn/start','turn/interrupt','thread/backgroundTerminals/terminate'):
            with self.subTest(method=method),self.assertRaises(native.NativeFailure): t.request(method,{},deadline=time.monotonic()+0.1)

    def test_read_response_deadline_ignores_late_reply_and_keeps_next_request_bound(self):
        t = self.connect()
        started = time.monotonic()
        with self.assertRaises(native.NativeFailure): t.request('thread/backgroundTerminals/list', {'fixture':'late'}, deadline=started+0.04)
        self.assertLess(time.monotonic()-started,0.2)
        self.assertFalse(t.closed)
        self.assertEqual(t.request('initialize', {})['codexHome'],self.config['profileRoot'])
        self.assertFalse(t.pending)
        self.assertFalse(any(event.get('method') == 'connection/lost' for event in self.events))

    def test_read_send_and_response_share_same_deadline(self):
        t = self.connect()
        original = t._send
        def delayed_send(value, *, deadline=None):
            time.sleep(0.04)
            return original(value,deadline=deadline)
        started = time.monotonic()
        with patch.object(t,'_send',side_effect=delayed_send):
            with self.assertRaises(native.NativeFailure): t.request('thread/backgroundTerminals/list', {'fixture':'never'}, deadline=started+0.08)
        self.assertLess(time.monotonic()-started,0.11,'response wait cannot restart the budget after sending')
        self.assertFalse(t.closed)
        self.assertEqual(t.request('initialize', {})['codexHome'],self.config['profileRoot'])

    def test_read_write_failure_does_not_wait_for_blocked_connection_lost_callback(self):
        t = self.connect()
        entered, release = threading.Event(), threading.Event()
        def blocked_callback(event):
            entered.set(); release.wait(0.4); self.events.append(event)
        t.callback = blocked_callback
        started = time.monotonic()
        try:
            with patch.object(t,'_write_bytes',side_effect=native.NativeFailure('fixture uncertain partial frame')):
                with self.assertRaises(native.NativeFailure):
                    t.request('thread/backgroundTerminals/list', {}, deadline=started+0.05)
            elapsed = time.monotonic()-started
            self.assertTrue(entered.wait(0.2))
            self.assertTrue(t.closed,'uncertain partial frames must still close the socket')
            self.assertFalse(t.pending)
        finally: release.set()
        self.assertLess(elapsed,0.2,'bounded read cleanup must not wait on a scope callback held by approvals')

    def test_oversize_frame_disconnects(self):
        t = self.connect()
        with self.assertRaises(native.NativeFailure): t.request('oversize', {})
        self.assertTrue(any(e.get('method') == 'connection/lost' for e in self.events))
    def test_official_private_socket_alias_is_verified(self):
        import socket
        short = tempfile.TemporaryDirectory(prefix='tcn-', dir='/tmp'); self.addCleanup(short.cleanup)
        target_root = Path(short.name).resolve()
        target = target_root / ('a' * 64)
        sock = socket.socket(socket.AF_UNIX); self.addCleanup(sock.close)
        sock.bind(str(target)); target.chmod(0o600)
        alias = self.root / 'server.sock'; alias.symlink_to(target)
        with patch.object(native._transport_module, 'DAEMON_SOCKET_ROOT', target_root, create=True):
            self.assertEqual(native._transport_module._socket_info(alias).st_ino, alias.lstat().st_ino)
        arbitrary = self.root / 'arbitrary.sock'; arbitrary.symlink_to(target)
        with self.assertRaises(native.NativeFailure): native._transport_module._socket_info(arbitrary)

    def test_fragmented_message_and_ping(self):
        t = self.connect()
        self.assertEqual(t.request('fragmented', {})['codexHome'], self.config['profileRoot'])
    def test_masked_server_frame_is_rejected(self):
        t = self.connect()
        with self.assertRaises(native.NativeFailure): t.request('masked', {})
    def test_wrong_websocket_accept_is_rejected(self):
        self.executable.write_text(self.executable.read_text().replace("accept = base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())", "accept = b'wrong'"))
        with self.assertRaises(native.NativeFailure): self.connect()

    def test_server_close_and_invalid_continuation_disconnect(self):
        for method in ('close', 'bad-continuation'):
            t = self.connect()
            with self.assertRaises(native.NativeFailure): t.request(method, {})
            self.assertTrue(t.closed)

    def test_backpressure_write_respects_deadline(self):
        import socket, threading
        sender, receiver = socket.socketpair()
        sender.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        self.addCleanup(sender.close); self.addCleanup(receiver.close)
        t = native._transport_module.NativeTransport.__new__(native._transport_module.NativeTransport)
        t.socket, t.writer, t.closed = sender, threading.Lock(), False
        errors = []
        def send():
            try: t._wire_send(b'x' * 65536)
            except native.NativeFailure as error: errors.append(error)
        with patch.object(native._transport_module, 'REQUEST_SECONDS', 0.05):
            worker = threading.Thread(target=send, daemon=True); worker.start(); worker.join(0.4)
            alive = worker.is_alive()
            if alive: sender.shutdown(socket.SHUT_RDWR); worker.join(1)
        self.assertFalse(alive, 'write exceeded its deadline under socket backpressure')
        self.assertTrue(errors)

    def test_idle_ping_does_not_start_data_frame_deadline(self):
        import socket, threading, time
        sender, receiver = socket.socketpair()
        self.addCleanup(sender.close); self.addCleanup(receiver.close)
        t = native._transport_module.NativeTransport.__new__(native._transport_module.NativeTransport)
        t.socket, t.writer, t.closed, t.total = sender, threading.Lock(), False, 0
        sender.setblocking(False)
        results = []
        def read():
            try: results.append(t._message())
            except native.NativeFailure as error: results.append(error)
        with patch.object(native._transport_module, 'REQUEST_SECONDS', 0.05):
            worker = threading.Thread(target=read, daemon=True); worker.start()
            receiver.sendall(b'\x89\x00'); time.sleep(0.12)
            receiver.sendall(b'\x81\x02{}'); worker.join(0.3)
        sender.shutdown(socket.SHUT_RDWR)
        self.assertEqual(results, [b'{}'])
    def test_failed_startup_cleans_only_its_owned_process_and_can_retry(self):
        self.executable.write_text(self.executable.read_text().replace('server = socket.socket', 'import time; time.sleep(0.2)\nserver = socket.socket'))
        with patch.object(native._transport_module, 'START_SECONDS', 0.05):
            with self.assertRaises(native.NativeFailure): self.connect()
        self.assertIsNotNone(native._transport_module._DAEMONS[-1].poll())
        t = self.connect()
        self.assertIn('codexHome', t.request('initialize', {}))

    def test_existing_profile_configuration_is_not_overwritten(self):
        profile = Path(self.config['profileRoot']); profile.mkdir(mode=0o700)
        (profile / 'config.toml').write_text('do not overwrite')
        with self.assertRaises(native.NativeFailure): self.connect()
        self.assertEqual((profile / 'config.toml').read_text(), 'do not overwrite')


MOCK_SERVER = r'''
import base64, hashlib, json, os, socket, struct, sys, threading
args = sys.argv[1:]
path = args[args.index('--listen') + 1].removeprefix('unix://')
server = socket.socket(socket.AF_UNIX); server.bind(path); server.listen()
def exact(c, n):
    data = b''
    while len(data) < n:
        part = c.recv(n-len(data))
        if not part: raise OSError()
        data += part
    return data
def read_frame(c):
    h = exact(c, 2); length = h[1] & 127
    if length == 126: length = struct.unpack('!H', exact(c,2))[0]
    if length == 127: length = struct.unpack('!Q', exact(c,8))[0]
    if not h[1] & 128: raise OSError('client did not mask')
    key = exact(c,4); data = exact(c,length)
    return h[0] & 15, bytes(b ^ key[i % 4] for i,b in enumerate(data))
def send_frame(c, data, opcode=1, final=True):
    first = (128 if final else 0) | opcode
    if len(data) < 126: header = bytes([first,len(data)])
    elif len(data) < 65536: header = bytes([first,126]) + struct.pack('!H',len(data))
    else: header = bytes([first,127]) + struct.pack('!Q',len(data))
    c.sendall(header+data)
def client(c):
    try:
        header = b''
        while not header.endswith(b'\r\n\r\n'): header += exact(c,1)
        key = next(line.split(b':',1)[1].strip() for line in header.split(b'\r\n') if line.lower().startswith(b'sec-websocket-key:'))
        accept = base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
        c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
        while True:
            opcode, data = read_frame(c)
            if opcode == 8: break
            f = json.loads(data)
            if 'id' not in f or 'method' not in f: continue
            m = f['method']
            if m == 'never/respond': continue
            if m in ('thread/backgroundTerminals/list','thread/turns/list','thread/items/list') and f['params'].get('fixture') == 'never': continue
            if m in ('thread/backgroundTerminals/list','thread/turns/list','thread/items/list') and f['params'].get('fixture') == 'late':
                import time; time.sleep(0.12)
                send_frame(c,json.dumps({'id':f['id'],'result':{'stale':True}}).encode()); continue
            if m == 'close': send_frame(c,b'',opcode=8); continue
            if m == 'bad-continuation': send_frame(c,b'{}',opcode=0); continue
            if m == 'oversize': send_frame(c,b'x'*(3*1024*1024)); continue
            result = {'codexHome': os.environ['CODEX_HOME']}
            if m == 'environment/check': result = {'credential': 'OPENAI_API_KEY' in os.environ, 'proxy': 'HTTPS_PROXY' in os.environ, 'profile': os.environ['CODEX_HOME']}
            payload = json.dumps({'id': f['id'], 'result': result}).encode()
            if m == 'fragmented':
                send_frame(c,payload[:5],final=False)
                send_frame(c,b'keepalive',opcode=9)
                pong, value = read_frame(c)
                if pong != 10 or value != b'keepalive': raise OSError('bad pong')
                send_frame(c,payload[5:],opcode=0)
            elif m == 'masked': c.sendall(b'\x81\x82abcdxx')
            else: send_frame(c,payload)
    except (OSError, ValueError): pass
    finally: c.close()
while True:
    c, _ = server.accept(); threading.Thread(target=client,args=(c,),daemon=True).start()
'''

if __name__ == '__main__': unittest.main()
