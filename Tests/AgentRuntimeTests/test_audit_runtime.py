import pathlib,sys,threading,time,unittest,uuid
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[2]/'Sources/TravelCatApp/Resources/AgentRuntime'))
import sidecar
class AuditTests(unittest.TestCase):
 def test_receipt_is_required_and_rejection_latches(self):
  events=[];broker=sidecar.audit_runtime.AuditBroker(events.append,timeout=.2);errors=[]
  def record():
   try: broker.record(str(uuid.uuid4()),'model.request')
   except Exception as e: errors.append(e)
  worker=threading.Thread(target=record);worker.start()
  for _ in range(100):
   if events: break
   time.sleep(.001)
  self.assertTrue(worker.is_alive());broker.ack(events[0]['data']['receiptId'],False);worker.join(1)
  self.assertTrue(errors)
  with self.assertRaises(Exception):broker.record(str(uuid.uuid4()),'model.request')
 def test_frozen_body_and_external_reference_denial(self):
  p=sidecar.Provider(dict(baseURL='https://example.com/v1',api='responses',model='m',apiKey='secret'))
  frozen=p.freeze('/responses',{'input':'hello','model':'evil'})
  self.assertEqual(frozen.body,b'{"input":"hello","model":"m"}')
  with self.assertRaises(sidecar.RuntimeFailure):p.freeze('/responses',{'input':[{'type':'input_image','image_url':'https://remote/image'}]})

