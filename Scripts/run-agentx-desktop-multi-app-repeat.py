#!/usr/bin/env python3
"""Repeat the complete isolated multi-app acceptance with pinned build products."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import traceback
import types


def utc():
    return datetime.now(timezone.utc).isoformat()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, type=Path)
    parser.add_argument('--products', required=True, type=Path)
    parser.add_argument('--pi-bundle', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--rounds', type=int, default=50)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error('rounds must be positive')
    os.umask(0o077)
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    pinned = args.output / 'pinned/debug'
    pinned.mkdir(parents=True)
    for name in ('TravelCatApp', 'TravelCat_TravelUI.bundle', 'TravelCat_TravelCatApp.bundle'):
        source, target = args.products / name, pinned / name
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
    baseline = digest(pinned / 'TravelCatApp')
    if baseline != digest(args.products / 'TravelCatApp'):
        raise RuntimeError('build changed while pinning')
    source_snapshot = args.output / 'source'
    dependency_names = ('Scripts/run-agentx-desktop-multi-app-acceptance.py',
        'Scripts/run-agentx-desktop-writer-acceptance.py', 'Scripts/run-agentx-pi-pilot-acceptance.py',
        'Scripts/agentx', 'Tests/AgentRuntimeTests/test_agentxd_api_contract.py',
        'Runtime/agentxd_pi.py', 'Runtime/PiAgent/runner.mjs')
    for name in dependency_names:
        target = source_snapshot / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(args.repo / name, target)
    harness = runpy.run_path(str(source_snapshot / 'Scripts/run-agentx-desktop-multi-app-acceptance.py'))
    fixture = harness['fixture']
    original_stage = fixture['pilot']['temporary_app']
    # Keep the original staging and safety checks; only redirect its scratch-path lookup.
    class PinnedSubprocess:
        def __getattr__(self, name):
            return getattr(subprocess, name)
        def check_output(self, command, **kwargs):
            if len(command) == 2 and command[1] == 'scratch-path':
                return str(pinned.parent) + '\n'
            return subprocess.check_output(command, **kwargs)
    staging_globals = dict(original_stage.__globals__, subprocess=PinnedSubprocess())
    fixture['pilot']['temporary_app'] = types.FunctionType(original_stage.__code__, staging_globals)
    meta = {'startedAt': utc(), 'head': subprocess.check_output(['git', '-C', str(args.repo), 'rev-parse', 'HEAD'], text=True).strip(),
            'binarySHA256': baseline, 'roundsRequested': args.rounds, 'sourceProducts': str(args.products),
            'piBundle': str(args.pi_bundle), 'scope': 'isolated baseline dual-app acceptance; no UI automation',
            'sourceFiles': {name: digest(source_snapshot / name) for name in dependency_names},
            'pinnedFiles': {str(p.relative_to(pinned)): digest(p) for p in pinned.rglob('*') if p.is_file()}}
    (args.output / 'metadata.json').write_text(json.dumps(meta, indent=2))
    print(json.dumps({'snapshotReady': True, 'binarySHA256': baseline, 'output': str(args.output)}), flush=True)
    current = {}

    @contextmanager
    def measured_desktop(exe, workspace, env, *, interrupt=False):
        endpoint = workspace / 'root/.agentxd-endpoint.json'
        previous = endpoint.read_bytes() if endpoint.exists() else None
        launch = {'startedAt': utc(), 'endpointPresentBefore': endpoint.exists()}
        current['launches'].append(launch)
        started = time.monotonic()
        with (workspace / 'gui.log').open('ab') as output, subprocess.Popen([exe], env=env, cwd=workspace, stdout=output, stderr=output) as app:
            launch['pid'] = app.pid
            try:
                fixture['wait_for'](lambda: endpoint.is_file() and endpoint.read_bytes() != previous, app,
                                    'ordinary desktop did not publish its run endpoint')
                launch['endpointReadySeconds'] = round(time.monotonic() - started, 6)
                launch['endpointPublishedAt'] = utc()
                value = json.loads(endpoint.read_bytes())
                launch['endpointKeys'] = sorted(value)
                launch['endpointPort'] = value.get('port')
                yield app, value
            except BaseException as error:
                launch['failedAt'] = utc()
                launch['elapsedAtFailureSeconds'] = round(time.monotonic() - started, 6)
                launch['errorType'] = type(error).__name__
                launch['endpointExistsAtFailure'] = endpoint.exists()
                if endpoint.exists():
                    stat = endpoint.stat()
                    launch['endpointMetadata'] = {'bytes': stat.st_size, 'mtimeNs': stat.st_mtime_ns, 'mode': oct(stat.st_mode & 0o777)}
                launch['processReturnCodeAtFailure'] = app.poll()
                # Process arguments/environment can carry secrets; collect state and executable name only.
                proc = subprocess.run(['/bin/ps', '-axo', 'pid,ppid,stat,etime,comm'], capture_output=True, text=True, timeout=5)
                (workspace / 'processes-at-failure.txt').write_text(proc.stdout)
                raise
            finally:
                if app.poll() is None:
                    app.terminate()
                    try:
                        app.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        app.kill()
                        app.wait()
                        launch['forcedKill'] = True
                launch['returnCode'] = app.returncode
                launch['endedAt'] = utc()
                launch['endpointExistsAfterExit'] = endpoint.exists()
        harness['case'].assertEqual(app.returncode, -signal.SIGKILL if interrupt else 0)
        if not interrupt:
            harness['case'].assertFalse(endpoint.exists())
    fixture['desktop'] = measured_desktop
    results = []
    for number in range(1, args.rounds + 1):
        workspace = Path(tempfile.mkdtemp(prefix='agentxd-pi-e2e-f102-', dir='/private/tmp'))
        current = {'round': number, 'startedAt': utc(), 'workspace': str(workspace), 'launches': []}
        begin = time.monotonic()
        try:
            if digest(pinned / 'TravelCatApp') != baseline:
                raise RuntimeError('pinned binary changed')
            with harness['ThreadingHTTPServer'](('127.0.0.1', 0), harness['Model']) as server:
                server.calls, server.release, server.lock = [], threading.Event(), threading.Lock()
                threading.Thread(target=server.serve_forever, daemon=True).start()
                try:
                    harness['verify'](workspace, args.pi_bundle, server)
                    current['modelCalls'] = [prompt for prompt, _ in server.calls]
                finally:
                    server.release.set()
                    server.shutdown()
            current['status'] = 'passed'
        except Exception as error:
            current['status'] = 'failed'
            current['errorType'] = type(error).__name__
            current['error'] = str(error)
            (workspace / 'failure-traceback.txt').write_text(traceback.format_exc())
        current['durationSeconds'] = round(time.monotonic() - begin, 6)
        current['endedAt'] = utc()
        results.append(current)
        with (args.output / 'rounds.jsonl').open('a') as out:
            out.write(json.dumps(current) + '\n')
        if current['status'] == 'passed':
            shutil.copy2(workspace / 'gui.log', args.output / f'round-{number:02d}-gui.log')
            shutil.rmtree(workspace)
            current['workspaceRetained'] = False
        else:
            current['workspaceRetained'] = True
        print(json.dumps({'round': number, 'status': current['status'], 'durationSeconds': current['durationSeconds'],
                          'startupSeconds': [v.get('endpointReadySeconds') for v in current['launches']]}), flush=True)
    summary = {'startedAt': meta['startedAt'], 'endedAt': utc(), 'head': meta['head'], 'binarySHA256': baseline,
               'rounds': len(results), 'passed': sum(r['status'] == 'passed' for r in results),
               'failed': sum(r['status'] == 'failed' for r in results), 'results': results}
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps({k: v for k, v in summary.items() if k != 'results'}), flush=True)
    return bool(summary['failed'])


if __name__ == '__main__':
    raise SystemExit(main())
