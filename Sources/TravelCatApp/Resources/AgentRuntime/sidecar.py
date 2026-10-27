#!/usr/bin/env python3
"""Trusted stdio controller. Never emit exception text or subprocess diagnostics."""
import base64
import hashlib
from collections import namedtuple
import contextlib
import http.client
import json
import os
from pathlib import Path
import queue
import re
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import importlib.util

# The app launches with -I; load only this bundled trusted sibling, never cwd/PYTHONPATH.
_workspace_spec=importlib.util.spec_from_file_location('travelcat_workspace_io',Path(__file__).resolve().with_name('workspace_io.py'))
workspace_io=importlib.util.module_from_spec(_workspace_spec)
_workspace_spec.loader.exec_module(workspace_io)

for _name in ('audit_runtime', 'audit_payload', 'runtime_discovery', 'codex_native'):
    _spec=importlib.util.spec_from_file_location(_name,Path(__file__).resolve().with_name(_name+'.py'))
    _module=importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_module)
    globals()[_name]=_module
FrozenRequest=namedtuple('FrozenRequest','path body headers streaming request_hash')

MAX_LINE = 2 * 1024 * 1024
MAX_OUTPUT = 32 * 1024 * 1024
MAX_ACP_BYTES = 8 * 1024 * 1024
MAX_ACP_EVENTS = 10000
TIMEOUT = 120
KEEPALIVE_SECONDS = 10
TASK_SECONDS = 3600

class RuntimeFailure(Exception):
    pass

def child_environment():
    return {k:v for k,v in os.environ.items() if k in ("PATH","HOME","TMPDIR","LANG","LC_ALL")}

def docker_command(args, host=None, context=None):
    prefix=["docker"]
    if context:
        if not isinstance(context,str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}",context): raise RuntimeFailure("invalid Docker context")
        prefix += ["--context",context]
    if host is None or host == '':
        return [*prefix, *args]
    if not isinstance(host,str) or not re.fullmatch(r'(?:[A-Za-z0-9][A-Za-z0-9_.-]{0,63}@)?[A-Za-z0-9][A-Za-z0-9_.-]{0,127}',host):
        raise RuntimeFailure('invalid SSH host alias')
    return ['ssh','-T','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',host,shlex.join([*prefix,*args])]

def run_docker(args, host=None, timeout=30, input_data=None, output_limit=MAX_LINE, context=None):
    process=None
    try:
        process=subprocess.Popen(docker_command(args,host,context),stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=child_environment())
        result=queue.Queue(maxsize=1)
        def collect():
            try:
                if input_data is not None:
                    process.stdin.write(input_data);process.stdin.close()
                result.put(process.stdout.read(output_limit+1))
            except Exception: result.put(b'')
        threading.Thread(target=collect,daemon=True).start()
        try: data=result.get(timeout=timeout)
        except queue.Empty: raise RuntimeFailure('Docker unavailable or timed out') from None
        if len(data)>output_limit: raise RuntimeFailure('Docker response too large')
        if process.wait(timeout=2): raise RuntimeFailure('Docker operation failed')
        return data.decode('utf-8')
    except (OSError,subprocess.TimeoutExpired):
        raise RuntimeFailure('Docker unavailable or timed out') from None
    finally:
        if process:
            if process.poll() is None:
                process.kill();process.wait(timeout=2)
            process.stdout.close()