class SubmissionTests(unittest.TestCase):
 def setUp(self):
  self.events=[];self.sent=[]
  self.broker=sidecar.audit_runtime.AuditBroker(self.events.append,timeout=.5)
  self.task=sidecar.Task(str(uuid.uuid4()),dict(image='x@sha256:'+'a'*64,command=['agent']),sidecar.Provider(dict(baseURL='https://example.com/v1',api='responses',model='fixed',apiKey='private-key')),self.events.append,audit=self.broker)
  self.task.send=lambda process,lock,event:self.sent.append(event)
  self.network=[]
 def wait(self,predicate):
  deadline=time.monotonic()+2
  while not predicate() and time.monotonic()<deadline:time.sleep(.002)
  self.assertTrue(predicate())
 def start(self):
  import base64
  def upstream(frozen,revoked,lock):
   if revoked():raise sidecar.RuntimeFailure('task stopped')
   self.network.append(frozen)
   yield {'status':200,'contentType':'application/json'}
   for chunk in getattr(self,'response_chunks',[b'{"usage":{"input_tokens":4,"output_tokens":2},"output":"ok"}']):
    yield {'chunk':base64.b64encode(chunk).decode()}
  self.task.provider.stream_frozen=upstream
  self.task.request_slots.acquire()
  self.worker=threading.Thread(target=self.task.forward,args=({'id':'relay','path':'/responses','body':{'input':'hello','model':'evil'}},));self.worker.start()
 def ack(self,event,accepted=True):self.broker.ack(event['data']['receiptId'],accepted)
 def drain(self):
  seen=set();deadline=time.monotonic()+2
  while self.worker.is_alive() and time.monotonic()<deadline:
   for event in list(self.events):
    if event['event']=='audit' and event['data']['receiptId'] not in seen:
     seen.add(event['data']['receiptId']);self.ack(event)
   time.sleep(.002)
  self.worker.join(.1);self.assertFalse(self.worker.is_alive())
 def test_exact_request_waits_for_receipt_and_bound_grant(self):
  import hashlib
  self.start();self.wait(lambda:bool(self.events));self.assertEqual(self.network,[])
  request=self.events[0];self.ack(request)
  self.wait(lambda:any(e['event']=='modelApproval' for e in self.events));self.assertEqual(self.network,[])
  approval=next(e['data'] for e in self.events if e['event']=='modelApproval')
  with self.assertRaises(sidecar.RuntimeFailure):self.task.model_permission(approval['callId'],'bad',True)
  self.task.model_permission(approval['callId'],approval['requestHash'],True)
  with self.assertRaises(sidecar.RuntimeFailure):self.task.model_permission(approval['callId'],approval['requestHash'],True)
  self.wait(lambda:any(e.get('data',{}).get('record',{}).get('kind')=='model.decision' for e in self.events))
  self.assertEqual(self.network,[]);self.drain()
  self.assertEqual(len(self.network),1)
  self.assertEqual(hashlib.sha256(self.network[0].body).hexdigest(),approval['requestHash'])
  self.assertEqual(self.network[0].body.decode(),request['data']['record']['body'])
  self.assertEqual(approval['destination'],'https://example.com/v1/responses')
  self.assertEqual(request['data']['record']['destination'],approval['destination'])
  self.assertFalse(request['data']['record']['bodyRedacted'])
  records=[e['data']['record'] for e in self.events if e['event']=='audit']
  self.assertEqual([r['kind'] for r in records[:2]],['model.request','model.decision'])
  self.assertEqual(records[-1]['kind'],'model.completed')
  fragments=records[2:-1]
  self.assertTrue(all(r['kind']=='model.response' for r in fragments))
  self.assertEqual([r['sequence'] for r in fragments],list(range(len(fragments))))
  self.assertEqual(records[-1]['usage']['totalInput'],4)
  self.assertNotIn('private-key',str(records))
 def test_swift_uppercase_call_uuid_preserves_hash_one_shot_and_deadline_binding(self):
  call=str(uuid.uuid4());event=threading.Event()
  entry={'hash':'bound-request-sha','event':event,'allow':False,'deadline':time.monotonic()+1}
  self.task.model_permissions[call]=entry
  for identifier,request_hash in [(call.upper(),'wrong-sha'),(str(uuid.uuid4()).upper(),'bound-request-sha')]:
   with self.assertRaises(sidecar.RuntimeFailure):self.task.model_permission(identifier,request_hash,False)
  self.assertFalse(event.is_set())
  try: result=self.task.model_permission(call.upper(),'bound-request-sha',False)
  except sidecar.RuntimeFailure: self.fail('Swift uuidString upper-case call ID must resolve the same bound approval')
  self.assertEqual(result,{});self.assertTrue(event.is_set());self.assertFalse(entry['allow'])
  with self.assertRaises(sidecar.RuntimeFailure):self.task.model_permission(call,'bound-request-sha',True)
  entry['event']=threading.Event();entry['deadline']=time.monotonic()-1
  with self.assertRaises(sidecar.RuntimeFailure):self.task.model_permission(call.upper(),'bound-request-sha',True)
  self.assertFalse(entry['event'].is_set());self.assertEqual(self.network,[])
 def test_denial_never_submits(self):
  self.start();self.wait(lambda:bool(self.events));self.ack(self.events[0])
  self.wait(lambda:any(e['event']=='modelApproval' for e in self.events))
  p=next(e['data'] for e in self.events if e['event']=='modelApproval')
  self.task.model_permission(p['callId'],p['requestHash'],False);self.drain();self.assertEqual(self.network,[])
 def test_rejected_request_receipt_never_submits(self):
  self.start();self.wait(lambda:bool(self.events));self.ack(self.events[0],False)
  self.worker.join(1);self.assertFalse(self.worker.is_alive());self.assertEqual(self.network,[]);self.assertTrue(self.broker.failed)
 def test_stop_while_waiting_never_submits(self):
  self.start();self.wait(lambda:bool(self.events));self.ack(self.events[0])
  self.wait(lambda:any(e['event']=='modelApproval' for e in self.events))
  self.task.stop();self.drain();self.assertEqual(self.network,[])
 def test_task_grant_still_requires_decision_receipt(self):
  self.task.model_policy='task';self.start();self.wait(lambda:bool(self.events));self.assertEqual(self.network,[])
  self.drain();self.assertEqual(len(self.network),1)
  self.assertFalse(any(e['event']=='modelApproval' for e in self.events))
 def test_ack_routes_without_task_lookup(self):
  c=sidecar.Controller();output=[];c.emit=output.append
  c.handle({'id':'ack','method':'audit_ack','params':{'receiptId':'stale','accepted':True}})
  self.assertEqual(output,[{'id':'ack','result':{'accepted':False}}])

 def test_relay_receives_only_cross_chunk_sanitized_text(self):
  import base64,json
  self.task.model_policy='task';self.task.provider.key='private-"key'
  encoded=json.dumps(self.task.provider.key)[1:-1].encode()
  self.response_chunks=[b'{"output":"'+encoded[:5],encoded[5:]+b'"}']
  self.start();self.drain()
  content=b''.join(base64.b64decode(event['chunk']) for event in self.sent if 'chunk' in event)
  self.assertEqual(json.loads(content),{'output':'[REDACTED]'})
  self.assertNotIn(encoded,content)
 def test_failed_audit_cleans_container_and_failed_cleanup_is_retryable(self):
  from unittest.mock import patch
  self.task.created=True
  with patch.object(sidecar,'run_docker',side_effect=[sidecar.RuntimeFailure('offline'),'']) as docker:
   self.start();self.wait(lambda:bool(self.events));self.ack(self.events[0],False)
   self.worker.join(1);self.assertFalse(self.worker.is_alive())
   docker.assert_called_once();self.assertTrue(self.task.created)
   self.assertEqual(self.task.stop(),{'stopped':True})
   self.assertEqual(docker.call_count,2)
  self.assertEqual(self.network,[])
 def test_remote_anthropic_sources_denied(self):
  p=sidecar.Provider(dict(baseURL='https://example.com',api='messages',model='m',apiKey='secret'))
  for kind in ('image','document'):
   with self.assertRaises(sidecar.RuntimeFailure):
    p.freeze('/messages',{'messages':[{'role':'user','content':[{'type':kind,'source':{'type':'url','url':'https://remote.example/content'}}]}]})

 def test_semantic_sse_key_fragments_never_reach_container(self):
  import json
  fixtures=[
   [{'choices':[{'delta':{'content':part}}]} for part in ('private-','key')],
   [{'type':'response.output_text.delta','delta':part} for part in ('private-','key')],
   [{'type':'content_block_delta','delta':{'type':'text_delta','text':part}} for part in ('private-','key')],
   [{'choices':[{'delta':{'tool_calls':[{'function':{'arguments':part}}]}}]} for part in ('private-','key')],
   [{'type':'response.function_call_arguments.delta','delta':part} for part in ('private-','key')],
   [{'type':'content_block_delta','delta':{'type':'input_json_delta','partial_json':part}} for part in ('private-','key')],
  ]
  for documents in fixtures:
   with self.subTest(documents=documents):
    self.setUp();self.task.model_policy='task'
    self.response_chunks=[('data: '+json.dumps(doc)+'\n\n').encode() for doc in documents]
    self.start();self.drain()
    self.assertFalse(any('chunk' in event for event in self.sent))
    self.assertTrue(any('error' in event for event in self.sent))
    kinds=[e['data']['record']['kind'] for e in self.events if e['event']=='audit']
    self.assertNotIn('model.response',kinds);self.assertIn('model.failed',kinds)

 def test_import_record_contains_exact_file_manifest(self):
  import base64,hashlib
  from unittest.mock import patch
  records=[]
  def emit(event):
   records.append(event['data']['record']);self.broker.ack(event['data']['receiptId'],True)
  self.broker.emit=emit
  data=b'original selected bytes';files=[{'name':'input.txt','base64':base64.b64encode(data).decode()}]
  with patch.object(sidecar,'run_docker',return_value='{"imported":1,"rootIdentity":[1,2]}'):self.task.workspace('import',files=files)
  self.assertEqual(records[0]['files'],[{'name':'input.txt','bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}])
  self.assertNotIn(files[0]['base64'],str(records))
 def test_start_record_identifies_runtime_and_sandbox(self):
  from unittest.mock import patch
  c=sidecar.Controller();records=[];c.emit=lambda event:None
  def emit(event):
   records.append(event['data']['record']);c.audit.ack(event['data']['receiptId'],True)
  c.audit.emit=emit
  params={'taskId':self.task.task_id,'instance':{'image':'x@sha256:'+'a'*64,'command':['agent','--stdio'],'host':'test-host','dockerContext':'engine'},'provider':{'baseURL':'https://example.com/v1','apiKey':'private-key','model':'m','api':'responses'}}
  with patch.object(sidecar.Task,'start',return_value={}):c.handle({'id':'start','method':'start','params':params})
  record=records[0]
  self.assertEqual(record['image'],params['instance']['image']);self.assertEqual(record['command'],['agent','--stdio'])
  self.assertEqual(record['host'],'test-host');self.assertEqual(record['dockerContext'],'engine')
  self.assertEqual(record['sandbox']['network'],'none');self.assertEqual(record['sandbox']['hostMounts'],[])

 def test_keepalive_spans_permission_upstream_and_audit_without_early_headers(self):
  import base64,http.client,container_relay,socket
  from unittest.mock import patch
  changed=threading.Condition();phase=['initial'];leases={};lease_packets={};receipts={}
  headers=threading.Event();upstream_entered=threading.Event();upstream_release=threading.Event();body_done=threading.Event();cleaning=threading.Event()
  results=[];errors=[];chunks=[];forwarders=[];keepalives=[];clients=[];owned_ids=[];handlers=set()
  original_queue=container_relay.queue.Queue;original_headers=container_relay.Handler.end_headers
  class ObservedQueue(original_queue):
   previous_phase=None
   def get(queue,*args,**kwargs):
    # Reaching the next get proves the Handler processed the previous lease.
    with changed:
     handlers.add(threading.current_thread())
     if queue.previous_phase is not None:
      label=queue.previous_phase;leases[label]=leases.get(label,0)+1;queue.previous_phase=None;changed.notify_all()
    item=super().get(*args,**kwargs)
    with changed:
     packet=lease_packets.pop(id(item),None)
     if item.get('keepalive') is True and packet is not None and packet[0] is item:queue.previous_phase=packet[1]
    return item
  def await_condition(predicate,label):
   with changed:self.assertTrue(changed.wait_for(predicate,2),label)
  def await_leases(label):await_condition(lambda:leases.get(label,0)>=2,'Handler must process two leases during '+label)
  def receipt(kind,index=0):
   await_condition(lambda:len(receipts.get(kind,[]))>index,'Audit phase must be reached: '+kind)
   return receipts[kind][index]
  def no_headers_or_upstream():
   self.assertFalse(headers.is_set());self.assertFalse(upstream_entered.is_set())
  def audit_emit(event):
   kind=event['data']['record']['kind']
   with changed:
    entries=receipts.setdefault(kind,[]);label='audit.'+kind+'.'+str(len(entries));phase[0]=label
    entries.append((event['data']['receiptId'],label));changed.notify_all()
    reject=cleaning.is_set()
   if reject:self.broker.ack(event['data']['receiptId'],False)
  self.broker=sidecar.audit_runtime.AuditBroker(audit_emit) # Production 30s audit receipt boundary.
  self.task.audit=self.broker
  keepalive=self.task.relay_keepalive
  def track_keepalive(*args):
   with changed:keepalives.append(threading.current_thread())
   return keepalive(*args)
  self.task.relay_keepalive=track_keepalive
  def task_emit(event):
   with changed:
    self.events.append(event)
    if event['event']=='modelApproval':phase[0]='permission'
    changed.notify_all()
  self.task.emit=task_emit
  def upstream(frozen,revoked,lock):
   with changed:phase[0]='upstream';upstream_entered.set();changed.notify_all()
   self.assertTrue(upstream_release.wait(30),'Owned upstream gate must be released')
   if revoked():raise sidecar.RuntimeFailure('owned fixture stopped')
   yield {'status':200,'contentType':'application/json'}
   yield {'chunk':base64.b64encode(b'{"output":"ok"}').decode()}
  self.task.provider.stream_frozen=upstream
  def relay_emit(obj):
   owned_ids.append(obj['id']);self.task.request_slots.acquire()
   worker=threading.Thread(target=self.task.forward,args=(obj,));forwarders.append(worker);worker.start()
  def task_send(process,lock,event):
   with changed:
    if event.get('keepalive') is True:lease_packets[id(event)]=(event,phase[0])
    if 'chunk' in event:chunks.append(event['chunk'])
   with container_relay.lock:target=container_relay.pending.get(event['id'])
   if target:target.put(event)
  self.task.send=task_send
  def observe_headers(handler):
   result=original_headers(handler);headers.set();return result
  server=container_relay.Server(('127.0.0.1',0),container_relay.Handler)
  server.connections=threading.BoundedSemaphore(8)
  server_worker=threading.Thread(target=lambda:server.serve_forever(poll_interval=.01),daemon=True);server_worker.start()
  def request():
   conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=30);clients.append(conn)
   try:
    conn.request('POST','/responses',b'{"input":"hello"}',{'Content-Type':'application/json'})
    response=conn.getresponse();results.append((response.status,response.read()));body_done.set()
   except Exception as error:errors.append(type(error).__name__)
   finally:conn.close()
  worker=threading.Thread(target=request)
  try:
   # Use the production 125s idle lease. Positive consumed-heartbeat evidence,
   # rather than a 25ms scheduling window, is the behavior under test.
   with patch.object(sidecar,'KEEPALIVE_SECONDS',.005),patch.object(container_relay.queue,'Queue',ObservedQueue),patch.object(container_relay,'emit',relay_emit),patch.object(container_relay.Handler,'end_headers',observe_headers):
    worker.start()
    request_receipt,label=receipt('model.request');await_leases(label);no_headers_or_upstream()
    self.assertTrue(self.broker.ack(request_receipt,True))
    await_condition(lambda:any(e['event']=='modelApproval' for e in self.events),'Bound approval must be published')
    await_leases('permission');no_headers_or_upstream()
    approval=next(e['data'] for e in self.events if e['event']=='modelApproval')
    self.task.model_permission(approval['callId'],approval['requestHash'],True)
    decision_receipt,label=receipt('model.decision');await_leases(label);no_headers_or_upstream()
    self.assertTrue(self.broker.ack(decision_receipt,True))
    self.assertTrue(upstream_entered.wait(2));await_leases('upstream');self.assertFalse(headers.is_set())
    upstream_release.set()
    accepted=0
    while True:
     await_condition(lambda:len(receipts.get('model.response',[]))>accepted or bool(receipts.get('model.completed')),'Response or completion audit must be reached')
     if len(receipts.get('model.response',[]))>accepted:
      response_receipt,label=receipts['model.response'][accepted];await_leases(label)
      self.assertTrue(headers.is_set(),'Buffered response metadata precedes response-fragment auditing')
      self.assertEqual(len(chunks),accepted,'Current response fragment must wait for its durable receipt')
      self.assertFalse(body_done.is_set());self.assertTrue(self.broker.ack(response_receipt,True));accepted+=1
     else:
      complete_receipt,label=receipts['model.completed'][0];await_leases(label)
      self.assertFalse(body_done.is_set());self.assertTrue(self.broker.ack(complete_receipt,True));break
    worker.join(2);self.assertFalse(worker.is_alive());self.assertEqual(errors,[])
    self.assertEqual(results,[(200,b'{"output":"ok"}')]);self.assertGreater(accepted,0)
  finally:
   with changed:cleaning.set()
   self.task.stopped.set();upstream_release.set()
   with self.broker.lock:pending=list(self.broker.pending)
   for receipt_id in pending:self.broker.ack(receipt_id,False)
   # Wake only this test's Handler, including a failed phase/heartbeat mutation.
   with container_relay.lock:targets=[container_relay.pending.get(rid) for rid in owned_ids]
   for target in targets:
    if target is not None:
     try:target.put({'error':'owned fixture cleanup'},timeout=.5)
     except container_relay.queue.Full:
      for _ in range(16):
       try:target.get_nowait()
       except container_relay.queue.Empty:break
      target.put_nowait({'error':'owned fixture cleanup'})
   for forwarder in forwarders:forwarder.join(2);self.assertFalse(forwarder.is_alive())
   for heartbeat in keepalives:heartbeat.join(2);self.assertFalse(heartbeat.is_alive())
   for conn in clients:
    if conn.sock:
     try:conn.sock.shutdown(socket.SHUT_RDWR)
     except OSError:pass
    conn.close()
   if worker.ident is not None:worker.join(2);self.assertFalse(worker.is_alive())
   server.shutdown();server.server_close();server_worker.join(2)
   for handler in handlers:
    if handler is not threading.current_thread():handler.join(2);self.assertFalse(handler.is_alive())
   self.assertFalse(server_worker.is_alive())

 def test_relay_idle_expiry_and_control_lease_renewal_are_header_silent(self):
  import base64,io,container_relay
  from email.message import Message
  from unittest.mock import patch
  for renewals,complete in ((0,False),(2,False),(2,True)):
   with self.subTest(renewals=renewals,complete=complete):
    statuses=[];failures=[];waits=[]
    handler=container_relay.Handler.__new__(container_relay.Handler)
    handler.connection=type('Connection',(),{'settimeout':lambda *_:None})()
    handler.path='/responses';handler.headers=Message();handler.headers['Content-Length']='2'
    handler.rfile=io.BytesIO(b'{}');handler.wfile=io.BytesIO()
    handler.send_response=lambda status:statuses.append(status)
    handler.send_header=lambda *_:None;handler.end_headers=lambda:None
    handler.send_error=lambda status,*_:failures.append(status)
    items=[{'keepalive':True} for _ in range(renewals)]
    if complete:items.extend([{'status':200,'contentType':'application/json'},{'chunk':base64.b64encode(b'ok').decode()},{'done':True}])
    class ScriptedQueue:
     def __init__(queue,*args,**kwargs):pass
     def get(queue,timeout):
      waits.append(timeout)
      if not items:raise container_relay.queue.Empty
      item=items.pop(0)
      if item.get('keepalive'):self.assertEqual(statuses,[])
      return item
    with patch.object(container_relay.queue,'Queue',ScriptedQueue),patch.object(container_relay,'emit',lambda _:None):handler.do_POST()
    self.assertEqual(waits,[125]*(renewals+3 if complete else renewals+1),'Every consumed lease starts a fresh full idle wait')
    self.assertEqual(failures,[] if complete else [502])
    self.assertEqual(statuses,[200] if complete else [])
    self.assertEqual(handler.wfile.getvalue(),b'ok' if complete else b'')

 def test_tool_permission_details_are_persisted_and_scrubbed_before_ui(self):
  from unittest.mock import patch
  def emit(event):
   self.events.append(event);self.broker.ack(event['data']['receiptId'],True)
  self.broker.emit=emit;self.task.session='session'
  request={'id':42,'method':'session/request_permission','params':{'sessionId':'session','options':[{'optionId':'yes','name':'Allow'}],'toolCall':{'title':'Run','rawInput':{'command':'echo private-key'}}}}
  with patch.object(self.task,'lines',return_value=iter([request])):self.task.read_acp()
  self.assertEqual(self.events[0]['event'],'audit')
  record=self.events[0]['data']['record']
  self.assertEqual(record['kind'],'operation.permissionRequest')
  self.assertEqual(record['toolCall']['rawInput']['command'],'echo [REDACTED]')
  permission=next(e for e in self.events if e['event']=='permission')
  self.assertEqual(record['requestId'],permission['data']['requestId'])
 def test_tool_permission_audit_failure_stops_before_ui(self):
  from unittest.mock import patch
  self.broker.emit=lambda event:self.broker.ack(event['data']['receiptId'],False)
  self.task.session='session'
  request={'id':42,'method':'session/request_permission','params':{'sessionId':'session','options':[{'optionId':'yes'}],'toolCall':{'title':'write'}}}
  with patch.object(self.task,'lines',return_value=iter([request])):self.task.read_acp()
  self.assertFalse(any(e['event']=='permission' for e in self.events));self.assertTrue(self.task.stopped.is_set())

 def test_redacted_request_flags_hash_of_actual_bytes(self):
  import hashlib
  self.task.model_policy='task'
  self.task.provider.model='model-private-key'
  self.start();self.drain()
  record=next(e['data']['record'] for e in self.events if e['event']=='audit' and e['data']['record']['kind']=='model.request')
  self.assertTrue(record['bodyRedacted'])
  self.assertNotIn('private-key',str(record))
  self.assertIn('[REDACTED]',record['body'])
  self.assertEqual(record['requestHash'],hashlib.sha256(self.network[0].body).hexdigest())
  self.assertNotEqual(record['requestHash'],hashlib.sha256(record['body'].encode()).hexdigest())

class BoundaryTests(unittest.TestCase):
 def test_receipt_timeout_latches_closed(self):
  broker=sidecar.audit_runtime.AuditBroker(lambda event:None,timeout=.001)
  with self.assertRaises(sidecar.audit_runtime.AuditFailure):broker.record(str(uuid.uuid4()),'model.request')
  self.assertTrue(broker.failed)
 def test_ack_is_not_starved_by_worker_limit(self):
  import io,json
  from unittest.mock import Mock,patch
  c=sidecar.Controller();events=[];c.emit=events.append
  stdin=Mock();stdin.buffer=io.BytesIO((json.dumps({'id':'ack','method':'audit_ack','params':{'receiptId':'unknown','accepted':True}})+'\n').encode())
  slots=Mock();slots.acquire.return_value=False
  with patch.object(sidecar.sys,'stdin',stdin),patch.object(sidecar.threading,'BoundedSemaphore',return_value=slots):c.run()
  slots.acquire.assert_not_called()
  self.assertEqual(events,[{'id':'ack','result':{'accepted':False}}])
 def test_http_receives_frozen_exact_bytes(self):
  from unittest.mock import patch
  p=sidecar.Provider(dict(baseURL='https://example.com/v1',api='responses',model='m',apiKey='secret'));original={'input':'中文'}
  frozen=p.freeze('/responses',original);original['input']='changed';received=[]
  class Response:
   status=200
   def read1(self,n):return b''
  class Connection:
   def __init__(self,*args,**kwargs):pass
   def request(self,method,path,body,headers):received.append(body)
   def getresponse(self):return Response()
   def close(self):pass
  with patch.object(sidecar.http.client,'HTTPSConnection',Connection):list(p.stream_frozen(frozen,lambda:False))
  self.assertEqual(received,[frozen.body]);self.assertIn('中文',frozen.body.decode())
 def test_oversized_audit_record_fails_closed(self):
  events=[];broker=sidecar.audit_runtime.AuditBroker(events.append)
  with self.assertRaises(sidecar.audit_runtime.AuditFailure):broker.record(str(uuid.uuid4()),'model.request',body='x'*(2*1024*1024))
  self.assertEqual(events,[]);self.assertTrue(broker.failed)
