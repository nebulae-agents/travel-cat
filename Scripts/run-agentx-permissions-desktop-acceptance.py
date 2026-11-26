#!/usr/bin/env python3
"""M4: two real sandboxed Pi apps, cancellation/restart, and durable network denial."""
import argparse
from collections import Counter
import hashlib
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import tempfile
import threading
import traceback
import types

HERE = Path(__file__).resolve().parent
multi = runpy.run_path(str(HERE / 'run-agentx-desktop-multi-app-acceptance.py'))
fixture, case = multi['fixture'], multi['case']
put = multi['pilot']['put']


def verify(workspace, bundle, server):
    root = multi['configure'](workspace, server.server_port)
    declarations = {}
    for name in ('alpha', 'beta'):
        path = root / 'apps' / name / 'app.yaml'
        app = json.loads(path.read_bytes())
        app['manifest'] = {'permissions': {'files': ['self'], 'network': ['configured-provider'],
                                           'secrets': [], 'shell': False, 'schedule': False}}
        put(path, app)
        declarations[name] = app
    marker = root / '.agentxd-pilot.json'
    config = json.loads(marker.read_bytes())
    for app in config['apps']: app['runStore'] = 'events-v1'
    put(marker, config)
    put(root / 'manager/gateway.yaml', {'version': 1, 'applications': {
        name: {'provider': 'local', 'model': 'fixture', 'max_output_tokens': 32,
               'max_request_bytes': 1048576, 'timeout_seconds': 20} for name in ('alpha', 'beta')}})
    exe, env = fixture['prepare_desktop'](workspace, bundle)
    wait = fixture['wait_for']
    rows = {}

    def get(endpoint, app, rid):
        status, row = case.exchange(endpoint, 'GET', f'/v1/apps/{app}/runs/{rid}', None)
        case.assertEqual(status, 200)
        return row

    def terminal(endpoint, app, rid):
        row = get(endpoint, app, rid)
        return row if row['status'] in ('failed', 'completed', 'cancelled') and row.get('auditStatus') == 'confirmed' else None

    with fixture['desktop'](exe, workspace, env) as (process, endpoint):
        for name in ('alpha', 'beta'):
            status, run = multi['post'](endpoint, name, 'shared', name + '-1')
            case.assertEqual(status, 201)
            rows[name] = run
            case.assertEqual(multi['post'](endpoint, name, 'shared', name + '-1'), (200, run))
        wait(lambda: len(server.calls) == 2, process, 'two sandboxed Pi requests overlap')
        receipts = [json.loads(p.read_bytes()) for p in (root / 'manager/pi-processes').glob('*.json')]
        receipt = next(r for r in receipts if r['runID'] == rows['alpha']['id'])
        child = receipt['child']['pid']
        case.assertEqual(receipt['owner'], multi['identity'](process.pid))
        case.assertEqual(receipt['child'], multi['identity'](child))
        parent = subprocess.check_output(['/bin/ps', '-p', str(child), '-o', 'ppid='], text=True)
        case.assertEqual(int(parent.strip()), process.pid)
        case.assertFalse(receipt['reaped'])
        os.kill(child, signal.SIGKILL)
        rows['alpha'] = wait(lambda: terminal(endpoint, 'alpha', rows['alpha']['id']), process, 'alpha interrupted')
        case.assertEqual((rows['alpha']['status'], rows['alpha']['stopEvidence']), ('failed', 'confirmedExited'))
        case.assertEqual(get(endpoint, 'beta', rows['beta']['id'])['status'], 'running')
        server.release.set()
        rows['beta'] = wait(lambda: terminal(endpoint, 'beta', rows['beta']['id']), process, 'beta completes')
        case.assertEqual(rows['beta']['response'], 'reply beta-1')
        code, more = multi['post'](endpoint, 'beta', 'fresh', 'beta-2')
        case.assertEqual(code, 201)
        rows['beta-2'] = wait(lambda: terminal(endpoint, 'beta', more['id']), process, 'beta remains usable')
        case.assertEqual(rows['beta-2']['response'], 'reply beta-2')
        for row in rows.values():
            audit = multi['cli'](root, row['appID'], 'audit', row['id'])
            case.assertTrue(audit['verified'])
            case.assertEqual(audit['auditStatus'], 'confirmed')
            other = 'beta' if row['appID'] == 'alpha' else 'alpha'
            case.assertEqual(case.exchange(endpoint, 'GET', f'/v1/apps/{other}/runs/{row["id"]}', None)[0], 404)
    case.assertEqual(Counter(p for p, _ in server.calls), {'alpha-1': 1, 'beta-1': 1, 'beta-2': 1})
    # Revoke beta's network grant on disk. Restart reloads the manifest; no migration grants it back.
    path = root / 'apps/beta/app.yaml'
    # The host rewrites app.yaml as YAML; keep the fixture declaration, not JSON-parse it.
    revoked = declarations['beta']
    revoked['manifest']['permissions']['network'] = []
    put(path, revoked)
    with fixture['desktop'](exe, workspace, env) as (process, endpoint):
        for row in rows.values():
            case.assertEqual(get(endpoint, row['appID'], row['id']), row)
        code, denied = multi['post'](endpoint, 'beta', 'denied', 'beta-2')
        case.assertEqual(code, 201)
        denied = wait(lambda: terminal(endpoint, 'beta', denied['id']), process, 'network permission denial')
        case.assertEqual(denied['status'], 'failed')
        events = [json.loads(p.read_bytes()) for p in (root / 'apps/beta/events/permissions').glob('*.json')]
        case.assertTrue(any(e.get('kind') == 'permission.denied' and e.get('operation') == 'network.connect'
                            and e.get('source') == 'host_policy' and e.get('runID') == denied['id'] for e in events))
        case.assertEqual(len(server.calls), 3)
    event_files = list((root / 'apps/beta/events/permissions').glob('*.json'))
    case.assertTrue(event_files)
    return {'desktopStarts': 2, 'successfulProviderCalls': 3, 'permissionDeniedEvents': len(event_files),
            'checks': ['concurrent sandboxed Pi', 'alpha exit evidence', 'beta continuity', 'audit verification',
                       'cross-app run denial', 'restart readback', 'revoked network blocked before provider', 'durable denial event']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pi_bundle', type=Path)
    parser.add_argument('--products', type=Path, help='Optional immutable product directory containing TravelCatApp')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    if args.products:
        original = fixture['pilot']['temporary_app']
        class PinnedSubprocess:
            def __getattr__(self, name): return getattr(subprocess, name)
            def check_output(self, command, **kwargs):
                if len(command) == 2 and command[1] == 'scratch-path': return str(args.products.parent) + '\n'
                return subprocess.check_output(command, **kwargs)
        if args.products.name != 'debug': parser.error('--products must be named debug')
        fixture['pilot']['temporary_app'] = types.FunctionType(original.__code__, dict(original.__globals__, subprocess=PinnedSubprocess()))
    workspace = Path(tempfile.mkdtemp(prefix='agentxd-pi-e2e-m4-', dir='/private/tmp'))
    server = ThreadingHTTPServer(('127.0.0.1', 0), multi['Model'])
    server.calls, server.release, server.lock = [], threading.Event(), threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = verify(workspace, args.pi_bundle, server)
        if args.products: result['binarySHA256'] = hashlib.sha256((args.products / 'TravelCatApp').read_bytes()).hexdigest()
        result['status'] = 'passed'
        (args.output / 'summary.json').write_text(json.dumps(result, indent=2))
        shutil.copy2(workspace / 'gui.log', args.output / 'gui.log')
        shutil.rmtree(workspace)
        print(json.dumps(result))
    except BaseException:
        (args.output / 'failure.json').write_text(json.dumps({'workspace': str(workspace), 'traceback': traceback.format_exc()}, indent=2))
        raise
    finally:
        server.release.set(); server.shutdown(); server.server_close()


if __name__ == '__main__': main()
