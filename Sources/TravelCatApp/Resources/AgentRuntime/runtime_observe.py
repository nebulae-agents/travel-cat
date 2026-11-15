"""Ephemeral observations of owned objects; never discover, connect or reconcile."""
import itertools
import json
import os
import re
import selectors
import subprocess
import time

MAX_OBJECTS = 8
ROUND_SECONDS = 2.2  # Reserve 0.3s of the RPC budget for bounded client cleanup.
COVERAGE = {'native':'connected task protocol; one read page; no model request',
            'docker':'registered exact container only; not engine or model health',
            'coverage':'additional registered objects were not queried'}

def item(kind, key, state='unobserved', reason='not_connected'):
    return dict(id=kind+':'+str(key), kind=kind, state=state, reason=reason, coverage=COVERAGE[kind])

class InspectFailure(Exception):
    def __init__(self, reason): self.reason = reason

def inspect_container(command, environment, deadline):
    """Bound output and all reads; kill only our disposable inspect CLI on expiry."""
    process = None
    try:
        if time.monotonic() >= deadline: raise InspectFailure('timeout')
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=environment)
        os.set_blocking(process.stdout.fileno(), False)
        data = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining): raise InspectFailure('timeout')
                block = os.read(process.stdout.fileno(), 4096)
                if not block: break
                data.extend(block)
                if len(data) > 65536: raise InspectFailure('invalid_response')
        remaining = deadline - time.monotonic()
        if remaining <= 0: raise InspectFailure('timeout')
        if process.wait(timeout=remaining) != 0: raise InspectFailure('disconnected')
        try: return json.loads(data)
        except (ValueError, UnicodeError): raise InspectFailure('invalid_response') from None
    except subprocess.TimeoutExpired: raise InspectFailure('timeout') from None
    except PermissionError: raise InspectFailure('permission_denied') from None
    except OSError: raise InspectFailure('disconnected') from None
    finally:
        if process is not None:
            if process.poll() is None:
                process.kill()
                try: process.wait(timeout=0.1)
                except subprocess.TimeoutExpired: pass
            process.stdout.close()

def docker_item(key, task, deadline, command, environment):
    result = item('docker',key)
    identity = getattr(task,'container_id',None)
    if not isinstance(identity,str) or not re.fullmatch('[a-f0-9]{64}',identity):
        result['reason']='identity_unavailable'; return result
    if not getattr(task,'context',None) and not getattr(task,'host',None):
        result['reason']='identity_unavailable'; return result
    try:
        value=inspect_container(command(['container','inspect','--format','{{json .}}',identity],task.host,task.context),environment(),deadline)
        if not isinstance(value,dict): raise InspectFailure('invalid_response')
        if value.get('Id') != identity or value.get('Name') != '/'+task.name: raise InspectFailure('identity_mismatch')
        state=value.get('State')
        if not isinstance(state,dict) or type(state.get('Running')) is not bool: raise InspectFailure('invalid_response')
        status=state.get('Status')
        if state['Running']: result.update(state='alive',reason='none')
        elif status in ('exited','dead'): result.update(state='exited',reason='none')
        else: result.update(state='unknown',reason='unsupported')
    except InspectFailure as error: result.update(state='unknown',reason=error.reason)
    except Exception: result.update(state='unknown',reason='invalid_response')
    return result

