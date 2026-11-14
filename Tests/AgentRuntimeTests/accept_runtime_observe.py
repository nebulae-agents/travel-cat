#!/usr/bin/env python3
"""Opt-in real isolation acceptance. Setup creates its own idle container/thread;
observation itself may only read. Existing credentials stay in their temp profile.
No model generation, global Docker scans, or formal data access.
"""
import copy, json, pathlib, subprocess, sys, time, uuid
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[2]/'Sources/TravelCatApp/Resources/AgentRuntime'))
import sidecar
from types import SimpleNamespace

def main():
    if len(sys.argv)!=3 or sys.argv[1]!='--isolated-session': raise SystemExit('Requires --isolated-session temporary-session.json')
    session=pathlib.Path(sys.argv[2]).resolve(strict=True); root=session.parent
    if root.parent != pathlib.Path('/private/tmp') or not root.name.startswith('agentx-authenticated-'):
        raise SystemExit('Requires dedicated temporary acceptance root')
    report={'modelRequests':0,'docker':{},'native':{}}
    context='colima-travelcat-agent'; name='travelcat-observe-accept-'+uuid.uuid4().hex
    image='localhost:5000/travelcat-codex-acp@sha256:9e1ac8187c77450bb885f269cf82464aea77fff820fd798a6b1bd8012b838bce'
    def docker(args):
        return subprocess.run(['docker','--context',context,*args],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20,check=True).stdout.decode().strip()
    c=sidecar.Controller(); c.native.output=lambda _:None; identity=None
    phase='create'
    try:
        identity=docker(['create','--pull=never','--name',name,'--network=none','--read-only','--entrypoint','python3',image,'-c','import time; time.sleep(120)'])
        phase='start'; docker(['start',identity]); c.tasks['acceptance']=SimpleNamespace(container_id=identity,context=context,host=None,name=name)
        started=time.monotonic(); items=c.observe()['items']; report['docker']['alive']=next(i['state'] for i in items if i['kind']=='docker');report['docker']['elapsed']=round(time.monotonic()-started,3)
        docker(['stop','--time','1',identity]);report['docker']['exited']=next(i['state'] for i in c.observe()['items'] if i['kind']=='docker')
        docker(['rm',identity]);report['docker']['removed']=next(i['state'] for i in c.observe()['items'] if i['kind']=='docker');identity=None
    except Exception: report['docker']['error']='isolated_setup_or_observation_failed';report['docker']['phase']=phase
    finally:
        if identity:
            try: docker(['rm','-f',identity])
            except Exception: report['docker']['cleanup']='unconfirmed'
        c.tasks.clear(); c.native.closed.set()
    n=sidecar.codex_native; config=n._configuration(json.loads(session.read_text()));profile=pathlib.Path(config['profileRoot'])
    if n._transport_module._managed_profile_root(profile)!=root or not pathlib.Path(config['workspace']).is_relative_to(root): raise SystemExit('Profile scope mismatch')
    receipt=profile/'travelcat-daemon.json'
    if receipt.exists() and not n._transport_module._confirmed_absent(json.loads(receipt.read_text())['pid']):
        report['native']['reason']='existing_live_daemon_not_owned';print(json.dumps(report));return
    c=sidecar.Controller(); c.native.output=lambda _:None; connected=False
    try:
        result=c.native.handle('native_connect',config);connected=True
        report['native']['authenticated']=result['account']['authenticated']
        model=next((x['model'] for x in result['models'] if x.get('isDefault')),result['models'][0]['model'])
        task=str(uuid.uuid4());c.native.handle('native_start',{'instanceId':config['instanceId'],'taskId':task,'model':model})
        before=copy.deepcopy(c.native.tasks)
        transport=c.native.instances[config['instanceId']]['transport']; original=transport.request; calls=[]
        def record(method,params,**kwargs): calls.append(method);return original(method,params,**kwargs)
        transport.request=record
        began=time.monotonic();report['native']['state']=c.observe()['items'][0]['state'];report['native']['elapsed']=round(time.monotonic()-began,3)
        report['native']['onlyRead']=calls==['thread/backgroundTerminals/list']; report['native']['registryUnchanged']=before==c.native.tasks
        transport.close();report['native']['disconnected']=c.observe()['items'][0]['state']
    except Exception: report['native']['error']='isolated_setup_or_observation_failed'
    finally:
        if connected:
            c.native.close()
            try: n._transport_module.stop_managed_daemon(config)
            except Exception: report['native']['cleanup']='unconfirmed'
        else: c.native.closed.set()
    print(json.dumps(report))
if __name__=='__main__':main()
