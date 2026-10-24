import sys, pathlib, unittest, json, uuid
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'Sources/TravelCatApp/Resources/AgentRuntime'))
import sidecar

def acknowledge_audit(controller):
    # Explicit test-only host: exercise real receipt protocol without a native journal.
    def emit(event):
        if event.get('event')=='audit':controller.audit.ack(event['data']['receiptId'],True)
        else:controller.emit(event)
    controller.audit=sidecar.audit_runtime.AuditBroker(emit,timeout=.5)

def acknowledged_test_broker():
    # Explicit test host receipt; production never installs this broker.
    broker=sidecar.audit_runtime.AuditBroker(lambda event:broker.ack(event['data']['receiptId'],True),timeout=.5)
    return broker

class PolicyTests(unittest.TestCase):
    def provider(self, **kw):
        return sidecar.Provider(dict(baseURL='https://example.com/v1', apiKey='canary-secret', model='fixed-model', api='responses', **kw))
    def test_fixed_route_model_and_auth(self):
        p = self.provider()
        path, body, headers = p.prepare('/v1/responses', {'model':'attacker','input':'hello'})
        self.assertEqual(path, '/v1/responses')
        self.assertEqual(body['model'], 'fixed-model')
        self.assertEqual(headers['Authorization'], 'Bearer canary-secret')
    def test_arbitrary_routes_rejected(self):
        for route in ['https://evil.com/v1/responses','/v1/responses?url=x','/v1/messages','/../responses']:
            with self.assertRaises(sidecar.RuntimeFailure): self.provider().prepare(route,{})
    def test_tool_parameter_schema_can_describe_url_fields_without_allowing_url_inputs(self):
        schema={'type':'object','properties':{'image_url':{'type':'string'},'audio_url':{'type':'string'}}}
        body={'input':[{'role':'user','content':[{'type':'input_text','text':'hello'}]}],
              'tools':[{'type':'function','name':'group','tools':[{'type':'function','name':'inspect','parameters':schema}]}]}
        self.provider().freeze('/v1/responses',body)
        body['input'][0]['content'].append({'type':'input_image','image_url':'https://example.com/private.png'})
        with self.assertRaisesRegex(sidecar.RuntimeFailure,'opaque external content references'):
            self.provider().freeze('/v1/responses',body)
        body['input'][0]['content'].pop()
        body['input'][0]['parameters']={'image_url':'https://example.com/private.png'}
        with self.assertRaisesRegex(sidecar.RuntimeFailure,'opaque external content references'):
            self.provider().freeze('/v1/responses',body)
        del body['input'][0]['parameters']
        body['tools'].append({'type':'web_search'})
        with self.assertRaisesRegex(sidecar.RuntimeFailure,'external hosted tools'):
            self.provider().freeze('/v1/responses',body)
    def test_insecure_provider_rejected(self):
        for url in ['http://example.com','https://u:p@example.com','https://example.com/?x=y']:
            with self.assertRaises(sidecar.RuntimeFailure): sidecar.Provider(dict(baseURL=url,apiKey='x',model='m',api='responses'))
    def test_container_plan_security(self):
        inst = dict(image='example/agent@sha256:'+'a'*64, command=['agent','--stdio'])
        t=sidecar.Task(str(uuid.uuid4()), inst, self.provider(), lambda *a:None)
        plan=t.create_args()
        for value in ['--network=none','--read-only','--cap-drop=ALL','--security-opt=no-new-privileges','--user=65532:65532']:
            self.assertIn(value, plan)
        self.assertNotIn('canary-secret', str(plan))
        self.assertNotIn('-v', plan)
    def test_image_digest_required(self):
        with self.assertRaises(sidecar.RuntimeFailure): sidecar.Task(str(uuid.uuid4()),dict(image='latest',command=['agent']),self.provider(),lambda *a:None)
    def test_ssh_quotes_argv(self):
        command=sidecar.docker_command(['exec','name','echo','$(touch /tmp/no)'], 'my-host')
        self.assertEqual(command[:5],['ssh','-T','-o','BatchMode=yes','-o'])
        self.assertIn("'$(touch /tmp/no)'",command[-1])
        with self.assertRaises(sidecar.RuntimeFailure): sidecar.docker_command([], '-oProxyCommand=evil')
    def test_permission_stale_and_duplicate(self):
        t=sidecar.Task(str(uuid.uuid4()),dict(image='x@sha256:'+'a'*64,command=['agent']),self.provider(),lambda *a:None)
        with self.assertRaises(sidecar.RuntimeFailure): t.permission('missing','ok')
    def test_redirect_never_followed_and_error_body_hidden(self):
        class Response:
            status=302
            def read(self,n): return b'canary-secret'
        class Connection:
            def __init__(self,*a,**kw): pass
            def request(self,*a,**kw): pass
            def getresponse(self): return Response()
            def close(self): pass
        with patch.object(sidecar.http.client,'HTTPSConnection',Connection):
            with self.assertRaisesRegex(sidecar.RuntimeFailure,'upstream rejected'):
                list(self.provider().stream('/v1/responses',{},lambda:False))


    def test_docker_context_is_explicit_and_cannot_inject_options(self):
        self.assertEqual(sidecar.docker_command(['info'],context='colima-agent-acceptance'),['docker','--context','colima-agent-acceptance','info'])
        remote=sidecar.docker_command(['info'],'host',context='test')
        self.assertEqual(remote[-1],'docker --context test info')
        for context in ['--host=evil','x;sh','unix:///tmp/socket','a b']:
            with self.assertRaises(sidecar.RuntimeFailure):sidecar.docker_command([],context=context)