class Provider:
    ROUTES={'responses':'/responses','messages':'/messages','chatCompletions':'/chat/completions'}
    def __init__(self, config):
        self.url=urllib.parse.urlsplit(config.get('baseURL',''))
        if self.url.scheme!='https' or not self.url.hostname or self.url.username or self.url.password or self.url.query or self.url.fragment:
            raise RuntimeFailure('model service must be a fixed HTTPS URL')
        if self.url.path not in ('','/','/v1','/v1/'):
            raise RuntimeFailure('model service base path must be empty or /v1')
        self.api=config.get('api')
        if self.api not in self.ROUTES: raise RuntimeFailure('unsupported model API')
        self.key=config.get('apiKey','')
        self.model=config.get('model','')
        if not isinstance(self.key,str) or not self.key or len(self.key)>8192 or any(c in self.key for c in '\r\n'):
            raise RuntimeFailure('invalid model credential')
        if not isinstance(self.model,str) or not self.model or len(self.model)>256:
            raise RuntimeFailure('invalid model identifier')
    def prepare(self,path,body):
        route=self.ROUTES[self.api]
        if path not in (route,'/v1'+route) or not isinstance(body,dict): raise RuntimeFailure('model request route denied')
        # Routing/control fields must never override host configuration.
        body=dict(body)
        for key in ('base_url','baseURL','api_key','apiKey','url','headers','extra_headers','proxy','organization','project'):
            body.pop(key,None)
        body['model']=self.model
        headers={'Content-Type':'application/json','Accept':'application/json, text/event-stream'}
        if self.api=='messages': headers.update({'x-api-key':self.key,'anthropic-version':'2023-06-01'})
        else: headers['Authorization']='Bearer '+self.key
        return (self.url.path.rstrip('/')+route,body,headers)
    def freeze(self,path,body):
        path,body,headers=self.prepare(path,body)
        def inspect(value,in_tools=False,at_root=False):
            if isinstance(value,dict):
                if value.get('type')=='url':
                    raise RuntimeFailure('opaque remote source references are not supported; provide inline content')
                for key,item in value.items():
                    # Function parameter schemas name fields; those names are not input values.
                    if in_tools and key=='parameters' and isinstance(item,dict): continue
                    if key in ('file_id','file_url','image_url','audio_url','video_url','previous_response_id','container','vector_store_ids','mcp_servers','conversation'):
                        raise RuntimeFailure('opaque external content references are not supported; provide inline content')
                    if key=='type' and item in ('web_search','web_search_preview','file_search','computer_use_preview','mcp','code_interpreter'):raise RuntimeFailure('external hosted tools are not supported in this audit slice')
                    inspect(item,in_tools or (at_root and key=='tools' and isinstance(item,list)))
            elif isinstance(value,list):
                for item in value: inspect(item,in_tools)
        inspect(body,at_root=True)
        payload=json.dumps(body,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False).encode('utf-8')
        if len(payload)>1024*1024:raise RuntimeFailure('model request exceeds 1 MiB')
        return FrozenRequest(path,payload,headers,bool(body.get('stream')),hashlib.sha256(payload).hexdigest())
    def destination(self,frozen):
        return self.url._replace(path=frozen.path).geturl()
    def stream(self,path,body,revoked,admission_lock=None):
        yield from self.stream_frozen(self.freeze(path,body),revoked,admission_lock)
    def stream_frozen(self,frozen,revoked,admission_lock=None):
        path,body,headers=frozen.path,frozen.body,frozen.headers
        if revoked(): raise RuntimeFailure('task stopped')
        conn=http.client.HTTPSConnection(self.url.hostname,self.url.port or 443,timeout=30)
        started=time.monotonic()
        try:
            with admission_lock if admission_lock is not None else contextlib.nullcontext():
                if revoked(): raise RuntimeFailure('task stopped')
                conn.request('POST',path,body,headers)
            response=conn.getresponse()
            if response.status<200 or response.status>=300: raise RuntimeFailure('upstream rejected request')
            yield {'status':response.status,'contentType':'text/event-stream' if frozen.streaming else 'application/json'}
            total=0
            while not revoked():
                if time.monotonic()-started>TIMEOUT: raise RuntimeFailure('model request timed out')
                chunk=response.read1(16384) if hasattr(response,'read1') else response.read(16384)
                if not chunk: return
                total+=len(chunk)
                if total>MAX_OUTPUT: raise RuntimeFailure('model response limit exceeded')
                # Upstream response bytes are untrusted; errors never include upstream bodies.
                yield {'chunk':base64.b64encode(chunk).decode()}
            raise RuntimeFailure('task stopped')
        except RuntimeFailure: raise
        except Exception: raise RuntimeFailure('model request failed') from None
        finally: conn.close()

