#!/usr/bin/env python3
"""Check (or stop) only a fresh preview's first-owned, fully matched Native daemon.

Close the preview after recording terminal/background-zero metadata. This script
preserves the profile, receipt and all official account state as evidence.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import time

RUNTIME = Path(__file__).resolve().parents[1] / 'Sources/TravelCatApp/Resources/AgentRuntime'
spec = importlib.util.spec_from_file_location('acceptance_transport', RUNTIME / 'codex_native_transport.py')
transport = importlib.util.module_from_spec(spec)
spec.loader.exec_module(transport)


def verify(root):
    root = Path(root).resolve(strict=True)
    fixture = json.loads(transport._read_private(root / 'fixture.json'))
    owner = json.loads(transport._read_private(root / 'daemon-ownership.json'))
    metadata = json.loads(transport._read_private(root / 'acceptance-metadata.json'))
    if owner.get('firstLaunchOwned') is not True: raise ValueError('daemon was reused or ownership was not captured')
    if metadata.get('clientDetached') is not True: raise ValueError('preview must detach before cleanup')
    if metadata.get('sidecarExitConfirmed') is not True: raise ValueError('actual sidecar exit is unconfirmed')
    if not 0 <= time.time() - metadata.get('recordedAt', 0) <= 120: raise ValueError('terminal/background evidence is stale')
    if metadata.get('instanceId') != fixture['instanceId']: raise ValueError('metadata instance mismatch')
    for task in metadata['tasks']:
        if task['instanceId'] != fixture['instanceId'] or task['status'] not in ('completed', 'cancelled', 'failed') or task['backgroundCount'] != 0:
            raise ValueError('task is active or background-zero is unconfirmed')
        if not task['threadId'] or not task['turnStatuses'] or any(s not in ('completed', 'failed', 'interrupted') for s in task['turnStatuses'].values()):
            raise ValueError('official terminal turn evidence is missing')
    params = owner['parameters']
    # The operator may change the initial detected executable in production setup.
    # Bind the successful first connection's exact program to its own receipt.
    executable = params.get('executable')
    if not isinstance(executable, str) or not executable.startswith('/') or len(executable) > 4096 or any(c in executable for c in ('\0', '\n')):
        raise ValueError('invalid first-connected executable')
    profile = root / 'store/native-runtime' / fixture['instanceId']
    if profile.is_symlink() or params != {'instanceId': fixture['instanceId'], 'profileRoot': str(profile), 'workspace': str(root / 'workspace'), 'executable': executable}:
        raise ValueError('fixture configuration identity mismatch')
    receipt_bytes = transport._read_private(profile / 'travelcat-daemon.json')
    if hashlib.sha256(receipt_bytes).hexdigest() != owner['receiptSHA256']: raise ValueError('receipt changed')
    receipt = json.loads(receipt_bytes)
    if receipt != owner['receipt']: raise ValueError('receipt identity changed')
    socket_dir = Path('/private/tmp') / ('tc-native-' + str(os.getuid()) + '-' + hashlib.sha256(str(profile).encode()).hexdigest()[:24])
    sock = socket_dir / 'server.sock'
    expected = {'profileRoot': str(profile), 'workspace': fixture['workspace'], 'executable': executable, 'socket': str(sock),
                'configHash': hashlib.sha256(transport._config_text(params, socket_dir)).hexdigest()}
    if any(receipt.get(k) != v for k, v in expected.items()): raise ValueError('daemon configuration receipt mismatch')
    if hashlib.sha256(transport._read_private(profile / 'config.toml')).hexdigest() != receipt['configHash']: raise ValueError('daemon config changed')
    identity = transport._process_identity(receipt['pid'])
    if identity != receipt['processIdentity'] or str(sock) not in identity or 'app-server' not in identity:
        raise ValueError('daemon process identity changed')
    if transport._socket_info(sock).st_ino != receipt['socketInode']: raise ValueError('daemon socket identity changed')
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--stop', action='store_true', help='send TERM only after all identity and terminal checks pass')
    args = parser.parse_args()
    receipt = verify(args.root)
    result = {'identityMatched': True, 'firstLaunchOwned': True, 'pid': receipt['pid'], 'stopped': False}
    if args.stop:
        # Recheck at the mutation boundary; never signal a reused or replaced PID.
        if transport._process_identity(receipt['pid']) != receipt['processIdentity']: raise ValueError('process changed before stop')
        os.kill(receipt['pid'], signal.SIGTERM)
        deadline = time.monotonic() + 10
        while transport._process_identity(receipt['pid']) == receipt['processIdentity'] and time.monotonic() < deadline: time.sleep(.05)
        if transport._process_identity(receipt['pid']) is not None: raise ValueError('daemon exit unconfirmed; preserve all evidence')
        result['stopped'] = True
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    try: main()
    except (OSError, ValueError, KeyError, TypeError, transport.NativeFailure) as error:
        raise SystemExit('Native acceptance cleanup refused: ' + str(error)) from None
