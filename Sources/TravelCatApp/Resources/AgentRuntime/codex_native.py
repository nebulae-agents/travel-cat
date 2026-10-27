"""Bounded native Codex control. Auth and inference remain in the official server."""
import hashlib
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import threading
import time
import urllib.parse
import uuid

_spec = importlib.util.spec_from_file_location('travelcat_codex_native_transport', Path(__file__).resolve().with_name('codex_native_transport.py'))
_transport_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_transport_module)
NativeTransport = _transport_module.NativeTransport
NativeFailure = _transport_module.NativeFailure
_workspace_spec = importlib.util.spec_from_file_location('travelcat_native_workspace_io', Path(__file__).resolve().with_name('workspace_io.py'))
_workspace_module = importlib.util.module_from_spec(_workspace_spec)
_workspace_spec.loader.exec_module(_workspace_module)
PROFILE = 'travelcat-native'
MAX_HISTORY = 4000
MAX_PAGES = 40
MAX_HISTORY_BYTES = 8 * 1024 * 1024
APPROVAL_SECONDS = 300
CANCEL_COMPLETION_SECONDS = 10
MAX_BACKGROUND_PROCESSES = 256
MAX_BACKGROUND_PAGES = 10
MAX_BACKGROUND_BYTES = 1024 * 1024
# Swift waits 15 seconds; this covers the entire native read, never each page separately.
BACKGROUND_STATUS_SECONDS = 5
TERMINAL_TURN_STATUSES = frozenset(('completed', 'failed', 'interrupted'))


def _text(value, name, limit=512):
    if not isinstance(value, str) or not value.strip() or len(value) > limit or '\x00' in value:
        raise NativeFailure('invalid ' + name)
    return value


def _account(value):
    account = value.get('account') if isinstance(value, dict) else None
    if not isinstance(account, dict):
        return {'authenticated': False, 'authMode': None, 'planType': None}
    return {'authenticated': True, 'authMode': account.get('type'), 'planType': account.get('planType')}


def _inside(path, root):
    return path == root or root in path.parents


def _configuration(params):
    instance = _text(params.get('instanceId'), 'instance id')
    try:
        if str(uuid.UUID(instance)) != instance.lower(): raise ValueError()
    except ValueError:
        raise NativeFailure('instance id must be a UUID') from None
    paths = {}
    for name in ('workspace', 'profileRoot', 'executable'):
        value = _text(params.get(name), name, 4096)
        p = Path(value)
        if not p.is_absolute(): raise NativeFailure(name + ' must be absolute')
        if name == 'profileRoot' and p.is_symlink(): raise NativeFailure('native profile cannot be a symlink')
        # Resolving existing ancestors avoids lexical overlap and symlink aliases.
        paths[name] = str(p) if name == 'executable' else str(p.resolve())
    workspace, profile = Path(paths['workspace']), Path(paths['profileRoot'])
    default = (Path.home() / '.codex').resolve()
    if profile.name.lower() != instance.lower() or _inside(profile, workspace) or _inside(workspace, profile) or _inside(profile, default) or _inside(default, profile):
        raise NativeFailure('profile must be a dedicated instance directory outside workspace and default Codex home')
    if not workspace.is_dir() or not Path(paths['executable']).is_file() or not os.access(paths['executable'], os.X_OK):
        raise NativeFailure('workspace or executable unavailable')
    return {'instanceId': instance, **paths}