def native_items(native, deadline, maximum):
    if not native.operations.acquire(False): return [item('native','coverage',reason='busy')],0
    try:
        if not native.lock.acquire(False): return [item('native','coverage',reason='busy')],0
        try:
            entries=list(itertools.islice(native.tasks.items(),maximum))
            omitted=max(0,len(native.tasks)-len(entries))
            snapshots=[(key,dict(task),native.instances.get(task.get('instanceId'))) for key,task in entries]
        finally: native.lock.release()
        results=[]
        for key,task,instance in snapshots:
            result=item('native',key); results.append(result)
            if time.monotonic() >= deadline: result['reason']='budget_exhausted'; continue
            transport=instance.get('transport') if instance else None
            if not transport or getattr(transport,'closed',True): continue
            if not task.get('verified') or not task.get('threadId') or task.get('generation') != instance.get('generation'):
                result['reason']='identity_mismatch'; continue
            try:
                response=transport.request('thread/backgroundTerminals/list',{'threadId':task['threadId'],'limit':1,'cursor':None},deadline=deadline,observation=True)
                if time.monotonic() >= deadline: result.update(state='unknown',reason='timeout'); continue
                if not isinstance(response,dict) or not isinstance(response.get('data'),list) or len(response['data'])>1 or 'nextCursor' not in response:
                    result.update(state='unknown',reason='invalid_response'); continue
                if (response['nextCursor'] is not None and not isinstance(response['nextCursor'],str)) or any(not isinstance(entry,dict) or entry.get('threadId',task['threadId']) != task['threadId'] for entry in response['data']):
                    result.update(state='unknown',reason='invalid_response'); continue
                result.update(state='responsive',reason='none')
            except Exception as error:
                # Only trusted local exception classifications cross the UI boundary.
                reason='timeout' if time.monotonic() >= deadline else getattr(error,'observation_reason','disconnected')
                if reason not in ('timeout','unsupported','invalid_response','disconnected','permission_denied','busy'): reason='disconnected'
                result.update(state='unknown',reason=reason)
        return results,omitted
    finally: native.operations.release()

def observe(controller, command, environment):
    if not controller.observation_slot.acquire(False): return {'items':[item('native','coverage',reason='busy'),item('docker','coverage',reason='busy')]}
    try:
        deadline=time.monotonic()+ROUND_SECONDS
        # Snapshot registry with no waiting behind task controls.
        if not controller.lock.acquire(False): return {'items':[item('native','coverage',reason='busy'),item('docker','coverage',reason='busy')]}
        try:
            docker=list(itertools.islice(controller.tasks.items(),MAX_OBJECTS))
            docker_omitted=max(0,len(controller.tasks)-len(docker))
        finally: controller.lock.release()
        items,native_omitted=native_items(controller.native,deadline,MAX_OBJECTS)
        used=len(items)
        if not items: items.append(item('native','none'))
        allowance=max(0,MAX_OBJECTS-used)
        docker_omitted+=max(0,len(docker)-allowance)
        for key,task in docker[:allowance]:
            items.append(item('docker',key,reason='budget_exhausted') if time.monotonic()>=deadline else docker_item(key,task,deadline,command,environment))
        if not docker: items.append(item('docker','none'))
        if native_omitted: items.append(item('native','omitted:'+str(native_omitted),reason='coverage_omitted'))
        if docker_omitted: items.append(item('docker','omitted:'+str(docker_omitted),reason='coverage_omitted'))
        return {'items':items}
    finally: controller.observation_slot.release()

def wire_frame(response, limit):
    """Keep one atomic pipe write. Overflow is explicit per layer, never partial JSON."""
    import hashlib
    def compact(entry):
        return {'id':entry['kind']+':'+hashlib.sha256(entry['id'].encode()).hexdigest()[:12],
                'kind':entry['kind'],'state':entry['state'],'reason':entry['reason']}
    if 'result' not in response:
        data=json.dumps(response,separators=(',',':')).encode()+b'\n'
        return data if len(data)<=limit else None
    items=[compact(entry) for entry in response['result']['items']]
    def encode(): return json.dumps({'id':response['id'],'result':{'items':items}},separators=(',',':')).encode()+b'\n'
    data=encode()
    for kind in sorted(('native','docker'),key=lambda kind:sum(entry['kind']==kind for entry in items),reverse=True):
        if len(data)<=limit: break
        if any(entry['kind']==kind for entry in items):
            items=[entry for entry in items if entry['kind']!=kind]+[{'id':kind+':coverage','kind':kind,'state':'unobserved','reason':'coverage_omitted'}]
            data=encode()
    return data if len(data)<=limit else None
