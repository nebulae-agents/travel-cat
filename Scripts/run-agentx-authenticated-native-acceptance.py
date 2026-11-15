#!/usr/bin/env python3
"""Real authenticated Codex control acceptance; two bounded model turns, no file/tool work.
Requires a dedicated, already logged-in temporary native profile and exclusive use.
Does not read, copy, print or modify credentials. Retains its sanitized report and
new thread in that profile. Only the validated profile's owned daemon is stopped.
Usage: python3 Scripts/run-agentx-authenticated-native-acceptance.py /private/tmp/agentx-authenticated-*/native-session.json --allow-two-model-requests
"""
import json,pathlib,sys,time,uuid,threading
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'Sources/TravelCatApp/Resources/AgentRuntime'))
import codex_native as n
if len(sys.argv)!=3 or sys.argv[2]!='--allow-two-model-requests':raise SystemExit('Explicit two-turn acceptance opt-in required')
session=pathlib.Path(sys.argv[1]).resolve(strict=True);root=session.parent
import tempfile
if not root.name.startswith('agentx-authenticated-') or not any(root.is_relative_to(p.resolve()) for p in (pathlib.Path('/private/tmp'),pathlib.Path(tempfile.gettempdir()))):raise SystemExit('Requires dedicated temporary acceptance root')
params=n._configuration(json.loads(session.read_text()));key=params['instanceId'];profile=pathlib.Path(params['profileRoot'])
if n._transport_module._managed_profile_root(profile)!=root or not pathlib.Path(params['workspace']).is_relative_to(root):raise SystemExit('Profile and workspace must belong to this acceptance root')
receipt_path=profile/'travelcat-daemon.json'
if receipt_path.exists() and not n._transport_module._confirmed_absent(json.loads(receipt_path.read_text())['pid']):raise SystemExit('Requires no existing live daemon; use this profile exclusively')
events=[];event_lock=threading.Lock()
def emit(e):
 with event_lock:events.append(e)
def snapshot():
 with event_lock:return list(events)
def wait_for(predicate,seconds=90):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if predicate():return
  time.sleep(.05)
 raise RuntimeError('bounded wait expired')
def terminal(c,tid,turn):return c.tasks[tid]['terminalTurns'].get(turn)
def no_tools(entries):
 return all(isinstance(e.get('item'),dict) and e['item'].get('type') in ('userMessage','agentMessage','reasoning') for e in entries)
def contains_marker(entries,turn_id):
 return any(e.get('turnId')==turn_id and isinstance(e.get('item'),dict) and e['item'].get('type')=='agentMessage' and isinstance(e['item'].get('text'),str) and e['item']['text'].strip()=='AGENTX_NATIVE_ACCEPTANCE_OK' for e in entries)