class Task:
    def __init__(self,task_id,instance,provider,emit,files=None,audit=None,model_policy="review"):
        try: self.task_id=str(uuid.UUID(task_id))
        except (ValueError,TypeError,AttributeError): raise RuntimeFailure('invalid task identifier') from None
        self.audit=audit or audit_runtime.RejectingBroker()
        if model_policy not in ("review","task"):raise RuntimeFailure("invalid model policy")
        self.model_policy=model_policy
        self.model_permissions={}
        self.files=files or []
        try: workspace_io.validate_files(self.files)
        except Exception: raise RuntimeFailure("invalid or restricted input files") from None
        self.instance=instance
        self.host=instance.get('host')
        self.context=instance.get("dockerContext")
        docker_command([],self.host,self.context)
        self.image=instance.get('image','')
        if not isinstance(self.image,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:/-]*@sha256:[a-f0-9]{64}',self.image): raise RuntimeFailure('image must be pinned by sha256 digest')
        self.command=instance.get('command')
        if not isinstance(self.command,list) or not 1<=len(self.command)<=64 or any(not isinstance(x,str) or not x or len(x)>4096 or '\x00' in x for x in self.command): raise RuntimeFailure('invalid adapter argv')
        if self.command[0].startswith('-'): raise RuntimeFailure('invalid adapter executable')
        self.name='travelcat-agent-'+uuid.uuid4().hex
        self.provider=provider
        self.emit=emit
        self.stopped=threading.Event()
        self.lock=threading.RLock()
        self.admission_lock=threading.Lock()
        self.cleanup_lock=threading.Lock()
        self.acp_bytes=0
        self.acp_events=0
        self.uncertain=False
        self.acp_write=threading.Lock()
        self.relay_write=threading.Lock()
        self.pending={}
        self.permissions={}
        self.next_id=0
        self.process=None
        self.relay=None
        self.session=None
        self.turn=threading.Lock()
        self.request_slots=threading.BoundedSemaphore(4)
        self.request_count=0
        self.created=False
        self.binding_id=str(uuid.uuid4());self.execution_id=None;self.artifact_baseline=None
        self.artifact_read_slot=threading.Lock();self.workspace_identity=None
    def event(self,event,data):
        with self.lock:
            if event=='state':
                if data.get('status')=='unknown': self.uncertain=True
                elif self.uncertain and data.get('status')=='failed': data={**data,'status':'unknown'}
        self.emit({'event':event,'taskId':self.task_id,'data':data})
    def create_args(self):
        return ['create','--pull=never','--log-driver=none','--name',self.name,'--network=none','--read-only','--user=65532:65532','--cap-drop=ALL','--security-opt=no-new-privileges','--cpus=2','--memory=1g','--memory-swap=1g','--pids-limit=128','--ipc=none','--tmpfs=/tmp:rw,nosuid,nodev,size=256m,mode=1777','--entrypoint=python3',self.image,'-I','-S','-c','import time; time.sleep(3600)']
    def start(self):
        if self.stopped.is_set(): raise RuntimeFailure('task stopped')
        try:
            metadata=json.loads(run_docker(['image','inspect','--format','{{json .Config.Volumes}}',self.image],self.host,context=self.context))
            if metadata: raise RuntimeFailure('images declaring volumes are not supported')
            # Name is reserved before create, so a timed out create is also cleaned up.
            with self.lock:
                if self.stopped.is_set(): raise RuntimeFailure('task stopped')
                self.created=True
                run_docker(self.create_args(),self.host,context=self.context)
                run_docker(['start',self.name],self.host,context=self.context)
            if self.stopped.is_set(): raise RuntimeFailure('task stopped')
            relay_source=Path(__file__).resolve().with_name('container_relay.py').read_text()
            self.relay=self.spawn(['exec','-i',self.name,'python3','-I','-S','-B','-u','-c',relay_source])
            self.ready=threading.Event()
            threading.Thread(target=self.read_relay,daemon=True).start()
            if not self.ready.wait(15) or self.stopped.is_set(): raise RuntimeFailure('model relay failed to start')
            if self.files: self.workspace('import',files=self.files)
            self.files=[]
            env=[]
            for key,value in {'OPENAI_API_KEY':'travelcat-placeholder','OPENAI_BASE_URL':'http://127.0.0.1:8765/v1','OPENAI_MODEL':'travelcat-model','ANTHROPIC_API_KEY':'travelcat-placeholder','ANTHROPIC_BASE_URL':'http://127.0.0.1:8765','ANTHROPIC_MODEL':'travelcat-model'}.items(): env+=['-e',key+'='+value]
            self.process=self.spawn(['exec','-i','-w','/tmp/workspace',*env,self.name,*self.command])
            threading.Thread(target=self.read_acp,daemon=True).start()
            hello=self.rpc('initialize',{'protocolVersion':1,'clientCapabilities':{'fs':{'readTextFile':False,'writeTextFile':False},'terminal':False},'clientInfo':{'name':'travel-cat','version':'1'}},30)
            if hello.get('protocolVersion')!=1: raise RuntimeFailure('unsupported ACP protocol version')
            result=self.rpc('session/new',{'cwd':'/tmp/workspace','mcpServers':[]},30)
            self.session=result.get('sessionId')
            if not isinstance(self.session,str) or not self.session: raise RuntimeFailure('adapter returned invalid session')
            threading.Thread(target=self.expire,daemon=True).start()
            threading.Thread(target=self.sweep_permissions,daemon=True).start()
            return {'sessionId':self.session,'containerName':self.name}
        except Exception:
            self.stop()
            self.cleanup()
            detail=('; container '+self.name+' requires cleanup; retry stop') if self.created else '; check Docker, image and adapter'
            raise RuntimeFailure('isolated runtime startup failed'+detail) from None
    def spawn(self,args):
        return subprocess.Popen(docker_command(args,self.host,self.context),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=child_environment())
    def send(self,process,lock,message):
        data=(json.dumps(message,separators=(',',':'))+'\n').encode()
        if len(data)>MAX_LINE: raise RuntimeFailure('message limit exceeded')
        with lock:
            if self.stopped.is_set() or not process or process.poll() is not None: raise RuntimeFailure('runtime disconnected')
            process.stdin.write(data);process.stdin.flush()
    def rpc(self,method,params,timeout=TIMEOUT):
        with self.lock:
            self.next_id+=1; rid=self.next_id; waiting=queue.Queue(maxsize=1);self.pending[rid]=waiting
        try:
            self.send(self.process,self.acp_write,{'jsonrpc':'2.0','id':rid,'method':method,'params':params})
            try: response=waiting.get(timeout=timeout)
            except queue.Empty: raise RuntimeFailure('adapter response timed out') from None
            if 'error' in response: raise RuntimeFailure('adapter request failed')
            if not isinstance(response.get('result'),dict): raise RuntimeFailure('invalid adapter response')
            return response['result']
        finally:
            with self.lock: self.pending.pop(rid,None)
    def lines(self,process,acp=False):
        while not self.stopped.is_set():
            line=process.stdout.readline(MAX_LINE+1)
            if not line: return
            if len(line)>MAX_LINE: raise RuntimeFailure('adapter output limit exceeded')
            if acp:
                self.acp_bytes+=len(line);self.acp_events+=1
                if self.acp_bytes>MAX_ACP_BYTES or self.acp_events>MAX_ACP_EVENTS: raise RuntimeFailure('task output budget exceeded')
            obj=json.loads(line)
            if not isinstance(obj,dict): raise RuntimeFailure('invalid protocol message')
            yield obj
    def read_acp(self):
        try:
            for obj in self.lines(self.process,acp=True):
                if 'method' not in obj:
                    with self.lock:
                        q=self.pending.get(obj.get('id'))
                        if q and q.empty(): q.put_nowait(obj)
                    continue
                method=obj['method'];params=obj.get('params',{})
                if not isinstance(params,dict): raise RuntimeFailure('invalid adapter params')
                if method=='session/update' and params.get('sessionId')==self.session:
                    self.event('update',params.get('update',{}))
                elif method=='session/request_permission' and 'id' in obj and params.get('sessionId')==self.session:
                    options=params.get('options',[])
                    if not isinstance(options,list) or not options or len(options)>32 or any(not isinstance(o,dict) or not isinstance(o.get('optionId'),str) for o in options): raise RuntimeFailure('invalid permission request')
                    token=uuid.uuid4().hex
                    with self.lock:
                        if any(value[0]==obj['id'] for value in self.permissions.values()): raise RuntimeFailure('duplicate permission request')
                        if len(self.permissions)>=16: raise RuntimeFailure('too many pending permissions')
                        self.permissions[token]=(obj['id'],{o['optionId'] for o in options},time.monotonic()+120)
                    permission_payload={'requestId':token,'options':options,'toolCall':params.get('toolCall',{})}
                    safe_permission_payload=audit_payload._sanitize_value(permission_payload,self.provider.key)
                    self.audit.record(self.task_id,'operation.permissionRequest',**safe_permission_payload)
                    self.event('permission',safe_permission_payload)
                elif 'id' in obj:
                    self.send(self.process,self.acp_write,{'jsonrpc':'2.0','id':obj['id'],'error':{'code':-32601,'message':'host capability denied'}})
        except Exception: pass
        finally:
            if not self.stopped.is_set():
                self.event('state',{'status':'unknown' if self.host else 'failed','message':'Adapter disconnected'})
                self.stop()
    def sweep_permissions(self):
        while not self.stopped.wait(0.5):
            with self.lock: tokens=list(self.permissions)
            for token in tokens: self.expire_permission(token)
    def expire_permission(self,request_id):
        with self.lock:
            record=self.permissions.get(request_id)
            if not record or record[2]>time.monotonic() or self.stopped.is_set(): return
            del self.permissions[request_id]
        try:
            self.send(self.process,self.acp_write,{'jsonrpc':'2.0','id':record[0],'result':{'outcome':{'outcome':'cancelled'}}})
        except Exception:
            self.event('state',{'status':'unknown' if self.host else 'failed','message':'Permission expiry delivery failed'})
            self.stop()
        finally: self.event('permissionExpired',{'requestId':request_id})
    def permission(self,request_id,option_id):
        with self.lock:
            record=self.permissions.get(request_id)
            if not record or record[2]<time.monotonic() or self.stopped.is_set(): raise RuntimeFailure('permission expired or already handled')
            if option_id not in record[1]: raise RuntimeFailure('invalid permission option')
            del self.permissions[request_id]
        self.send(self.process,self.acp_write,{'jsonrpc':'2.0','id':record[0],'result':{'outcome':{'outcome':'selected','optionId':option_id}}})
        return {}
    def prompt(self,text):
        if not isinstance(text,str) or not text or len(text.encode())>512*1024: raise RuntimeFailure('invalid prompt')
        if not self.turn.acquire(False): raise RuntimeFailure('task already has an active turn')
        try:
            with self.lock:
                self.execution_id=str(uuid.uuid4());self.artifact_baseline=None
            baseline=self.workspace('manifest')
            with self.lock:
                self.artifact_baseline=baseline
                if self.workspace_identity is not None and self.workspace_identity!=baseline.get('rootIdentity'):raise RuntimeFailure('workspace root changed')
                self.workspace_identity=baseline.get('rootIdentity')
            self.audit.record(self.task_id,'operation.artifactBaseline',bindingId=self.binding_id,executionId=self.execution_id,fileCount=len(baseline['files']),inventoryComplete=baseline['inventoryComplete'],hashComplete=baseline['hashComplete'],reason=baseline.get('reason'))
            self.event('state',{'status':'running'})
            result=self.rpc('session/prompt',{'sessionId':self.session,'prompt':[{'type':'text','text':text}]},TASK_SECONDS)
            if result.get('stopReason') not in ('end_turn','max_tokens','max_turn_requests','refusal','cancelled'): raise RuntimeFailure('invalid adapter completion')
            self.event('state',{'status':'cancelled' if result.get('stopReason')=='cancelled' else 'completed'})
            return result
        except Exception:
            self.event('state',{'status':'failed','message':'Turn failed or timed out'})
            self.stop();raise
        finally:
            with self.lock: self.permissions.clear()
            self.turn.release()
    def cancel(self):
        self.send(self.process,self.acp_write,{'jsonrpc':'2.0','method':'session/cancel','params':{'sessionId':self.session}})
        return {'requested':True}
    def read_relay(self):
        try:
            for obj in self.lines(self.relay):
                if obj.get('ready') is True: self.ready.set();continue
                if not self.request_slots.acquire(False): raise RuntimeFailure('model concurrency exceeded')
                with self.lock: self.request_count+=1
                if self.request_count>256:
                    self.request_slots.release();raise RuntimeFailure('model request budget exceeded')
                threading.Thread(target=self.forward,args=(obj,),daemon=True).start()
        except Exception: pass
        finally:
            self.ready.set()
            if not self.stopped.is_set():
                self.event('state',{'status':'unknown' if self.host else 'failed','message':'Model relay disconnected'})
                self.stop()
    def workspace(self,method,**params):
        if self.stopped.is_set(): raise RuntimeFailure('task stopped')
        if method=='import':
            files=params.get('files',[])
            workspace_io.validate_files(files)
            manifest=[]
            for file in files:
                content=base64.b64decode(file['base64'],validate=True)
                manifest.append({'name':file['name'],'bytes':len(content),'sha256':hashlib.sha256(content).hexdigest()})
            self.audit.record(self.task_id,'operation.import',phase='requested',fileCount=len(files),files=manifest)
        script=Path(__file__).with_name('workspace_io.py').read_text()
        data=json.dumps({'method':method,**params,'expectedRootIdentity':self.workspace_identity,'includeIdentity':True},separators=(',',':')).encode()
        if len(data)>workspace_io.CONTROL_LIMIT: raise RuntimeFailure('workspace input too large')
        result=json.loads(run_docker(['exec','-i',self.name,'python3','-I','-S','-c',script],self.host,5 if method in ('manifest','artifacts','export') else 30,input_data=data,output_limit=workspace_io.CONTROL_LIMIT,context=self.context))
        if self.stopped.is_set() or not isinstance(result,dict) or 'error' in result: raise RuntimeFailure('workspace operation failed')
        if method=='export':
            try:
                workspace_io.safe_name(result.get('name'))
                encoded=result['base64']
                if not isinstance(encoded,str) or len(encoded)>workspace_io.TOTAL_LIMIT*4//3+4 or len(base64.b64decode(encoded,validate=True))>workspace_io.TOTAL_LIMIT: raise ValueError()
            except Exception: raise RuntimeFailure('invalid artifact response') from None
        identity=result.get('rootIdentity')
        if not isinstance(identity,list) or len(identity)!=2 or self.workspace_identity is not None and identity!=self.workspace_identity:raise RuntimeFailure('workspace root changed or identity missing')
        self.workspace_identity=identity
        return result
    def artifact_read(self,method,expected=None,**params):
        if not self.artifact_read_slot.acquire(False):raise RuntimeFailure('artifact observation already pending')
        try:
            with self.lock:
                scope=(self.binding_id,self.execution_id);baseline=self.artifact_baseline
                if expected is not None and scope!=expected:raise RuntimeFailure('artifact caller binding is stale')
            result=self.workspace(method,**params)
            with self.lock:
                if self.stopped.is_set() or scope!=(self.binding_id,self.execution_id):raise RuntimeFailure('artifact binding changed')
            if method=='manifest':
                identity=result.get('rootIdentity')
                if not isinstance(identity,list) or len(identity)!=2:raise RuntimeFailure('workspace identity missing')
                if self.workspace_identity is not None and self.workspace_identity!=identity:raise RuntimeFailure('workspace root changed')
                self.workspace_identity=identity
                return workspace_io.changes(result,baseline,*scope)
            return {**result,'bindingId':scope[0],'executionId':scope[1]}
        finally:self.artifact_read_slot.release()
    def artifact_changes(self):return self.artifact_read('manifest')
    def model_permission(self,call_id,request_hash,allow):
        # Swift UUID.uuidString uses uppercase; identify the same UUID without
        # relaxing its task-local request hash, deadline or one-shot binding.
        try:
            canonical=str(uuid.UUID(call_id))
            if canonical!=call_id.lower(): raise ValueError()
        except (ValueError,TypeError,AttributeError):
            raise RuntimeFailure('model permission stale or mismatched') from None
        call_id=canonical
        with self.lock:
            entry=self.model_permissions.get(call_id)
            if not entry or entry['hash']!=request_hash or entry['event'].is_set() or time.monotonic()>entry['deadline'] or self.stopped.is_set():
                raise RuntimeFailure('model permission stale or mismatched')
            entry['allow']=allow is True;entry['event'].set()
        return {}
    def authorize_model(self,call_id,frozen):
        allowed=self.model_policy=='task'
        if not allowed:
            entry={'hash':frozen.request_hash,'event':threading.Event(),'allow':False,'deadline':time.monotonic()+120}
            with self.lock:self.model_permissions[call_id]=entry
            try:
                self.event('modelApproval',{'callId':call_id,'requestHash':frozen.request_hash,'destination':audit_payload.sanitize(self.provider.destination(frozen),self.provider.key),'model':audit_payload.sanitize(self.provider.model,self.provider.key)})
                deadline=entry['deadline']
                while not entry['event'].wait(.1):
                    if self.stopped.is_set() or time.monotonic()>deadline:break
                allowed=entry['event'].is_set() and entry['allow'] and not self.stopped.is_set()
            finally:
                with self.lock:self.model_permissions.pop(call_id,None)
        self.audit.record(self.task_id,'model.decision',call_id,requestHash=frozen.request_hash,allow=allowed,policy=self.model_policy)
        if not allowed:raise RuntimeFailure('model submission denied or permission expired')
    def relay_keepalive(self,rid,finished):
        # Control-only activity: never causes HTTP headers/body to be released.
        while not finished.wait(KEEPALIVE_SECONDS):
            try:self.send(self.relay,self.relay_write,{'id':rid,'keepalive':True})
            except Exception:return
    def forward(self,obj):
        rid=obj.get('id');call_id=str(uuid.uuid4());finished=threading.Event()
        try:
            if not isinstance(rid,str) or len(rid)>64: raise RuntimeFailure('invalid relay request')
            threading.Thread(target=self.relay_keepalive,args=(rid,finished),daemon=True).start()
            frozen=self.provider.freeze(obj.get('path'),obj.get('body'))
            original_body=frozen.body.decode('utf-8')
            audit_body=audit_payload.sanitize(original_body,self.provider.key)
            self.audit.record(self.task_id,'model.request',call_id,body=audit_body,bodyRedacted=audit_body!=original_body,destination=audit_payload.sanitize(self.provider.destination(frozen),self.provider.key),model=audit_payload.sanitize(self.provider.model,self.provider.key),api=self.provider.api,requestHash=frozen.request_hash,bytes=len(frozen.body))
            self.authorize_model(call_id,frozen)
            capture=audit_payload.ResponseAudit(self.provider.key);sequence=0;status=None
            fragments=[];response_metadata=None
            for item in self.provider.stream_frozen(frozen,lambda:self.stopped.is_set() or self.audit.failed,self.admission_lock):
                if 'status' in item:status=item['status'];response_metadata=item
                if 'chunk' in item:fragments.extend(capture.feed(base64.b64decode(item['chunk'])))
            fragments.extend(capture.finish())
            # Bounded full-response buffering prevents semantic SSE delta fragments
            # from reconstructing the credential after ordinary byte redaction.
            if capture.semantic_secret_detected():
                raise RuntimeFailure('response withheld: configured credential detected in decoded content deltas')
            if response_metadata:self.send(self.relay,self.relay_write,{'id':rid,**response_metadata})
            for text in fragments:
                self.audit.record(self.task_id,'model.response',call_id,text=text,sequence=sequence);sequence+=1
                self.send(self.relay,self.relay_write,{'id':rid,'chunk':base64.b64encode(text.encode('utf-8')).decode()})
            self.audit.record(self.task_id,'model.completed',call_id,usage=capture.usage(),status=status,complete=True)
            self.send(self.relay,self.relay_write,{'id':rid,'done':True})
        except Exception as error:
            try:self.audit.record(self.task_id,'model.failed',call_id,reason=str(error) if isinstance(error,(RuntimeFailure,audit_runtime.AuditFailure,codex_native.NativeFailure)) else 'model request failed')
            except Exception:
                # Receipt failure revokes admission AND destroys owned processes/container.
                # Unconfirmed removal retains created=True so a later stop can retry.
                self.stop()
            try: self.send(self.relay,self.relay_write,{'id':rid,'error':'model request failed'})
            except Exception: pass
        finally:
            finished.set()
            self.request_slots.release()
    def expire(self):
        if not self.stopped.wait(TASK_SECONDS):
            self.event('state',{'status':'failed','message':'Task time limit reached'});self.stop()
    def stop(self):
        with self.admission_lock, self.lock:
            self.stopped.set();self.permissions.clear()
            for q in self.pending.values():
                if q.empty(): q.put_nowait({'error':True})
        self.cleanup()
        return {'stopped':not self.created}
    def cleanup(self):
        with self.cleanup_lock:
            self._cleanup()
    def _cleanup(self):
        for process in (self.process,self.relay):
            if process:
                try:
                    process.terminate()
                    try: process.wait(timeout=2)
                    except subprocess.TimeoutExpired: process.kill();process.wait(timeout=2)
                except OSError: pass
                for stream in (process.stdin,process.stdout):
                    try: stream.close()
                    except (OSError,ValueError): pass
        if self.created:
            try:
                run_docker(['rm','-f',self.name],self.host,15,context=self.context)
                self.created=False
            except RuntimeFailure:
                self.event('state',{'status':'unknown','message':'Container '+self.name+' cleanup not confirmed; inspect the configured Docker host'})
        return {}

