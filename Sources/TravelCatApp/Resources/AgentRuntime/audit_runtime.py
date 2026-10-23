"""Mandatory durable host receipts. No journal or provider credential is stored here."""
import datetime,json,threading,time,uuid
class AuditFailure(Exception): pass
class AuditBroker:
 def __init__(self,emit,timeout=30):
  self.emit=emit;self.timeout=timeout;self.lock=threading.Lock();self.pending={};self.failed=False
 def ack(self,receipt_id,accepted):
  with self.lock:
   entry=self.pending.get(receipt_id)
   if entry is None or entry[0].is_set(): return False
   entry[1]=accepted is True;entry[0].set();return True
 def record(self,task_id,kind,call_id=None,**fields):
  receipt=str(uuid.uuid4());entry=[threading.Event(),False]
  record=dict(fields,eventId=str(uuid.uuid4()),taskId=task_id,kind=kind,timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat())
  if call_id:record['callId']=call_id
  if len(json.dumps(record,ensure_ascii=False,separators=(',',':')).encode('utf-8'))>2*1024*1024:
   with self.lock:self.failed=True
   raise AuditFailure('audit record exceeds 2 MiB limit')
  with self.lock:
   if self.failed:raise AuditFailure('audit unavailable; restart after repairing journal')
   self.pending[receipt]=entry
  try:
   self.emit({'event':'audit','taskId':task_id,'data':{'receiptId':receipt,'record':record}})
   if not entry[0].wait(self.timeout) or not entry[1]:
    with self.lock:self.failed=True
    raise AuditFailure('audit persistence failed or timed out')
   return record
  except Exception:
   with self.lock:self.failed=True
   raise
  finally:
   with self.lock:self.pending.pop(receipt,None)
class RejectingBroker:
 def record(self,*args,**kwargs):raise AuditFailure('audit broker required')
