import pathlib, sys, unittest, threading, time, copy
from types import SimpleNamespace
from unittest.mock import Mock, patch
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'Sources/TravelCatApp/Resources/AgentRuntime'))
import sidecar

class RuntimeObserveTests(unittest.TestCase):
    def controller(self):
        c = sidecar.Controller(); self.addCleanup(c.native.closed.set)
        c.emit = Mock()
        c.emit_observation=lambda obj,deadline:c.emit(obj)
        return c

    def test_empty_and_params_are_strict(self):
        c = self.controller()
        c.handle({'id':'x','method':'runtime_observe','params':{}})
        result = c.emit.call_args.args[0]['result']
        self.assertEqual({i['kind'] for i in result['items']}, {'native','docker'})
        self.assertTrue(all(i['state']=='unobserved' for i in result['items']))
        c.handle({'id':'x','method':'runtime_observe','params':{'host':'secret'}})
        self.assertIn('error',c.emit.call_args.args[0])

    def test_native_is_single_scoped_read_and_does_not_change_records(self):
        c = self.controller(); transport = Mock(closed=False)
        transport.request.return_value = {'data':[], 'nextCursor':None}
        c.native.instances['i']={'generation':'g','transport':transport}
        c.native.tasks['t']={'taskId':'t','instanceId':'i','generation':'g','threadId':'thread','verified':True}
        before = copy.deepcopy(c.native.tasks)
        result = c.observe()['items'][0]
        self.assertEqual(result['state'],'responsive'); self.assertEqual(before,c.native.tasks)
        args, kwargs = transport.request.call_args
        self.assertEqual(args, ('thread/backgroundTerminals/list', {'threadId':'thread','limit':1,'cursor':None}))
        self.assertLessEqual(kwargs['deadline']-time.monotonic(),2.5)

    def test_busy_does_not_wait_or_query(self):
        c=self.controller()
        with c.observation_slot:
            self.assertEqual(c.observe()['items'][0]['reason'],'busy')

    def test_legacy_docker_never_inspects_name_without_identity(self):
        c=self.controller(); c.tasks['t']=SimpleNamespace(created=True,container_id=None)
        with patch.object(sidecar,'run_docker',side_effect=AssertionError('mutation')):
            item=c.observe()['items'][-1]
        self.assertEqual(item['reason'],'identity_unavailable')

    def test_native_timeout_is_sanitized(self):
        c=self.controller(); transport=Mock(closed=False)
        transport.request.side_effect=sidecar.codex_native._transport_module.NativeReadDeadline('secret/path/token')
        c.native.instances['i']={'generation':'g','transport':transport}
        c.native.tasks['t']={'taskId':'t','instanceId':'i','generation':'g','threadId':'thread','verified':True}
        result=c.observe()
        self.assertEqual(result['items'][0]['reason'],'timeout')
        self.assertNotIn('secret',str(result))

    def test_work_cap_reports_omitted_objects(self):
        c=self.controller()
        c.tasks={str(i):SimpleNamespace(created=True,container_id=None) for i in range(100)}
        items=c.observe()['items']
        self.assertLessEqual(len(items),10)
        self.assertTrue(any(i['reason']=='coverage_omitted' for i in items))

    def test_docker_exact_identity_context_and_no_default_fallback(self):
        c=self.controller(); identity='a'*64
        task=SimpleNamespace(container_id=identity,host=None,context='isolated',name='owned')
        c.tasks['t']=task
        value={'Id':identity,'Name':'/owned','State':{'Running':True,'Status':'running'}}
        with patch.object(sidecar.runtime_observe,'inspect_container',return_value=value) as inspect:
            self.assertEqual(c.observe()['items'][-1]['state'],'alive')
        command=inspect.call_args.args[0]
        self.assertEqual(command,['docker','--context','isolated','container','inspect','--format','{{json .}}',identity])
        value['Id']='b'*64
        with patch.object(sidecar.runtime_observe,'inspect_container',return_value=value):
            self.assertEqual(c.observe()['items'][-1]['reason'],'identity_mismatch')
        task.context=None
        with patch.object(sidecar.runtime_observe,'inspect_container') as inspect:
            self.assertEqual(c.observe()['items'][-1]['reason'],'identity_unavailable')
            inspect.assert_not_called()

    def test_docker_exited_and_error_are_not_conflated(self):
        c=self.controller(); identity='a'*64
        c.tasks['t']=SimpleNamespace(container_id=identity,host=None,context='isolated',name='owned')
        value={'Id':identity,'Name':'/owned','State':{'Running':False,'Status':'exited'}}
        with patch.object(sidecar.runtime_observe,'inspect_container',return_value=value):
            self.assertEqual(c.observe()['items'][-1]['state'],'exited')
        with patch.object(sidecar.runtime_observe,'inspect_container',side_effect=sidecar.runtime_observe.InspectFailure('disconnected')):
            self.assertEqual(c.observe()['items'][-1]['state'],'unknown')

    def test_total_deadline_shared_across_native_and_docker(self):
        c=self.controller(); transport=Mock(closed=False)
        transport.request.return_value={'data':[],'nextCursor':None}
        c.native.instances['i']={'generation':'g','transport':transport}
        c.native.tasks['t']={'taskId':'t','instanceId':'i','generation':'g','threadId':'thread','verified':True}
        c.tasks['d']=SimpleNamespace(container_id='a'*64,host=None,context='isolated',name='owned')
        with patch.object(sidecar.runtime_observe,'inspect_container',side_effect=sidecar.runtime_observe.InspectFailure('timeout')) as inspect:
            c.observe()
        self.assertEqual(transport.request.call_args.kwargs['deadline'],inspect.call_args.args[2])

    def test_real_owned_inspect_client_deadline_and_bounded_output(self):
        observe=sidecar.runtime_observe
        started=time.monotonic()
        with self.assertRaises(observe.InspectFailure) as raised:
            observe.inspect_container([sys.executable,'-c','import time; time.sleep(30)'],{},started+0.1)
        self.assertEqual(raised.exception.reason,'timeout')
        self.assertLess(time.monotonic()-started,0.5)
        with self.assertRaises(observe.InspectFailure) as raised:
            observe.inspect_container([sys.executable,'-c','print("x"*70000)'],{},time.monotonic()+1)
        self.assertEqual(raised.exception.reason,'invalid_response')

    def test_invalid_response_and_disconnected_and_generation_mismatch(self):
        c=self.controller(); transport=Mock(closed=False)
        transport.request.return_value={'unexpected':'secret'}
        c.native.instances['i']={'generation':'g','transport':transport}
        c.native.tasks['t']={'taskId':'t','instanceId':'i','generation':'g','threadId':'thread','verified':True}
        self.assertEqual(c.observe()['items'][0]['reason'],'invalid_response')
        transport.closed=True
        self.assertEqual(c.observe()['items'][0]['reason'],'not_connected')
        transport.closed=False;c.native.instances['i']['generation']='new'
        self.assertEqual(c.observe()['items'][0]['reason'],'identity_mismatch')

    def test_transport_observation_busy_registry_does_not_wait(self):
        native=sidecar.codex_native._transport_module
        transport=native.NativeTransport.__new__(native.NativeTransport)
        transport.lock=threading.Lock();transport.pending={};transport.closed=False
        with transport.lock:
            began=time.monotonic()
            with self.assertRaises(native.NativeFailure):
                transport.request('thread/backgroundTerminals/list',{},deadline=began+0.04,observation=True)
            self.assertLess(time.monotonic()-began,0.15)

    def test_dispatch_does_not_wait_for_controller_registry(self):
        c=self.controller()
        with c.lock:
            began=time.monotonic();c.handle({'id':'id','method':'runtime_observe','params':{}})
            self.assertLess(time.monotonic()-began,.1)
            items=c.emit.call_args.args[0]['result']['items']
            self.assertEqual({item['kind'] for item in items},{'native','docker'})
            self.assertTrue(all(item['reason']=='busy' for item in items))

    def test_pipe_atomic_delivery_and_backpressure(self):
        import os,fcntl,json
        c=self.controller(); c.emit_observation=sidecar.Controller.emit_observation.__get__(c)
        read,write=os.pipe(); self.addCleanup(os.close,read);self.addCleanup(os.close,write)
        output=SimpleNamespace(fileno=lambda:write)
        response={'id':'test','result':{'items':[sidecar.runtime_observe.item(kind,str(i),'alive','none') for kind in ('native','docker') for i in range(8)]}}
        with patch.object(sidecar.sys,'stdout',output):
            self.assertTrue(c.emit_observation(response,time.monotonic()+.2))
            data=os.read(read,8192)
            self.assertLessEqual(len(data),os.fpathconf(write,'PC_PIPE_BUF'))
            items=json.loads(data)['result']['items'];self.assertEqual({i['kind'] for i in items},{'native','docker'})
            self.assertTrue(any(i['reason']=='coverage_omitted' for i in items))
            flags=fcntl.fcntl(write,fcntl.F_GETFL);fcntl.fcntl(write,fcntl.F_SETFL,flags|os.O_NONBLOCK)
            total=0
            try:
                while True: total+=os.write(write,b'x'*512)
            except BlockingIOError: pass
            started=time.monotonic();self.assertFalse(c.emit_observation(response,started+.2));self.assertLess(time.monotonic()-started,.1)
            self.assertEqual(os.read(read,total),b'x'*total)
            with c.output_lock:
                self.assertFalse(c.emit_observation(response,time.monotonic()+.2))

    def test_partial_observation_tail_precedes_later_frames_without_disconnect(self):
        import json,struct
        module=sidecar.codex_native._transport_module
        for later_observation in (False,True):
            with self.subTest(later_observation=later_observation):
                transport=module.NativeTransport.__new__(module.NativeTransport)
                transport.lock=threading.RLock();transport.writer=threading.Lock();transport.pending={};transport.closed=False
                clock=[100.0];wire=bytearray();first=[True]
                def send(data):
                    if first[0]:
                        first[0]=False;wire.extend(data[:1]);clock[0]+=.04;return 1
                    wire.extend(data);return len(data)
                transport.socket=SimpleNamespace(setblocking=lambda _:None,send=send)
                transport._lost=Mock(side_effect=AssertionError('observer disconnected transport'))
                with patch.object(module.time,'monotonic',side_effect=lambda:clock[0]),patch.object(module.select,'select',side_effect=lambda r,w,e,t:([],w,[])):
                    with self.assertRaises(module.NativeReadDeadline):
                        transport.request('thread/backgroundTerminals/list',{},deadline=100.03,observation=True)
                    self.assertEqual(transport.pending,{})
                    self.assertTrue(transport.observation_tail)
                    # A second expired flush preserves every unsent byte.
                    tail=transport.observation_tail
                    with self.assertRaises(module.NativeReadDeadline):
                        transport._send({'method':'next'},deadline=100.04,observation=True)
                    self.assertEqual(tail,transport.observation_tail)
                    first[0]=True
                    with self.assertRaises(module.NativeReadDeadline):
                        transport._send({'method':'next'},deadline=100.07,observation=True)
                    self.assertEqual(tail[1:],transport.observation_tail)
                    transport._send({'method':'next'},deadline=101.0 if later_observation else None,observation=later_observation)
                self.assertFalse(transport.closed);transport._lost.assert_not_called()
                self.assertEqual(transport.observation_tail,b'')
                frames=[];offset=0
                while offset<len(wire):
                    size=wire[offset+1]&127;offset+=2
                    if size==126:size=struct.unpack('!H',wire[offset:offset+2])[0];offset+=2
                    key=wire[offset:offset+4];offset+=4
                    payload=bytes(b^key[i%4] for i,b in enumerate(wire[offset:offset+size]));offset+=size
                    frames.append(json.loads(payload))
                self.assertEqual([frame['method'] for frame in frames],['thread/backgroundTerminals/list','next'])