class Controller:
    def __init__(self):
        self.tasks={};self.probes={};self.lock=threading.Lock();self.output_lock=threading.Lock();self.shutting_down=False;self.output_broken=False
        self.audit=audit_runtime.AuditBroker(self.emit)
        self.native=codex_native.CodexNativeController(self.emit, audit=self.audit)
    def emit(self,obj):
        with self.output_lock:
            if self.output_broken: return
            try:
                sys.stdout.write(json.dumps(obj,ensure_ascii=False,separators=(',',':'))+'\n');sys.stdout.flush()
            except (OSError,ValueError):
                self.output_broken=True
                # Avoid an interpreter-finalization flush error on a closed UI pipe.
                try:
                    with open(os.devnull,'w') as sink: os.dup2(sink.fileno(),sys.stdout.fileno())
                except (OSError,ValueError,TypeError): pass
    def handle(self,obj):
        rid=obj.get('id')
        try:
            if not isinstance(rid,str) or not isinstance(obj.get('params'),dict): raise RuntimeFailure('invalid command')
            method=obj.get('method');p=obj['params']
            if isinstance(method,str) and method.startswith('native_'):
                with self.lock:
                    if self.shutting_down: raise RuntimeFailure('controller stopping')
                result=self.native.handle(method,p)
            elif method=='audit_ack':
                result={'accepted':self.audit.ack(p.get('receiptId'),p.get('accepted'))}
            elif method=='scan_local':
                result=runtime_discovery.scan_local()
            elif method=='probe':
                try: probe_id=str(uuid.UUID(p.get('probeId','')))
                except (ValueError,TypeError,AttributeError): raise RuntimeFailure('invalid probe identifier') from None
                context=p.get('dockerContext');image=p.get('image')
                inventory=runtime_discovery.scan_local()
                if not any(item['name']==context and item['local'] and item['available'] for item in inventory['contexts']):
                    raise RuntimeFailure('selected local Docker context unavailable')
                if not any(item['context']==context and item['ref']==image for item in inventory['images']):
                    raise RuntimeFailure('selected pinned image unavailable')
                placeholder=Provider({'baseURL':'https://127.0.0.1/v1','api':'responses','model':'probe-only','apiKey':'probe-only'})
                probe=Task(probe_id,{'image':image,'command':p.get('command'),'dockerContext':context},
                           placeholder,lambda event:None,files=[],audit=audit_runtime.RejectingBroker())
                with self.lock:
                    if self.shutting_down: raise RuntimeFailure('controller stopping')
                    if probe_id in self.probes or len(self.probes)>=4: raise RuntimeFailure('probe exists or probe limit reached')
                    self.probes[probe_id]=probe
                compatible=False
                try:
                    probe.start()
                    compatible=True
                except Exception:
                    pass  # Task.start attempts cleanup; retain an uncertain container below.
                if compatible:
                    try: cleanup=probe.stop().get('stopped') is True
                    except Exception: cleanup=False
                else:
                    cleanup=not probe.created
                if cleanup:
                    with self.lock: self.probes.pop(probe_id,None)
                result={'probeId':probe_id,'compatible':compatible and cleanup,
                        'cleanupConfirmed':cleanup,
                        'message':'ACP handshake and cleanup confirmed' if compatible and cleanup else
                                  ('Container cleanup unconfirmed' if not cleanup else 'ACP handshake failed')}
                if not cleanup: result['containerName']=probe.name
            elif method=='probe_cleanup':
                try: probe_id=str(uuid.UUID(p.get('probeId','')))
                except (ValueError,TypeError,AttributeError): raise RuntimeFailure('invalid probe identifier') from None
                with self.lock: probe=self.probes.get(probe_id)
                if not probe: raise RuntimeFailure('unknown probe')
                try: cleanup=probe.stop().get('stopped') is True
                except Exception: cleanup=False
                if cleanup:
                    with self.lock: self.probes.pop(probe_id,None)
                result={'probeId':probe_id,'cleanupConfirmed':cleanup}
                if not cleanup: result['containerName']=probe.name
            elif method=='discover':
                try:
                    run_docker(['info','--format','{{.ServerVersion}}'],p.get('host'),15,context=p.get('dockerContext'))
                    images=run_docker(['image','ls','--digests','--format','{{.Repository}}@{{.Digest}}'],p.get('host'),15,context=p.get('dockerContext')).splitlines()
                    result={'docker':True,'images':[x for x in images if '@sha256:' in x][:200],'message':'Docker available; images require adapter compatibility checks'}
                except RuntimeFailure: result={'docker':False,'images':[],'message':'Docker unavailable or SSH connection failed'}
            elif method=='start':
                task=Task(p['taskId'],p['instance'],Provider(p['provider']),self.emit,p.get('files'),audit=self.audit,model_policy=p.get('modelPolicy','review'))
                with self.lock:
                    if self.shutting_down: raise RuntimeFailure('controller stopping')
                    if task.task_id in self.tasks or len(self.tasks)>=8: raise RuntimeFailure('task exists or task limit reached')
                    self.tasks[task.task_id]=task
                try:
                    self.audit.record(task.task_id,'operation.start',phase='requested',modelPolicy=task.model_policy,image=task.image,command=[audit_payload.sanitize(arg,task.provider.key) for arg in task.command],host=task.host,dockerContext=task.context,sandbox={'network':'none','readOnly':True,'user':'65532:65532','capabilities':'ALL dropped','noNewPrivileges':True,'cpus':2,'memoryMiB':1024,'memorySwapMiB':1024,'pids':128,'ipc':'none','tmpfs':'/tmp:rw,nosuid,nodev,size=256m,mode=1777','hostMounts':[],'dockerSocketMounted':False})
                    if task.model_policy=='task':self.audit.record(task.task_id,'policy.taskGrant',destination=audit_payload.sanitize(task.provider.url.geturl(),task.provider.key),destinationScope='fixed base URL and configured API route',api=task.provider.api,model=audit_payload.sanitize(task.provider.model,task.provider.key),fileCount=len(task.files))
                    result=task.start()
                except Exception:
                    with self.lock:
                        if not task.created: self.tasks.pop(task.task_id,None)
                    raise
            else:
                with self.lock: task=self.tasks.get(str(uuid.UUID(p.get('taskId',''))))
                if not task: raise RuntimeFailure('unknown task')
                if method in ('permission','stop','export','cancel'):
                    if method=='stop':task.stopped.set()
                    details={'phase':'requested'}
                    if method=='permission':details.update(requestId=p.get('requestId'),optionId=p.get('optionId'))
                    if method=='export':details['path']=p.get('path')
                    try:self.audit.record(task.task_id,'operation.'+method,**details)
                    except Exception:
                        if method=='stop':task.stop()
                        raise
                if method=='model_permission': result=task.model_permission(p.get('callId'),p.get('requestHash'),p.get('allow'))
                elif method=='prompt': result=task.prompt(p.get('text'))
                elif method=='artifact_changes':result=task.artifact_changes()
                elif method=='artifacts': result=task.artifact_read('artifacts')
                elif method=='export': result=task.artifact_read('export',expected=(p.get('bindingId'),p.get('executionId')) if 'bindingId' in p else None,path=p.get('path'))
                elif method=='cancel': result=task.cancel()
                elif method=='permission': result=task.permission(p.get('requestId'),p.get('optionId'))
                elif method=='stop':
                    result=task.stop()
                    with self.lock:
                        if result.get('stopped'): self.tasks.pop(task.task_id,None)
                else: raise RuntimeFailure('unknown method')
            self.emit({'id':rid,'result':result})
        except Exception as error:
            response={'id':rid,'error':str(error) if isinstance(error,(RuntimeFailure,audit_runtime.AuditFailure,codex_native.NativeFailure)) else 'runtime command failed'}
            if obj.get('method') in ('start','probe'):
                name='taskId' if obj.get('method')=='start' else 'probeId'
                try: requested_id=str(uuid.UUID(obj.get('params',{}).get(name,'')))
                except (ValueError,TypeError,AttributeError): requested_id=None
                with self.lock:
                    response['taskRetained']=requested_id in (self.tasks if name=='taskId' else self.probes)
            self.emit(response)
    def run(self):
        slots=threading.BoundedSemaphore(24)
        def work(obj):
            try: self.handle(obj)
            finally: slots.release()
        try:
            while True:
                line=sys.stdin.buffer.readline(workspace_io.CONTROL_LIMIT+1)
                if not line: break
                if len(line)>workspace_io.CONTROL_LIMIT: break
                try: obj=json.loads(line)
                except Exception: continue
                if not isinstance(obj,dict): continue
                if obj.get('method') in ('audit_ack','model_permission'):
                    self.handle(obj);continue
                if not slots.acquire(False):
                    self.emit({'id':obj.get('id'),'error':'controller busy'});continue
                threading.Thread(target=work,args=(obj,),daemon=False).start()
        finally:
            with self.lock:
                self.shutting_down=True
                tasks=list(self.tasks.values())+list(self.probes.values())
            self.native.close()
            for task in tasks:
                try: task.stop()
                except Exception: pass  # One cleanup failure must not skip the remaining tasks.

if __name__=='__main__':
    if sys.version_info<(3,11):
        sys.stderr.write('Python 3.11 or later required\n');sys.exit(1)
    controller=Controller()
    def shutdown(signum,frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM,shutdown)
    signal.signal(signal.SIGINT,shutdown)
    controller.run()
