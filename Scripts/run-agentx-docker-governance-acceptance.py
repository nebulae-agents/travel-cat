#!/usr/bin/env python3
"""Disruptive opt-in probe restricted to the local empty travelcat-agent Colima profile.
Requires an exclusive maintenance window for this entire dedicated VM, an already
running profile and no existing containers. The empty-container check is only a
point-in-time guard; do not launch other VM work until the probe finishes. Creates one real ACP
session, stops/restarts the VM, verifies unconfirmed stop then retry/cleanup. Leaves
the profile running as it found it, and retains a temporary sanitized evidence report.
Usage: python3 Scripts/run-agentx-docker-governance-acceptance.py --allow-empty-profile-disconnect
"""
import sys, pathlib, uuid, json, subprocess, tempfile, time
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1] / 'Sources/TravelCatApp/Resources/AgentRuntime'))
import sidecar
context='colima-travelcat-agent'
image='localhost:5000/travelcat-codex-acp@sha256:9e1ac8187c77450bb885f269cf82464aea77fff820fd798a6b1bd8012b838bce'
def docker(args):
 return subprocess.run(['docker','--context',context]+args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30)
if sys.argv[1:]!=['--allow-empty-profile-disconnect']: raise SystemExit('Explicit empty-profile disconnect opt-in required')
endpoint=subprocess.run(['docker','context','inspect',context,'--format','{{.Endpoints.docker.Host}}'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10)
expected='unix://'+str(pathlib.Path.home()/'.colima/travelcat-agent/docker.sock')
if endpoint.returncode!=0 or endpoint.stdout.decode().strip()!=expected: raise SystemExit('Requires the exact local travelcat-agent socket')
before=docker(['ps','-aq'])
if before.returncode!=0 or before.stdout.strip(): raise SystemExit('Requires reachable Docker with no existing containers')
report={'checks':{},'context':context,'image':image}; root=pathlib.Path(tempfile.mkdtemp(prefix='agentx-real-docker-'))
c=sidecar.Controller(); c.emit=lambda _:None
p=sidecar.Provider({'baseURL':'https://127.0.0.1/v1','api':'responses','model':'probe-only','apiKey':'probe-only'})
t=sidecar.Task(str(uuid.uuid4()),{'image':image,'command':['/opt/travelcat-acp/node_modules/.bin/codex-acp'],'dockerContext':context},p,lambda _:None)
c.tasks[t.task_id]=t
try:
 started=t.start(); report['checks']['acpSession']=bool(started['sessionId'])
 info=json.loads(docker(['inspect',t.name]).stdout)[0]; report['containerId']=info['Id']
 report['checks']['restrictedContainer']=info['HostConfig']['NetworkMode']=='none' and info['HostConfig']['ReadonlyRootfs'] and info['Config']['User']=='65532:65532' and all(x['Type']=='tmpfs' for x in info['Mounts'])
 report['checks']['liveOwnedClients']=t.process.poll() is None and t.relay.poll() is None
 current=docker(['ps','-aq','--no-trunc'])
 if current.returncode!=0 or current.stdout.decode().split()!=[report['containerId']]:
  raise RuntimeError('Exclusive profile changed; refusing VM disconnect')
 subprocess.run(['colima','stop','--profile','travelcat-agent'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60,check=True)
 report['checks']['daemonDisconnected']=docker(['info']).returncode!=0
 failed=c.quiesce(); report['checks']['disconnectedStopUnconfirmed']=failed['stopped'] is False and t.task_id in c.tasks
 subprocess.run(['colima','start','--profile','travelcat-agent','--activate=false'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90,check=True)
 report['checks']['daemonRecovered']=docker(['info']).returncode==0
 report['checks']['retryConfirmed']=c.quiesce()['stopped'] is True
 absent=docker(['container','inspect',report['containerId']]);report['checks']['exactContainerAbsent']=absent.returncode!=0 and b'No such' in absent.stderr and docker(['info']).returncode==0
 report['checks']['clientsReaped']=t.process.poll() is not None and t.relay.poll() is not None
 report['checks']['registryEmpty']=not c.tasks
 report['checks']['repeatConfirmed']=c.quiesce()['stopped'] is True
except Exception as e: report['error']=str(e)
finally:
 try:
  if docker(['info']).returncode!=0: subprocess.run(['colima','start','--profile','travelcat-agent','--activate=false'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90,check=True)
  report['cleanupConfirmed']=t.stop()['stopped']
 except Exception as e: report['cleanupError']=str(e)
 c.native.close()
(root/'report.json').write_text(json.dumps(report,indent=2));print(json.dumps({'root':str(root),**report}))

raise SystemExit(0 if report['checks'] and all(report['checks'].values()) and report.get('cleanupConfirmed') is True and not any(k in report for k in ('error','cleanupError')) else 1)