class ProcessTests(unittest.TestCase):
    def task(self):
        return sidecar.Task(str(uuid.uuid4()),dict(image='x@sha256:'+'a'*64,command=['agent']),sidecar.Provider(dict(baseURL='https://example.com/v1',apiKey='canary',model='m',api='responses')),lambda e:self.events.append(e),audit=acknowledged_test_broker())
    def setUp(self): self.events=[]
    def test_actual_acp_stdio_permissions_updates_cancel(self):
        import subprocess, threading
        t=self.task(); t.session='session'
        script='''import sys,json
for line in sys.stdin:
 o=json.loads(line)
 if o.get('method')=='initialize': print(json.dumps({'id':o['id'],'result':{'protocolVersion':1}}),flush=True)
 elif o.get('method')=='session/prompt':
  prompt=o['id']
  print(json.dumps({'method':'session/update','params':{'sessionId':'session','update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'hello'}}}}),flush=True)
  print(json.dumps({'id':90,'method':'session/request_permission','params':{'sessionId':'session','options':[{'optionId':'yes','name':'Allow','kind':'allow_once'}],'toolCall':{}}}),flush=True)
 elif o.get('id')==90:
  print(json.dumps({'id':prompt,'result':{'stopReason':'end_turn'}}),flush=True)
'''
        t.process=subprocess.Popen([sys.executable,'-u','-c',script],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        threading.Thread(target=t.read_acp,daemon=True).start()
        self.assertEqual(t.rpc('initialize',{}),{'protocolVersion':1})
        result=[]
        worker=threading.Thread(target=lambda:result.append(t.prompt('hello')));worker.start()
        import time
        deadline=time.monotonic()+3
        while not any(e['event']=='permission' for e in self.events) and time.monotonic()<deadline: time.sleep(.01)
        event=next(e for e in self.events if e['event']=='permission')
        token=event['data']['requestId']
        with self.assertRaises(sidecar.RuntimeFailure): t.permission(token,'invalid')
        t.permission(token,'yes')
        with self.assertRaises(sidecar.RuntimeFailure): t.permission(token,'yes')
        worker.join(3)
        self.assertEqual(result,[{'stopReason':'end_turn'}])
        self.assertTrue(any(e['event']=='update' for e in self.events))
        t.stop();t.process.wait(3)
    def test_process_exit_unblocks_pending_request(self):
        import subprocess,threading,time
        t=self.task()
        t.process=subprocess.Popen([sys.executable,'-c','import sys; sys.stdin.readline()'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        threading.Thread(target=t.read_acp,daemon=True).start()
        started=time.monotonic()
        with self.assertRaises(sidecar.RuntimeFailure): t.rpc('initialize',{},10)
        self.assertLess(time.monotonic()-started,3)
        t.process.wait(3)
    def test_start_failure_cleans_owned_container(self):
        t=self.task();calls=[]
        def run(args,*a,**kw):
            calls.append(args)
            if args[0]=='start': raise sidecar.RuntimeFailure('failure')
            return 'null' if args[0]=='image' else ''
        with patch.object(sidecar,'run_docker',run):
            with self.assertRaises(sidecar.RuntimeFailure): t.start()
        self.assertEqual(calls[-1],['rm','-f',t.name])
    def test_subprocess_environment_excludes_host_credentials(self):
        import os
        with patch.dict(os.environ,{'OPENAI_API_KEY':'host-secret','HTTPS_PROXY':'http://evil'}):
            env=sidecar.child_environment()
            self.assertNotIn('OPENAI_API_KEY',env)
            self.assertNotIn('HTTPS_PROXY',env)
    def test_stop_before_start_cannot_create_container(self):
        t=self.task();t.stop()
        with patch.object(sidecar,'run_docker') as run:
            with self.assertRaises(sidecar.RuntimeFailure): t.start()
            run.assert_not_called()

    def test_startup_full_handshake_and_cancel_confirmation(self):
        import subprocess,threading,time
        t=self.task();commands=[]
        relay="import json,time; print(json.dumps({'ready':True}),flush=True);time.sleep(30)"
        acp="""import sys,json
for line in sys.stdin:
 o=json.loads(line);m=o.get('method')
 if m=='initialize': print(json.dumps({'id':o['id'],'result':{'protocolVersion':1}}),flush=True)
 elif m=='session/new': print(json.dumps({'id':o['id'],'result':{'sessionId':'real-stdio-session'}}),flush=True)
 elif m=='session/prompt': prompt=o['id']
 elif m=='session/cancel': print(json.dumps({'id':prompt,'result':{'stopReason':'cancelled'}}),flush=True)
"""
        def spawn(args):
            commands.append(args)
            return subprocess.Popen([sys.executable,'-u','-c',relay if args[-2]=='-c' else acp],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        def docker(args,*a,**kw): return 'null' if args[0]=='image' else ''
        with patch.object(sidecar,'run_docker',docker),patch.object(t,'spawn',spawn):
            self.assertEqual(t.start(),{'sessionId':'real-stdio-session'})
            self.assertNotIn('canary',str(commands))
            self.assertIn('OPENAI_API_KEY=travelcat-placeholder',str(commands))
            results=[];worker=threading.Thread(target=lambda:results.append(t.prompt('wait')));worker.start()
            deadline=time.monotonic()+3
            while not t.turn.locked() and time.monotonic()<deadline: time.sleep(.01)
            # Wait until the prompt request has been written before cancellation.
            with t.acp_write: pass
            self.assertFalse(any(e['data'].get('status')=='cancelled' for e in self.events))
            self.assertEqual(t.cancel(),{'requested':True});worker.join(3)
            self.assertEqual(results,[{'stopReason':'cancelled'}])
            t.stop()
    def test_image_declared_volume_fails_before_create(self):
        t=self.task()
        with patch.object(sidecar,'run_docker',return_value='{"/data":{}}') as run:
            with self.assertRaises(sidecar.RuntimeFailure): t.start()
        self.assertEqual(len(run.call_args_list),1)
    def test_cancel_without_confirmation_does_not_emit_cancelled(self):
        t=self.task()
        with patch.object(t,'send'):
            self.assertEqual(t.cancel(),{'requested':True})
        self.assertEqual(self.events,[])

    def test_missing_stop_reason_does_not_report_completed(self):
        t=self.task()
        with patch.object(t,'rpc',return_value={}):
            with self.assertRaises(sidecar.RuntimeFailure): t.prompt('hello')
        self.assertFalse(any(e['data'].get('status')=='completed' for e in self.events))

class RelayIntegrationTests(unittest.TestCase):
    def test_http_request_crosses_stdio_and_stream_returns(self):
        import subprocess,threading,http.client,base64,os
        runtime=str(pathlib.Path(sidecar.__file__).parent)
        script='''import sys,threading
sys.path.insert(0,sys.argv[1])
import container_relay as r
s=r.Server(('127.0.0.1',0),r.Handler)
s.connections=threading.BoundedSemaphore(8)
threading.Thread(target=r.responses,daemon=True).start()
r.emit({'port':s.server_port})
s.serve_forever()
'''
        process=subprocess.Popen([sys.executable,'-u','-c',script,runtime],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
        try:
            port=json.loads(process.stdout.readline())['port'];result=[]
            def request():
                conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
                conn.request('POST','/v1/responses',json.dumps({'model':'alias','input':'hello'}),{'Content-Type':'application/json','Authorization':'Bearer placeholder'})
                response=conn.getresponse();result.append((response.status,response.read()));conn.close()
            worker=threading.Thread(target=request);worker.start()
            item=json.loads(process.stdout.readline())
            self.assertEqual(item['path'],'/v1/responses');self.assertNotIn('headers',item)
            for data in [{'status':200,'contentType':'text/event-stream'},{'chunk':base64.b64encode(b'data: hello\n\n').decode()},{'done':True}]:
                process.stdin.write((json.dumps({'id':item['id'],**data})+'\n').encode());process.stdin.flush()
            worker.join(5)
            self.assertEqual(result,[(200,b'data: hello\n\n')])
            conn=http.client.HTTPConnection('127.0.0.1',port,timeout=5)
            conn.request('POST','https://evil.example',b'{}',{'Content-Type':'application/json'})
            self.assertEqual(conn.getresponse().status,403);conn.close()
        finally:
            process.terminate();process.wait(3);process.stdin.close();process.stdout.close()
    def test_host_injects_secret_without_forwarding_client_route_controls(self):
        captured={}
        class Response:
            status=200
            chunks=[b'data: hello\n\n',b'']
            def read1(self,n): return self.chunks.pop(0)
        class Connection:
            def __init__(self,*a,**kw): captured['destination']=a
            def request(self,method,path,body,headers): captured.update(method=method,path=path,body=json.loads(body),headers=headers)
            def getresponse(self): return Response()
            def close(self): pass
        p=sidecar.Provider(dict(baseURL='https://provider.example/v1',api='messages',apiKey='canary-secret',model='fixed'))
        with patch.object(sidecar.http.client,'HTTPSConnection',Connection):
            chunks=list(p.stream('/v1/messages',{'model':'untrusted','url':'https://evil','headers':{'x-api-key':'evil'},'stream':True},lambda:False))
        self.assertEqual(captured['headers']['x-api-key'],'canary-secret')
        self.assertEqual(captured['destination'][0],'provider.example')
        self.assertEqual(captured['body']['model'],'fixed')
        self.assertNotIn('url',captured['body']);self.assertNotIn('headers',captured['body'])
        self.assertNotIn('canary-secret',str(chunks))

class LifecycleRegressions(unittest.TestCase):
    task=ProcessTests.task
    setUp=ProcessTests.setUp
    def test_stop_waits_for_inflight_create_then_removes(self):
        import threading,time
        t=self.task();entered=threading.Event();release=threading.Event();exists=set();calls=[]
        def docker(args,*a,**kw):
            calls.append(args[0])
            if args[0]=='image': return 'null'
            if args[0]=='create':
                entered.set();release.wait(3);exists.add(t.name)
            if args[0]=='rm': exists.discard(t.name)
            return ''
        def start():
            try:t.start()
            except sidecar.RuntimeFailure:pass
        with patch.object(sidecar,'run_docker',docker),patch.object(t,'spawn',side_effect=sidecar.RuntimeFailure('test')):
            worker=threading.Thread(target=start);worker.start();self.assertTrue(entered.wait(2))
            stopper=threading.Thread(target=t.stop);stopper.start();time.sleep(.03)
            release.set();worker.join(3);stopper.join(3)
        self.assertFalse(worker.is_alive());self.assertFalse(stopper.is_alive());self.assertEqual(exists,set())
        self.assertGreater(calls.index('rm'),calls.index('create'))
    def test_revoked_provider_does_not_connect_or_submit(self):
        p=self.task().provider
        with patch.object(sidecar.http.client,'HTTPSConnection') as connection:
            with self.assertRaises(sidecar.RuntimeFailure): list(p.stream('/responses',{},lambda:True))
            connection.assert_not_called()
    def test_revoked_after_connection_does_not_submit(self):
        import threading
        revoked=threading.Event();connection=unittest.mock.Mock()
        def connect(*a,**kw):revoked.set();return connection
        with patch.object(sidecar.http.client,'HTTPSConnection',connect):
            with self.assertRaises(sidecar.RuntimeFailure):list(self.task().provider.stream('/responses',{},revoked.is_set))
        connection.request.assert_not_called()
    def test_cumulative_acp_budget_fails_closed(self):
        import io
        t=self.task();process=unittest.mock.Mock();process.stdout=io.BytesIO(b'{}\n'*20)
        with patch.object(sidecar,'MAX_ACP_EVENTS',3):
            with self.assertRaises(sidecar.RuntimeFailure):list(t.lines(process,acp=True))
    def test_remote_unknown_not_overwritten_by_prompt_failure(self):
        t=self.task();t.host='test-host'
        t.event('state',{'status':'unknown','message':'disconnected'})
        with patch.object(t,'rpc',side_effect=sidecar.RuntimeFailure('failed')):
            with self.assertRaises(sidecar.RuntimeFailure):t.prompt('hello')
        self.assertEqual(self.events[-1]['data']['status'],'unknown')
    def test_permission_expiry_cancels_runtime_and_emits_expiry(self):
        import time
        t=self.task();t.permissions['token']=(123,{'yes'},time.monotonic()-1)
        with patch.object(t,'send') as send:t.expire_permission('token')
        self.assertNotIn('token',t.permissions)
        self.assertEqual(send.call_args.args[2]['result'],{'outcome':{'outcome':'cancelled'}})
        self.assertEqual(self.events[-1]['event'],'permissionExpired')

    def test_cumulative_acp_byte_budget(self):
        import io
        t=self.task();process=unittest.mock.Mock();process.stdout=io.BytesIO(b'{"text":"abc"}\n'*5)
        with patch.object(sidecar,'MAX_ACP_BYTES',20):
            with self.assertRaises(sidecar.RuntimeFailure):list(t.lines(process,acp=True))
    def test_request_admission_serializes_stop(self):
        import threading,time
        t=self.task();entered=threading.Event();release=threading.Event();requests=[]
        class Response:
            status=200
            def read(self,n):return b''
        class Connection:
            def __init__(self,*a,**kw):pass
            def request(self,*a):requests.append(a);entered.set();release.wait(2)
            def getresponse(self):return Response()
            def close(self):pass
        def forward():
            try:list(t.provider.stream('/responses',{},t.stopped.is_set,t.admission_lock))
            except sidecar.RuntimeFailure:pass
        with patch.object(sidecar.http.client,'HTTPSConnection',Connection):
            worker=threading.Thread(target=forward);worker.start();self.assertTrue(entered.wait(1))
            stopper=threading.Thread(target=t.stop);stopper.start();time.sleep(.02)
            release.set();worker.join(2);stopper.join(2)
            with self.assertRaises(sidecar.RuntimeFailure):list(t.provider.stream('/responses',{},t.stopped.is_set,t.admission_lock))
        self.assertEqual(len(requests),1);self.assertTrue(t.stopped.is_set())
    def test_controller_eof_waits_for_inflight_create_cleanup(self):
        import subprocess,tempfile,time
        with tempfile.TemporaryDirectory() as directory:
            script="""import sys,time,pathlib
sys.path.insert(0,sys.argv[1])
import sidecar
root=pathlib.Path(sys.argv[2])
def docker(args,*a,**kw):
 if args[0]=='image':return 'null'
 if args[0]=='create':
  (root/'started').touch();time.sleep(.15);(root/'container').touch()
 if args[0]=='start':raise sidecar.RuntimeFailure('test startup')
 if args[0]=='rm':(root/'container').unlink(missing_ok=True)
 return ''
sidecar.run_docker=docker
sidecar.Controller().run()
"""
            process=subprocess.Popen([sys.executable,'-u','-c',script,str(pathlib.Path(sidecar.__file__).parent),directory],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            message={'id':'start','method':'start','params':{'taskId':str(uuid.uuid4()),'instance':{'image':'x@sha256:'+'a'*64,'command':['agent']},'provider':{'baseURL':'https://example.com/v1','apiKey':'test','model':'m','api':'responses'}}}
            process.stdin.write((json.dumps(message)+'\n').encode());process.stdin.flush()
            audit=json.loads(process.stdout.readline())
            process.stdin.write((json.dumps({'id':'ack','method':'audit_ack','params':{'receiptId':audit['data']['receiptId'],'accepted':True}})+'\n').encode());process.stdin.flush()
            deadline=time.monotonic()+2
            while not pathlib.Path(directory,'started').exists() and time.monotonic()<deadline:time.sleep(.01)
            self.assertTrue(pathlib.Path(directory,'started').exists())
            process.stdin.close();process.stdin=None
            out,err=process.communicate(timeout=4)
            self.assertEqual(process.returncode,0,err)
            self.assertFalse(pathlib.Path(directory,'container').exists())

    def test_cleanup_failure_remains_retryable(self):
        t=self.task();t.created=True
        with patch.object(sidecar,'run_docker',side_effect=[sidecar.RuntimeFailure('unreachable'),'']):
            self.assertEqual(t.stop(),{'stopped':False})
            self.assertTrue(t.created)
            self.assertEqual(t.stop(),{'stopped':True})
        self.assertFalse(t.created)
    def test_controller_keeps_task_until_cleanup_confirmed(self):
        t=self.task();t.created=True;c=sidecar.Controller();c.tasks[t.task_id]=t;output=[];c.emit=output.append;acknowledge_audit(c)
        command={'id':'stop','method':'stop','params':{'taskId':t.task_id}}
        with patch.object(sidecar,'run_docker',side_effect=[sidecar.RuntimeFailure('unreachable'),'']):
            c.handle(command)
            self.assertIn(t.task_id,c.tasks);self.assertEqual(output[-1]['result'],{'stopped':False})
            c.handle(command)
            self.assertNotIn(t.task_id,c.tasks);self.assertEqual(output[-1]['result'],{'stopped':True})
    def test_start_failure_keeps_unconfirmed_container_tracked(self):
        c=sidecar.Controller();output=[];c.emit=output.append;acknowledge_audit(c);task_id=str(uuid.uuid4())
        def docker(args,*a,**kw):
            if args[0]=='image':return 'null'
            if args[0] in ('start','rm'):raise sidecar.RuntimeFailure('unreachable')
            return ''
        command={'id':'start','method':'start','params':{'taskId':task_id,'instance':{'image':'x@sha256:'+'a'*64,'command':['agent']},'provider':{'baseURL':'https://example.com/v1','apiKey':'test','model':'m','api':'responses'}}}
        with patch.object(sidecar,'run_docker',docker):c.handle(command)
        self.assertIn(task_id,c.tasks)
        self.assertIn(c.tasks[task_id].name,output[-1]['error'])

    def test_exact_isolated_app_launch(self):
        import subprocess
        result=subprocess.run([sys.executable,'-I','-B','-u',sidecar.__file__],input=b'',stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5)
        self.assertEqual(result.returncode,0,result.stderr)
    def test_safe_ssh_user_host_and_injection_rejection(self):
        self.assertEqual(sidecar.docker_command(['info'],'alice@test-host')[-2],'alice@test-host')
        for host in ['alice@-oProxyCommand=evil','alice@host;touch','-alice@host','alice@@host','alice@host/path']:
            with self.assertRaises(sidecar.RuntimeFailure):sidecar.docker_command([],host)

    def test_controller_emit_tolerates_broken_output(self):
        controller=sidecar.Controller();output=unittest.mock.Mock()
        output.write.side_effect=BrokenPipeError('closed')
        with patch.object(sidecar.sys,'stdout',output):
            controller.emit({'id':'a','result':{}})
            controller.emit({'id':'b','result':{}})
        self.assertEqual(output.write.call_count,1)
    def test_eof_cleanup_continues_after_broken_emitter(self):
        import io
        controller=sidecar.Controller();controller.emit=unittest.mock.Mock(side_effect=BrokenPipeError('closed'))
        first=self.task();second=self.task();first.created=True;second.created=True
        first.emit=controller.emit;second.emit=controller.emit
        controller.tasks={first.task_id:first,second.task_id:second}
        stdin=unittest.mock.Mock();stdin.buffer=io.BytesIO(b'')
        with patch.object(sidecar.sys,'stdin',stdin),patch.object(sidecar,'run_docker',side_effect=[sidecar.RuntimeFailure('unavailable'),'']) as docker:
            controller.run()
        self.assertTrue(first.created);self.assertFalse(second.created)
        self.assertEqual(docker.call_count,2)

    def test_relay_uses_trusted_source_argv_without_docker_copy(self):
        source=pathlib.Path(sidecar.__file__).with_name('container_relay.py').read_text()
        for host in [None,'test-host']:
            t=self.task();t.host=host;calls=[];spawns=[]
            def docker(args,*a,**kw):calls.append(args);return 'null' if args[0]=='image' else ''
            def spawn(args):spawns.append(args);raise sidecar.RuntimeFailure('end startup test')
            with patch.object(sidecar,'run_docker',docker),patch.object(t,'spawn',spawn),patch.object(sidecar.subprocess,'run') as legacy_copy:
                with self.assertRaises(sidecar.RuntimeFailure):t.start()
            self.assertFalse(any(args[0]=='cp' for args in calls));legacy_copy.assert_not_called()
            self.assertEqual(spawns[0],['exec','-i',t.name,'python3','-I','-S','-B','-u','-c',source])

    def test_start_error_reports_retention_explicitly(self):
        for cleanup_fails in [False,True]:
            c=sidecar.Controller();output=[];c.emit=output.append;acknowledge_audit(c);task_id=str(uuid.uuid4())
            def docker(args,*a,**kw):
                if args[0]=='image':return 'null'
                if args[0]=='start' or (args[0]=='rm' and cleanup_fails):raise sidecar.RuntimeFailure('test failure')
                return ''
            message={'id':'start','method':'start','params':{'taskId':task_id,'instance':{'image':'x@sha256:'+'a'*64,'command':['agent']},'provider':{'baseURL':'https://example.com/v1','apiKey':'test','model':'m','api':'responses'}}}
            with patch.object(sidecar,'run_docker',docker):c.handle(message)
            self.assertEqual(output[-1]['taskRetained'],cleanup_fails)
            self.assertIn('error',output[-1])

if __name__ == "__main__": unittest.main()
