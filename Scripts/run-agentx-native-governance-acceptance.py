#!/usr/bin/env python3
"""Opt-in real official app-server lifecycle probe; retains isolated evidence, never copies login.
Usage: python3 Scripts/run-agentx-native-governance-acceptance.py /absolute/path/to/codex
"""
import sys, tempfile, pathlib, uuid, json, time
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'Sources/TravelCatApp/Resources/AgentRuntime'))
import codex_native as n
if len(sys.argv)!=2 or not pathlib.Path(sys.argv[1]).is_absolute(): raise SystemExit('Pass the absolute official Codex executable')
root=pathlib.Path(tempfile.mkdtemp(prefix='agentx-real-native-')).resolve()
key=str(uuid.uuid4()); workspace=root/'workspace'; workspace.mkdir()
profile=root/'apps/workbench/state/runtime/native-runtime'/key
params={'instanceId':key,'workspace':str(workspace),'profileRoot':str(profile),'executable':sys.argv[1]}
report={'root':str(root),'checks':{}}; c=n.CodexNativeController(lambda _:None)
try:
 result=c.handle('native_connect',params)
 report['checks']['connect']=result['connected']; report['version']=result['version']; report['authenticated']=result['account']['authenticated']; report['modelCount']=len(result['models'])
 receipt=json.loads((profile/'travelcat-daemon.json').read_text()); pid=receipt['pid']; report['pid']=pid
 c.close(); report['checks']['detachPreservesDaemon']=n._transport_module._process_identity(pid)==receipt['processIdentity']
 c=n.CodexNativeController(lambda _:None); c.handle('native_connect',params)
 report['checks']['reconnectSameDaemon']=json.loads((profile/'travelcat-daemon.json').read_text())['pid']==pid
 taskid=str(uuid.uuid4()); started=c.handle('native_start',{'instanceId':key,'taskId':taskid,'model':result['models'][0]['model']})
 report['checks']['realIdleThreadStarted']=bool(started['threadId'])
 report['checks']['idleBackgroundStopped']=c.handle('native_background_stop',{'taskId':taskid})['stopped']
 report['checks']['quiesce']=c.handle('native_quiesce',{})=={'stopped':True}
 report['checks']['exitConfirmed']=n._transport_module._confirmed_absent(pid)
 report['checks']['retryQuiesce']=c.handle('native_quiesce',{})=={'stopped':True}
 try: c.handle('native_connect',params); report['checks']['sealed']=False
 except n.NativeFailure: report['checks']['sealed']=True
 c.close(); c=n.CodexNativeController(lambda _:None); c.handle('native_connect',params)
 new=json.loads((profile/'travelcat-daemon.json').read_text())
 report['checks']['restartNewIdentity']=(new['pid'],new['processIdentity'])!=(receipt['pid'],receipt['processIdentity'])
 report['checks']['restartQuiesce']=c.handle('native_quiesce',{})=={'stopped':True}
 report['checks']['restartExitConfirmed']=n._transport_module._confirmed_absent(new['pid'])
except Exception as e: report['error']=str(e)
finally:
 try: n._transport_module.stop_managed_daemon(params)
 except Exception as e: report['cleanupError']=str(e)
 c.close()
(root/'report.json').write_text(json.dumps(report,indent=2)); print(json.dumps(report))

raise SystemExit(0 if report['checks'] and all(report['checks'].values()) and not any(k in report for k in ('error','cleanupError')) else 1)