report={'checks':{},'modelRequests':0};c=n.CodexNativeController(emit);began=time.monotonic();phase='connect'
try:
 result=c.handle('native_connect',params);report['checks']['authenticated']=result['account']['authenticated']
 if not report['checks']['authenticated']:raise RuntimeError('isolated native keyring login required')
 model=next((x['model'] for x in result['models'] if x.get('isDefault')),result['models'][0]['model']);report['model']=model
 receipt=json.loads((profile/'travelcat-daemon.json').read_text());report['daemonPid']=receipt['pid']
 tid=str(uuid.uuid4());phase='short-thread';started=c.handle('native_start',{'instanceId':key,'taskId':tid,'model':model});thread=started['threadId'];report['threadId']=thread
 phase='short-turn';turn=c.handle('native_prompt',{'taskId':tid,'text':'Do not use any tools or read or write any files. Reply with exactly AGENTX_NATIVE_ACCEPTANCE_OK and nothing else.','clientUserMessageId':str(uuid.uuid4())})['turnId'];report['modelRequests']+=1
 wait_for(lambda:terminal(c,tid,turn) is not None);report['shortTurnStatus']=terminal(c,tid,turn);report['checks']['shortTurnCompleted']=terminal(c,tid,turn)=='completed'
 if not report['checks']['shortTurnCompleted']:raise RuntimeError('short turn did not complete successfully')
 phase='disconnect-resume';c.close();report['checks']['detachPreservesDaemon']=n._transport_module._process_identity(receipt['pid'])==receipt['processIdentity']
 c=n.CodexNativeController(emit);c.handle('native_connect',params);history=c.handle('native_resume',{'instanceId':key,'taskId':tid,'threadId':thread})
 report['checks']['persistedThreadResumed']=history['threadId']==thread and any(t['id']==turn and t['status']=='completed' for t in history['turns'])
 report['checks']['fixedResponseRecovered']=contains_marker(history['items'],turn);report['checks']['shortTurnUsedNoTools']=no_tools(history['items'])
 phase='active-turn';longturn=c.handle('native_prompt',{'taskId':tid,'text':'Do not use any tools and do not read or write files. Produce a long plain text numbered list of 1000 imaginary travel location names, one per line, without asking questions. Begin immediately. This is a cancellation test.','clientUserMessageId':str(uuid.uuid4())})['turnId'];report['modelRequests']+=1
 wait_for(lambda:any(e.get('data',{}).get('method')=='turn/started' and e['data']['params'].get('turn',{}).get('id')==longturn for e in snapshot()),15)
 report['checks']['officialTurnStarted']=True
 wait_for(lambda:any(e.get('data',{}).get('method')=='item/agentMessage/delta' and e['data']['params'].get('turnId')==longturn for e in snapshot()) or terminal(c,tid,longturn) is not None,90)
 report['checks']['streamObserved']=any(e.get('data',{}).get('method')=='item/agentMessage/delta' and e['data']['params'].get('turnId')==longturn for e in snapshot())
 report['checks']['activeBeforeInterrupt']=c.tasks[tid]['turnId']==longturn and terminal(c,tid,longturn) is None
 if not report['checks']['activeBeforeInterrupt']:raise RuntimeError('long turn ended before interruption')
 phase='interrupt';cancel=c.handle('native_cancel',{'taskId':tid,'turnId':longturn});report['cancelResult']=cancel;report['checks']['interrupted']=cancel['turnStatus']=='interrupted';report['checks']['backgroundStopped']=cancel['backgroundStopped'] is True
 phase='quiesce';report['checks']['quiesce']=c.handle('native_quiesce',{})['stopped'];report['checks']['daemonExited']=n._transport_module._confirmed_absent(receipt['pid']);c.close()
 phase='restart-resume';c=n.CodexNativeController(emit);c.handle('native_connect',params);newreceipt=json.loads((profile/'travelcat-daemon.json').read_text());report['checks']['newDaemonIdentity']=(newreceipt['pid'],newreceipt['processIdentity'])!=(receipt['pid'],receipt['processIdentity'])
 history=c.handle('native_resume',{'instanceId':key,'taskId':tid,'threadId':thread});statuses={t['id']:t['status'] for t in history['turns']}
 report['checks']['completedTurnRecoveredAfterRestart']=statuses.get(turn)=='completed';report['checks']['interruptedTurnRecoveredAfterRestart']=statuses.get(longturn)=='interrupted';report['checks']['fixedResponseRetainedAfterRestart']=contains_marker(history['items'],turn);report['checks']['noToolItems']=no_tools(history['items']);report['checks']['noBackgroundProcesses']=history['backgroundCount']==0
 report['checks']['finalQuiesce']=c.handle('native_quiesce',{})['stopped'];report['checks']['finalDaemonExited']=n._transport_module._confirmed_absent(newreceipt['pid'])
except Exception as e:report['error']={'phase':phase,'type':type(e).__name__,'message':str(e)[:250]}
finally:
 try:n._transport_module.stop_managed_daemon(params)
 except Exception as e:report['cleanupError']=type(e).__name__
 c.close()
report['durationSeconds']=round(time.monotonic()-began,3)
reportPath=root/('native-authenticated-report-'+str(uuid.uuid4())+'.json')
reportPath.write_text(json.dumps(report,indent=2));print(json.dumps({'reportPath':str(reportPath),**report}))

raise SystemExit(0 if report['checks'] and all(report['checks'].values()) and not any(k in report for k in ('error','cleanupError')) else 1)