class CodexNativeController:
    def __init__(self, output, audit=None):
        self.output = output
        self.audit = audit
        self.instances, self.tasks, self.approvals = {}, {}, {}
        self.lock = threading.RLock()
        self.operations = threading.RLock()
        self.background_status_slot = threading.Lock()
        self.closed = threading.Event()
        self.sweeper = threading.Thread(target=self._sweep, daemon=True)
        self.sweeper.start()

    def handle(self, method, params):
        if not isinstance(params, dict): raise NativeFailure('invalid native parameters')
        handlers = {'native_connect': self._connect, 'native_login': self._login,
                    'native_login_cancel': self._login_cancel, 'native_start': self._start,
                    'native_prompt': self._prompt, 'native_resume': self._resume,
                    'native_permission': self._permission, 'native_cancel': self._cancel,
                    'native_detach': self._detach, 'native_background_stop': self._background_stop,
                    'native_background_status': self._background_status, 'native_reconcile': self._reconcile,
                    'native_artifacts': self._artifacts, 'native_export': self._export,
                    'native_artifact_changes': self._artifact_changes}
        if method not in handlers: raise NativeFailure('unsupported native method')
        if method in ('native_background_status', 'native_reconcile'): return self._bounded_native_read(params, handlers[method])
        if method in ('native_artifacts','native_export','native_artifact_changes'):
            return self._bounded_artifact_read(params, handlers[method])
        with self.operations:
            if self.closed.is_set(): raise NativeFailure('native controller closed')
            return handlers[method](params)

    def _emit(self, instance, method, params, task_id=None):
        event = {'event': 'native', 'instanceId': instance, 'data': {'method': method, 'params': params}}
        if task_id is not None: event['taskId'] = task_id
        self.output(event)

    def _instance(self, params):
        instance = self.instances.get(params.get('instanceId'))
        if not instance or not instance.get('connected'): raise NativeFailure('native instance is disconnected')
        return instance

    def _task(self, params):
        task = self.tasks.get(params.get('taskId'))
        if not task or not task.get('verified'): raise NativeFailure('native task is not bound')
        if not self.instances[task['instanceId']].get('connected'): raise NativeFailure('native instance is disconnected')
        return task

    def _artifact_task(self, params):
        with self.lock:
            task = self._task(params)
            instance = self.instances[task['instanceId']]
            if not task.get('generation') or task['generation'] != instance.get('generation'):
                raise NativeFailure('native artifact task requires current connection resume')
            if 'bindingId' in params and (params['bindingId']!=task['bindingId'] or params.get('executionId')!=task['executionId']):
                raise NativeFailure('artifact caller binding or execution is stale')
            return task

    @staticmethod
    def _open_workspace(root):
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for component in Path(root).parts[1:]:
                child = _workspace_module.open_directory(fd, component)
                os.close(fd); fd = child
            return fd
        except Exception:
            os.close(fd); raise

    @staticmethod
    def _artifact_identity(task):
        return (task.get('bindingId'),task.get('executionId'),task.get('generation'),task.get('threadId'))

    def _bounded_artifact_read(self, params, handler):
        # Share the nonqueued read slot. Kernel filesystem calls cannot be forcibly
        # cancelled; keep control operations unlocked while bounded I/O runs.
        deadline=time.monotonic()+BACKGROUND_STATUS_SECONDS
        if not self.background_status_slot.acquire(False):raise NativeFailure('native observation already pending')
        try:
            if not self.operations.acquire(False):raise NativeFailure('native control busy; artifact read skipped')
            try:
                with self._background_status_lock(deadline):
                    task=self._artifact_task(params)
                    identity=self._artifact_identity(task)
            finally:self.operations.release()
            result=handler(params,deadline=deadline)
            with self._background_status_lock(deadline):
                self._check_background_deadline(deadline)
                if self._artifact_task(params) is not task or self._artifact_identity(task)!=identity:
                    raise NativeFailure('artifact binding changed during read')
            return result
        finally:self.background_status_slot.release()

    def _scoped_artifact_task(self,params,deadline):
        if deadline is None:return self._artifact_task(params)
        with self._background_status_lock(deadline):return self._artifact_task(params)

    def _workspace_read(self, params, method, *, deadline=None):
        task = self._scoped_artifact_task(params,deadline)
        identity=self._artifact_identity(task)
        instance=self.instances[task['instanceId']]
        root = instance['config']['workspace']
        request = {'method': method}
        if method == 'export': request['path'] = params.get('path')
        fd = current = None
        try:
            fd=self._open_workspace(root)
            root_identity=_workspace_module.identity(os.fstat(fd))
            if root_identity!=task['workspaceIdentity']:raise NativeFailure('workspace root changed')
            result=_workspace_module.perform(request, root=fd)
            current=self._open_workspace(root)
            if _workspace_module.identity(os.fstat(current))!=root_identity or self._scoped_artifact_task(params,deadline) is not task or self._artifact_identity(task)!=identity:
                raise NativeFailure('artifact binding or workspace changed')
            if method=='export':result.update(bindingId=task['bindingId'],executionId=task['executionId'])
            return result
        except Exception:
            raise NativeFailure('artifact read denied or failed') from None
        finally:
            if fd is not None: os.close(fd)
            if current is not None:os.close(current)

    def _artifacts(self, params, *, deadline=None):
        return self._workspace_read(params, 'artifacts',deadline=deadline)

    def _export(self, params, *, deadline=None):
        return self._workspace_read(params, 'export',deadline=deadline)

    def _artifact_changes(self, params, *, deadline=None):
        task=self._scoped_artifact_task(params,deadline)
        return _workspace_module.changes(self._workspace_read(params,'manifest',deadline=deadline),task['artifactBaseline'],task['bindingId'],task['executionId'],task['artifactTurnId'])

    def _connect(self, params):
        config = _configuration(params)
        key = config['instanceId']
        old = self.instances.get(key)
        if old and old['config'] != config: raise NativeFailure('instance configuration changed')
        if old and old['connected']:
            self._refresh(old)
            return old['connection']
        if old: old['transport'].close()
        instance = {'config': config, 'connected': False, 'generation': str(uuid.uuid4()), 'pendingStart': None, 'buffer': [], 'loginId': None, 'answeredRequests': set()}
        self.instances[key] = instance
        try:
            transport = NativeTransport(config, lambda frame: self._frame(key, instance['generation'], frame))
            instance['transport'] = transport
            result = transport.request('initialize', {'clientInfo': {'name': 'travelcat_native', 'title': 'Travel Cat', 'version': '1.0.0'}, 'capabilities': {'experimentalApi': True}})
            if result.get('codexHome') != config['profileRoot']: raise NativeFailure('server profile identity mismatch')
            version = _text(result.get('userAgent'), 'server version')
            transport.notify('initialized', {})
            account = _account(transport.request('account/read', {'refreshToken': False}))
            models = self._pages(instance, 'model/list', {'includeHidden': False}, limit=400)
            models = [{k: m.get(k) for k in ('id', 'model', 'displayName', 'isDefault')} for m in models if isinstance(m, dict) and isinstance(m.get('model'), str)]
            connection = {'connected': True, 'version': version, 'account': account, 'models': models,
                          'capabilities': {'authentication': True, 'history': True, 'resume': True, 'events': True, 'approval': True, 'interrupt': True, 'backgroundTerminals': True, 'fileChanges': True, 'artifacts': True, 'usage': True, 'cost': False, 'observability': 'native'}}
            instance.update(connected=True, connection=connection)
            return connection
        except Exception:
            instance['connected'] = False
            if instance.get('transport'): instance['transport'].close()
            raise

    def _refresh(self, instance):
        instance['connection']['account'] = _account(instance['transport'].request('account/read', {'refreshToken': False}))
        models = self._pages(instance, 'model/list', {'includeHidden': False}, limit=400)
        instance['connection']['models'] = [{k: m.get(k) for k in ('id', 'model', 'displayName', 'isDefault')} for m in models if isinstance(m, dict) and isinstance(m.get('model'), str)]

    def _login(self, params):
        instance = self._instance(params)
        result = instance['transport'].request('account/login/start', {'type': 'chatgpt'})
        login_id = _text(result.get('loginId'), 'login id')
        url = _text(result.get('authUrl'), 'authorization URL', 16384)
        parsed = urllib.parse.urlsplit(url)
        if result.get('type') != 'chatgpt' or parsed.scheme != 'https' or parsed.hostname not in ('auth.openai.com', 'auth.chatgpt.com') or parsed.username or parsed.password or parsed.port not in (None, 443) or any(c.isspace() for c in url):
            instance['transport'].request('account/login/cancel', {'loginId': login_id})
            raise NativeFailure('server returned an unsupported authorization URL')
        instance['loginId'] = login_id
        return {'loginId': login_id, 'authUrl': url}

    def _login_cancel(self, params):
        instance = self._instance(params)
        if not instance['loginId'] or params.get('loginId') != instance['loginId']: raise NativeFailure('login request is stale')
        result = instance['transport'].request('account/login/cancel', {'loginId': instance['loginId']})
        instance['loginId'] = None
        return result

    def _policy(self, instance):
        return {'cwd': instance['config']['workspace'], 'runtimeWorkspaceRoots': [instance['config']['workspace']],
                'permissions': PROFILE, 'approvalPolicy': 'untrusted', 'approvalsReviewer': 'user'}

    def _verify(self, instance, response):
        if response.get('activePermissionProfile', {}).get('id') != PROFILE or response.get('approvalPolicy') != 'untrusted' or response.get('approvalsReviewer') != 'user' or response.get('cwd') != instance['config']['workspace'] or response.get('runtimeWorkspaceRoots') != [instance['config']['workspace']]:
            raise NativeFailure('server did not enforce required native permission profile')
        sandbox = response.get('sandbox', {})
        if sandbox.get('type') != 'workspaceWrite' or sandbox.get('networkAccess') is not False or sandbox.get('excludeTmpdirEnvVar') is not True or sandbox.get('excludeSlashTmp') is not True or sandbox.get('writableRoots') not in ([], [instance['config']['workspace']]):
            raise NativeFailure('server returned unsupported sandbox permissions')

    def _bind(self, instance, task_id, thread_id=None):
        _text(task_id, 'task id')
        if task_id in self.tasks: raise NativeFailure('task already bound; detach before resuming')
        if thread_id and any(t.get('threadId') == thread_id and t['instanceId'] == instance['config']['instanceId'] for t in self.tasks.values()):
            raise NativeFailure('thread already bound to another task')
        task = {'taskId': task_id, 'instanceId': instance['config']['instanceId'], 'threadId': thread_id, 'turnId': None, 'verified': False, 'generation': instance['generation'], 'messages': set(), 'uncertain': False, 'buffer': [], 'bufferBytes': 0, 'status': {'type': 'unknown'}, 'cancelWaiter': None, 'interruptRequestedTurn': None, 'terminalTurns': {}}
        task.update(bindingId=str(uuid.uuid4()),executionId=None,artifactTurnId=None,artifactBaseline=None)
        fd=self._open_workspace(instance['config']['workspace'])
        try:task['workspaceIdentity']=_workspace_module.identity(os.fstat(fd))
        finally:os.close(fd)
        self.tasks[task_id] = task
        return task

    def _start(self, params):
        instance = self._instance(params)
        model = _text(params.get('model'), 'model')
        if not any(m['model'] == model or m['id'] == model for m in instance['connection']['models']): raise NativeFailure('model is not in native catalog')
        task = self._bind(instance, params.get('taskId'))
        instance['pendingStart'] = task['taskId']
        try:
            result = instance['transport'].request('thread/start', {**self._policy(instance), 'model': model, 'historyMode': 'paginated', 'ephemeral': False})
            self._verify(instance, result)
            thread = result['thread']
            task.update(threadId=_text(thread.get('id'), 'thread id'), verified=True)
            buffered = instance['buffer']; instance['buffer'] = []
            instance['pendingStart'] = None
            for frame in buffered: self._frame(task['instanceId'], instance['generation'], frame)
            return {'threadId': task['threadId'], 'sessionId': thread.get('sessionId', task['threadId'])}
        except Exception:
            self.tasks.pop(task['taskId'], None)
            raise
        finally:
            instance['pendingStart'] = None
            instance['buffer'] = []

    def _prompt(self, params):
        task = self._task(params)
        if task['turnId'] or task['uncertain']: raise NativeFailure('task has an active or uncertain turn; resume before sending again')
        text = _text(params.get('text'), 'prompt', 256 * 1024)
        message_id = _text(params.get('clientUserMessageId'), 'message id')
        if message_id in task['messages']: raise NativeFailure('message was already submitted')
        task['executionId']=str(uuid.uuid4())
        task['artifactTurnId']=None
        task['artifactBaseline']=None
        task['artifactBaseline']=self._workspace_read(params,'manifest')
        if self.audit:self.audit.record(task['taskId'],'operation.artifactBaseline',bindingId=task['bindingId'],executionId=task['executionId'],fileCount=len(task['artifactBaseline']['files']),inventoryComplete=task['artifactBaseline']['inventoryComplete'],hashComplete=task['artifactBaseline']['hashComplete'],reason=task['artifactBaseline'].get('reason'))
        task['messages'].add(message_id)
        task['uncertain'] = True
        instance = self.instances[task['instanceId']]
        result = instance['transport'].request('turn/start', {'threadId': task['threadId'], 'input': [{'type': 'text', 'text': text}], 'clientUserMessageId': message_id, **self._policy(instance)})
        turn_id = _text(result.get('turn', {}).get('id'), 'turn id')
        # A completion event can arrive before this response; do not restore that turn.
        task['artifactTurnId']=turn_id
        if task['uncertain']:
            if turn_id in task['terminalTurns']:task.update(turnId=None,uncertain=False,status={'type':'idle'})
            else:task.update(turnId=turn_id, uncertain=False)
        return {'turnId': turn_id}

    def _pages(self, instance, method, params, limit=None, *, validate_scope=None, deadline=None, byte_budget=None):
        if limit is None: limit = MAX_HISTORY
        values, seen, size, cursor = [], set(), 0, None
        for _ in range(MAX_PAGES):
            if validate_scope: validate_scope()
            options = {'deadline': deadline} if deadline is not None else {}
            response = instance['transport'].request(method, {**params, 'limit': 100, 'cursor': cursor}, **options)
            if validate_scope: validate_scope()
            if not isinstance(response, dict) or 'nextCursor' not in response: raise NativeFailure('invalid native history page')
            data = response.get('data')
            if not isinstance(data, list) or any(not isinstance(value, dict) or 'threadId' in params and value.get('threadId', params['threadId']) != params['threadId'] for value in data): raise NativeFailure('invalid native history page')
            page_size = len(json.dumps(response).encode())
            size += page_size
            if byte_budget is not None:
                byte_budget[0] -= page_size
                if byte_budget[0] < 0: raise NativeFailure('native history exceeds shared byte limit')
            values.extend(data)
            if len(values) > limit or size > MAX_HISTORY_BYTES: raise NativeFailure('native history exceeds recovery limit')
            cursor = response.get('nextCursor')
            if cursor is None: return values
            _text(cursor, 'history cursor', 4096)
            if cursor in seen: raise NativeFailure('native history pagination did not progress')
            seen.add(cursor)
        raise NativeFailure('native history exceeds page limit')

    def _resume(self, params):
        instance = self._instance(params)
        thread_id = _text(params.get('threadId'), 'thread id')
        with self.lock:
            existing = self.tasks.get(params.get('taskId'))
            if existing:
                if existing['instanceId'] != params.get('instanceId') or existing['threadId'] != thread_id:
                    raise NativeFailure('cannot resume a task with a different native identity')
                self._invalidate(existing['taskId'], 'reconnecting')
                self.tasks.pop(existing['taskId'])
            task = self._bind(instance, params.get('taskId'), thread_id)
        try:
            result = instance['transport'].request('thread/resume', {'threadId': thread_id, 'excludeTurns': True, **self._policy(instance)})
            self._verify(instance, result)
            if result.get('thread', {}).get('id') != thread_id: raise NativeFailure('resumed thread identity mismatch')
            turns = self._pages(instance, 'thread/turns/list', {'threadId': thread_id, 'sortDirection': 'asc'})
            items = self._pages(instance, 'thread/items/list', {'threadId': thread_id, 'sortDirection': 'asc'})
            background_count = len(self._list_background(instance, thread_id))
            active = [t['id'] for t in turns if t.get('status') == 'inProgress']
            if len(active) > 1: raise NativeFailure('ambiguous active turn in native history')
            with self.lock:
                self._remember_terminal_turns(task, turns)
                task.update(verified=True, turnId=active[0] if active else None, status=result['thread'].get('status', {'type': 'unknown'}), historyTurns=turns)
                buffered = task['buffer']; task['buffer'] = []
                for frame in buffered: self._frame(task['instanceId'], task['generation'], frame)
                task.pop('historyTurns', None)
                return {'threadId': thread_id, 'status': task['status'], 'turnId': task['turnId'], 'turns': turns, 'items': items, 'backgroundCount': background_count}
        except Exception:
            with self.lock:
                self.tasks.pop(task['taskId'], None)
                for frame in task['buffer']:
                    if 'id' in frame:
                        instance['transport'].respond(frame['id'], error={'code': -32000, 'message': 'Native recovery could not verify task scope'})
            raise

    def _background_scope(self, task):
        # The product binding, never caller-supplied thread or OS PID, owns authority.
        with self.lock:
            instance = self.instances.get(task['instanceId'])
            if self.tasks.get(task['taskId']) is not task or not task['verified'] or not instance or not instance['connected'] or instance['generation'] != task['generation'] or self.closed.is_set():
                raise NativeFailure('native background task binding is stale or disconnected')
            return instance

    def _list_background(self, instance, thread_id, validate_scope=None, *, deadline=None):
        values, process_ids, cursors, cursor, size = [], set(), set(), None, 0
        for _ in range(MAX_BACKGROUND_PAGES):
            if validate_scope: validate_scope()
            options = {'deadline': deadline} if deadline is not None else {}
            response = instance['transport'].request('thread/backgroundTerminals/list', {'threadId': thread_id, 'cursor': cursor, 'limit': 100}, **options)
            if validate_scope: validate_scope()
            if not isinstance(response, dict) or not isinstance(response.get('data'), list) or 'nextCursor' not in response:
                raise NativeFailure('invalid native background terminal page')
            size += len(json.dumps(response).encode())
            if size > MAX_BACKGROUND_BYTES or len(values) + len(response['data']) > MAX_BACKGROUND_PROCESSES:
                raise NativeFailure('native background terminal list exceeds limit')
            for item in response['data']:
                if not isinstance(item, dict) or item.get('threadId', thread_id) != thread_id:
                    raise NativeFailure('native background terminal thread identity mismatch')
                process_id = _text(item.get('processId'), 'background process id')
                _text(item.get('itemId'), 'background item id')
                _text(item.get('command'), 'background command', MAX_BACKGROUND_BYTES)
                cwd = _text(item.get('cwd'), 'background cwd', 4096)
                if not Path(cwd).is_absolute() or process_id in process_ids:
                    raise NativeFailure('invalid or duplicate native background terminal identity')
                process_ids.add(process_id)
                values.append(item)
            cursor = response['nextCursor']
            if cursor is None: return values
            _text(cursor, 'background cursor', 4096)
            if cursor in cursors: raise NativeFailure('native background pagination did not progress')
            cursors.add(cursor)
        raise NativeFailure('native background terminal list exceeds page limit')

    @staticmethod
    def _check_background_deadline(deadline):
        if time.monotonic() >= deadline: raise NativeFailure('native background status deadline exceeded')

    @contextmanager
    def _background_status_lock(self, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not self.lock.acquire(timeout=remaining):
            raise NativeFailure('native background scope deadline exceeded')
        try:
            self._check_background_deadline(deadline)
            yield
        finally: self.lock.release()

    def _bounded_native_read(self, params, handler):
        deadline = time.monotonic() + BACKGROUND_STATUS_SECONDS
        # Polls never queue behind controls or one another. A stop can wait only for one bounded read.
        if not self.background_status_slot.acquire(False): raise NativeFailure('native background status already pending')
        try:
            if not self.operations.acquire(False): raise NativeFailure('native control busy; background status skipped')
            try:
                self._check_background_deadline(deadline)
                if self.closed.is_set(): raise NativeFailure('native controller closed')
                return handler(params, deadline=deadline)
            finally: self.operations.release()
        finally: self.background_status_slot.release()

    def _background_status(self, params, *, deadline):
        # This read accepts only the product task, never caller-supplied runtime authority.
        if set(params) != {'taskId'}: raise NativeFailure('background status accepts only taskId')
        _text(params.get('taskId'), 'task id')
        with self._background_status_lock(deadline):
            task = self._task(params)
            instance = self._background_scope(task)
            identity = (task['taskId'], task['instanceId'], task['generation'], task['threadId'])

        def validate_scope():
            self._check_background_deadline(deadline)
            with self._background_status_lock(deadline):
                current = self._background_scope(task)
                if current is not instance or identity != (task['taskId'], task['instanceId'], task['generation'], task['threadId']):
                    raise NativeFailure('native background observation binding changed')

        processes = self._list_background(instance, identity[3], validate_scope, deadline=deadline)
        with self._background_status_lock(deadline):
            validate_scope()
            item_ids = [process['itemId'] for process in processes]
            if len(set(item_ids)) != len(item_ids): raise NativeFailure('duplicate native background item identity')
            return {'threadId': identity[3], 'count': len(processes), 'itemIds': item_ids}

    def _remember_terminal_turns(self, task, turns):
        # Scope has already been validated by the caller; this is evidence, not control state.
        for turn in turns:
            status = turn.get('status')
            if not isinstance(status, str) or status not in TERMINAL_TURN_STATUSES: continue
            try: turn_id = _text(turn.get('id'), 'terminal turn id')
            except NativeFailure: continue
            task['terminalTurns'].setdefault(turn_id, status)
        while len(task['terminalTurns']) > MAX_HISTORY:
            task['terminalTurns'].pop(next(iter(task['terminalTurns'])))

    def _reconcile(self, params, *, deadline):
        # Official history reads never resume a thread or acquire caller-supplied authority.
        if set(params) != {'taskId'}: raise NativeFailure('reconciliation accepts only taskId')
        _text(params.get('taskId'), 'task id')
        with self._background_status_lock(deadline):
            task = self._task(params)
            instance = self._background_scope(task)
            identity = (task['taskId'], task['instanceId'], task['generation'], task['threadId'], task['turnId'])

        def validate_scope():
            self._check_background_deadline(deadline)
            with self._background_status_lock(deadline):
                current = self._background_scope(task)
                if current is not instance or identity != (task['taskId'], task['instanceId'], task['generation'], task['threadId'], task['turnId']):
                    raise NativeFailure('native reconciliation binding changed')

        values = {}
        byte_budget = [MAX_HISTORY_BYTES]
        for name in ('turns', 'items'):
            values[name] = self._pages(instance, 'thread/' + name + '/list',
                {'threadId': identity[3], 'sortDirection': 'asc'}, validate_scope=validate_scope, deadline=deadline, byte_budget=byte_budget)
        if sum(len(json.dumps(value).encode()) for value in values.values()) > MAX_HISTORY_BYTES:
            raise NativeFailure('native reconciliation exceeds history limit')
        with self._background_status_lock(deadline):
            validate_scope()
            self._remember_terminal_turns(task, values['turns'])
            return {'threadId': identity[3], **values}

    def _stop_background(self, task):
        instance = self._background_scope(task)
        # Finish validation of every page before mutating any process.
        processes = self._list_background(instance, task['threadId'])
        terminated = 0
        for process in processes:
            self._background_scope(task)
            response = instance['transport'].request('thread/backgroundTerminals/terminate', {'threadId': task['threadId'], 'processId': process['processId']})
            if not isinstance(response, dict) or response.get('terminated') is not True:
                raise NativeFailure('native background termination was not confirmed; inspect or recover before retrying')
            terminated += 1
        self._background_scope(task)
        if self._list_background(instance, task['threadId']):
            raise NativeFailure('native background terminals remain after termination; stopped state is unconfirmed')
        self._background_scope(task)
        return {'stopped': True, 'terminatedCount': terminated}

    def _background_stop(self, params):
        task = self._task(params)
        if params.get('threadId', task['threadId']) != task['threadId'] or params.get('instanceId', task['instanceId']) != task['instanceId']:
            raise NativeFailure('native background request does not match the task binding')
        return self._stop_background(task)

    def _cancel(self, params):
        with self.lock:
            task = self._task(params)
            self._background_scope(task)
            turn_id = params.get('turnId')
            if not task['turnId'] or turn_id != task['turnId']: raise NativeFailure('turn is no longer active')
            if task['interruptRequestedTurn'] == turn_id:
                raise NativeFailure('native interruption was already requested; recover before retrying')
            waiter = {'turnId': turn_id, 'generation': task['generation'], 'event': threading.Event(), 'status': None, 'error': None}
            task['cancelWaiter'] = waiter
            task['interruptRequestedTurn'] = turn_id
        deadline = time.monotonic() + CANCEL_COMPLETION_SECONDS
        try:
            self.instances[task['instanceId']]['transport'].request('turn/interrupt', {'threadId': task['threadId'], 'turnId': turn_id})
            if not waiter['event'].wait(max(0, deadline - time.monotonic())) or waiter['error'] or waiter['status'] not in ('interrupted', 'completed', 'failed'):
                raise NativeFailure('native interrupt completion is unknown; recover before retrying')
            stopped = self._stop_background(task)
            return {'requested': True, 'backgroundStopped': True, 'terminatedCount': stopped['terminatedCount'], 'turnStatus': waiter['status']}
        except Exception:
            with self.lock: task['uncertain'] = True
            raise
        finally:
            with self.lock:
                if task.get('cancelWaiter') is waiter: task['cancelWaiter'] = None

    def _detach(self, params):
        with self.lock:
            task = self.tasks.get(params.get('taskId'))
            if not task: raise NativeFailure('native task is not bound')
            self._invalidate(task['taskId'], 'detached')
            self.tasks.pop(task['taskId'], None)
        return {'detached': True}

    def _permission(self, params):
        with self.lock:
            task = self._task(params)
            pending = self.approvals.get(params.get('requestId'))
            if not pending or pending['taskId'] != task['taskId'] or pending['hash'] != params.get('requestHash') or pending['generation'] != task['generation'] or pending['threadId'] != task['threadId'] or pending['turnId'] != task['turnId'] or task['terminalTurns'].get(pending['turnId']) in TERMINAL_TURN_STATUSES or pending['expiresAt'] <= time.time():
                raise NativeFailure('approval is stale or does not match this task')
            decision = params.get('optionId')
            if decision not in pending['options']: raise NativeFailure('unsupported approval decision')
            self.approvals.pop(pending['requestId'])
            self.instances[task['instanceId']]['answeredRequests'].add(pending['serverId'])
            self.instances[task['instanceId']]['transport'].respond(pending['serverId'], {'decision': decision})
            return {'sent': True}

    def _remove_approval(self, key, reason):
        request = self.approvals.pop(key, None)
        if request:
            self._emit(request['instanceId'], 'permission/invalidated', {k: request[k] for k in ('requestId', 'threadId', 'turnId', 'itemId')} | {'reason': reason}, request['taskId'])
        return request

    def _invalidate(self, task_id, reason='resolved'):
        # Detach and transport loss revoke only local authority; they are not user cancel.
        for key, request in list(self.approvals.items()):
            if request['taskId'] == task_id: self._remove_approval(key, reason)

    def _approval(self, instance, frame, task):
        transport, p = instance['transport'], frame.get('params', {})
        if frame['id'] in instance['answeredRequests']:
            transport.respond(frame['id'], error={'code': -32600, 'message': 'Server request was already answered'})
            return
        recognized = frame['method'] in ('item/commandExecution/requestApproval', 'item/fileChange/requestApproval')
        if not recognized:
            transport.respond(frame['id'], error={'code': -32601, 'message': 'This native client does not support this server request'})
            return
        cwd = p.get('cwd')
        safe_cwd = cwd is None or (isinstance(cwd, str) and Path(cwd).is_absolute() and _inside(Path(cwd).resolve(), Path(instance['config']['workspace'])))
        if not task or not task['verified'] or task['turnId'] != p.get('turnId') or task['terminalTurns'].get(p.get('turnId')) in TERMINAL_TURN_STATUSES or not p.get('itemId') or p.get('additionalPermissions') or p.get('networkApprovalContext') or p.get('grantRoot') or p.get('environmentId') not in (None, 'local') or not safe_cwd or len(self.approvals) >= 100:
            transport.respond(frame['id'], {'decision': 'cancel'})
            return
        available = p.get('availableDecisions')
        if available is None: available = ['accept', 'decline', 'cancel']
        if not isinstance(available, list):
            transport.respond(frame['id'], error={'code': -32602, 'message': 'Invalid approval decision list'})
            return
        choices = [d for d in ('accept', 'decline', 'cancel') if d in available]
        if not choices:
            transport.respond(frame['id'], error={'code': -32602, 'message': 'No supported single-use approval decision'})
            return
        request_id = str(uuid.uuid4())
        digest = hashlib.sha256(json.dumps({'instanceId': task['instanceId'], 'taskId': task['taskId'], 'generation': task['generation'], 'request': frame}, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode()).hexdigest()
        for key, existing in list(self.approvals.items()):
            if existing['instanceId'] == task['instanceId'] and existing['serverId'] == frame['id']:
                if existing['hash'] == digest: return
                self._remove_approval(key, 'request_changed')
                transport.respond(frame['id'], error={'code': -32600, 'message': 'Server request identity changed'})
                return
        expires = time.time() + APPROVAL_SECONDS
        self.approvals[request_id] = {'requestId': request_id, 'serverId': frame['id'], 'hash': digest, 'taskId': task['taskId'], 'instanceId': task['instanceId'], 'threadId': task['threadId'], 'turnId': task['turnId'], 'itemId': p['itemId'], 'generation': task['generation'], 'expiresAt': expires, 'options': choices}
        titles = {'accept': ('仅允许这次', 'allow_once'), 'decline': ('拒绝', 'reject_once'), 'cancel': ('取消本轮', 'cancel')}
        self._emit(task['instanceId'], 'permission', {'requestId': request_id, 'requestHash': digest, 'threadId': task['threadId'], 'turnId': task['turnId'], 'itemId': p['itemId'], 'title': 'Codex 执行审批' if 'commandExecution' in frame['method'] else 'Codex 文件修改审批', 'detail': p.get('command') or p.get('reason') or 'Codex 请求执行操作', 'options': [{'id': d, 'title': titles[d][0], 'kind': titles[d][1]} for d in choices], 'expiresAt': expires}, task['taskId'])

    def _frame(self, instance_id, generation, frame):
        with self.lock:
            instance = self.instances.get(instance_id)
            if not instance or generation != instance['generation'] or self.closed.is_set(): return
            method, params = frame.get('method'), frame.get('params', {})
            if not isinstance(params, dict): return
            if method == 'connection/lost':
                instance['connected'] = False
                for task in list(self.tasks.values()):
                    if task['instanceId'] == instance_id:
                        self._invalidate(task['taskId'], 'connection_lost'); task['uncertain'] = True
                        if task.get('cancelWaiter'):
                            task['cancelWaiter']['error'] = 'connection_lost'; task['cancelWaiter']['event'].set()
                        self._emit(instance_id, method, {'reason': 'native transport disconnected'}, task['taskId'])
                self._emit(instance_id, method, {'reason': 'native transport disconnected'})
                return
            thread_id = params.get('threadId') or (params.get('thread') or {}).get('id')
            task = next((t for t in self.tasks.values() if t['instanceId'] == instance_id and t.get('threadId') == thread_id), None) if thread_id else None
            if task and not task['verified']:
                task['bufferBytes'] += len(json.dumps(frame).encode())
                if len(task['buffer']) >= 1000 or task['bufferBytes'] > MAX_HISTORY_BYTES:
                    raise NativeFailure('native recovery event buffer exceeded')
                task['buffer'].append(frame)
                return
            if 'id' in frame:
                self._approval(instance, frame, task)
                return
            if method == 'account/updated':
                if instance.get('connection'):
                    instance['connection']['account'] = {'authenticated': params.get('authMode') is not None, 'authMode': params.get('authMode'), 'planType': params.get('planType')}
                self._emit(instance_id, method, {'authMode': params.get('authMode'), 'planType': params.get('planType')})
                return
            if method == 'account/login/completed':
                self._emit(instance_id, method, {'loginId': params.get('loginId'), 'success': bool(params.get('success')), 'error': 'Codex login failed' if params.get('error') else None})
                return
            if not task:
                if instance['pendingStart'] and thread_id:
                    if len(instance['buffer']) >= 100: raise NativeFailure('too many unbound native events')
                    instance['buffer'].append(frame)
                return
            if method in ('turn/started', 'turn/completed'):
                turn = params.get('turn', {})
                terminal = task['terminalTurns']
                valid_terminal = isinstance(turn.get('status'), str) and turn['status'] in TERMINAL_TURN_STATUSES
                if (method == 'turn/started' and turn.get('id') in terminal) or (method == 'turn/completed' and not valid_terminal):
                    # Keep the raw notification visible without reviving control state.
                    self._emit(instance_id, method, params, task['taskId'])
                    return
                if method == 'turn/completed': self._remember_terminal_turns(task, [turn])
                for saved in task.get('historyTurns', []):
                    if saved.get('id') == turn.get('id') and saved.get('status') not in TERMINAL_TURN_STATUSES: saved.update(turn)
            if method == 'turn/started':
                if task['turnId'] and task['turnId'] != params.get('turn', {}).get('id'): self._invalidate(task['taskId'], 'turn_changed')
                task.update(turnId=params.get('turn', {}).get('id'), uncertain=False, status={'type': 'active'})
            elif method == 'turn/completed':
                waiter = task.get('cancelWaiter')
                if waiter and waiter['generation'] == generation and params.get('turn', {}).get('id') == waiter['turnId']:
                    waiter['status'] = params.get('turn', {}).get('status')
                    waiter['event'].set()
                if params.get('turn', {}).get('id') == task['turnId']:
                    self._invalidate(task['taskId'], 'turn_completed'); task.update(turnId=None, uncertain=False, status={'type': 'idle'})
            elif method == 'thread/status/changed':
                task['status'] = params.get('status', {'type': 'unknown'})
            elif method == 'item/completed':
                item_id = params.get('item', {}).get('id')
                for key, pending in list(self.approvals.items()):
                    if pending['taskId'] == task['taskId'] and pending['itemId'] == item_id: self._remove_approval(key, 'item_completed')
            elif method == 'serverRequest/resolved':
                for key, pending in list(self.approvals.items()):
                    if pending['instanceId'] == instance_id and pending['serverId'] == params.get('requestId'): self._remove_approval(key, 'resolved')
            self._emit(instance_id, method, params, task['taskId'])

    def _sweep(self):
        while not self.closed.wait(1):
            with self.lock:
                for key, pending in list(self.approvals.items()):
                    if pending['expiresAt'] <= time.time():
                        self._remove_approval(key, 'expired')
                        instance = self.instances[pending['instanceId']]
                        instance['answeredRequests'].add(pending['serverId'])
                        decision = next((d for d in ('decline', 'cancel') if d in pending['options']), None)
                        try:
                            if decision: instance['transport'].respond(pending['serverId'], {'decision': decision})
                            else: instance['transport'].respond(pending['serverId'], error={'code': -32000, 'message': 'Native approval expired'})
                        except NativeFailure: pass

    def close(self):
        if self.closed.is_set(): return
        self.closed.set()
        with self.lock:
            for task_id in list(self.tasks):
                self._invalidate(task_id, 'detached')
                waiter = self.tasks[task_id].get('cancelWaiter')
                if waiter:
                    waiter['error'] = 'detached'; waiter['event'].set()
            for instance in self.instances.values():
                instance['connected'] = False
                if instance.get('transport'): instance['transport'].close()
