#!/usr/bin/env python3
"""Run Swift tests without publishing raw compiler/assertion/subprocess output.

Only identities present in public test source and fixed numeric outcomes survive.
This is a result index, not a compiler log or a substitute for the process status.
"""
import argparse
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile
import threading
import time

CASE = re.compile(r"^Test Case '-\[[A-Za-z0-9_]+\.([A-Za-z0-9_]+) ([A-Za-z0-9_]+)\]' (passed|failed|skipped) \(([0-9.]+) seconds\)\.$")
AGGREGATE = re.compile(r'^[✔✘] Test run with ([0-9]+) tests(?: in [0-9]+ suites)? (passed|failed) after [0-9.]+ seconds(?: with [0-9]+ issues?)?\.$')
ANSI = re.compile(r'\x1b\[[0-9;]*m')
MAX_LINE = 8192

def public_test_names(root):
    names = set()
    for path in (Path(root) / 'Tests').rglob('*.swift'):
        text = path.read_text(encoding='utf-8')
        suites = re.findall(r'\b(?:class|struct|extension)\s+([A-Za-z_][A-Za-z0-9_]{0,127})\b', text)
        methods = re.findall(r'\bfunc\s+([A-Za-z_][A-Za-z0-9_]{0,127})\s*\(', text)
        names.update(f'{suite}.{method}' for suite in suites for method in methods)
    return names

class ResultCollector:
    def __init__(self, known_names, limit=5000):
        self.known_names = known_names
        self.limit = min(5000, max(0, limit))
        self.tests = []
        self.swift_testing = None
        self.truncated = False
    def consume(self, line):
        if len(line) > MAX_LINE: return
        line = ANSI.sub('', line.rstrip('\r\n'))
        if match := CASE.fullmatch(line):
            suite, method, outcome, duration = match.groups()
            name = f'{suite}.{method}'
            if name not in self.known_names: return
            seconds = float(duration)
            if not math.isfinite(seconds) or not 0 <= seconds <= 86400: return
            if len(self.tests) >= self.limit:
                self.truncated = True
                return
            self.tests.append({'name': name, 'outcome': outcome, 'durationSeconds': seconds})
        elif match := AGGREGATE.fullmatch(line):
            count, outcome = match.groups()
            if int(count) <= 100000:
                previous = self.swift_testing or {'testCount': 0, 'outcome': 'passed'}
                self.swift_testing = {'testCount': min(100000, previous['testCount'] + int(count)),
                                      'outcome': 'failed' if outcome == 'failed' or previous['outcome'] == 'failed' else 'passed'}

def safe_metadata(value):
    rules = {
        'sourceRevision': lambda v: isinstance(v, str) and re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', v),
        'sourceDirty': lambda v: isinstance(v, bool),
        'swiftVersion': lambda v: isinstance(v, str) and re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', v),
        'timezone': lambda v: v in ('UTC', 'Asia/Shanghai', 'unspecified'),
        'platform': lambda v: v in ('Darwin', 'Linux', 'Windows', 'other'),
        'architecture': lambda v: v in ('arm64', 'x86_64', 'aarch64', 'other'),
        'selection': lambda v: v in ('utc', 'shanghai', 'local'),
    }
    result = {}
    for key, valid in rules.items():
        item = (value or {}).get(key)
        if valid(item): result[key] = item
    return result

def write_report(output, report):
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=output.parent, delete=False) as temporary:
        name = temporary.name
        try:
            json.dump(report, temporary, ensure_ascii=True, separators=(',', ':'))
            temporary.write('\n'); temporary.flush()
        except BaseException:
            os.unlink(name)
            raise
    try: os.replace(name, output)
    finally:
        if os.path.exists(name): os.unlink(name)

def run_tests(command, output, known_names, timeout=1500, metadata=None):
    try: Path(output).unlink(missing_ok=True)
    except OSError:
        print('{"reportStatus":"reportWriteFailed","exitCode":73}')
        return 73
    collector = ResultCollector(known_names)
    start = time.monotonic()
    reason = []
    process = None
    timers = []
    previous = {}
    cleanup_done = threading.Event()
    process_lock = threading.RLock()
    def send_owned(sig):
        with process_lock:
            if process is None or cleanup_done.is_set(): return
            try: os.killpg(process.pid, sig)
            except ProcessLookupError: pass
    def stop(why, sig=signal.SIGTERM):
        if not reason: reason.append((why, sig))
        send_owned(sig)
        grace = threading.Timer(2, lambda: send_owned(signal.SIGKILL))
        grace.daemon = True; timers.append(grace); grace.start()
    try:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        if threading.current_thread() is threading.main_thread():
            for sig in (signal.SIGTERM, signal.SIGINT):
                previous[sig] = signal.signal(sig, lambda number, frame: stop('interrupted', number))
        timer = threading.Timer(max(0.01, timeout), lambda: stop('timedOut'))
        timer.daemon = True; timers.append(timer); timer.start()
        # readline's size bound prevents unbounded assertion lines. Ignore every
        # fragment of an oversized line, not only its first chunk.
        dropping = False
        with process.stdout:
            while raw := process.stdout.readline(MAX_LINE + 1):
                oversized = len(raw) > MAX_LINE
                if not dropping and not oversized:
                    collector.consume(raw.decode('utf-8', errors='replace'))
                dropping = not raw.endswith(b'\n') if dropping or oversized else False
        exit_code = process.wait()
        if exit_code < 0: exit_code = 128 - exit_code
        if reason: exit_code = 124 if reason[0][0] == 'timedOut' else 128 + reason[0][1]
        status = reason[0][0] if reason else ('testsRecorded' if collector.tests or collector.swift_testing else 'resultsUnavailable')
    except OSError:
        # Do not serialize error descriptions: they can contain private paths.
        exit_code = 127; status = 'launchFailed'
    finally:
        if process is not None:
            # A dead group leader does not imply that TERM-ignoring descendants
            # exited. Complete owned-group cleanup before cancelling escalation.
            if reason or process.poll() is None: send_owned(signal.SIGKILL)
            if process.poll() is None: process.wait(timeout=5)
        with process_lock: cleanup_done.set()
        for timer in timers: timer.cancel()
        for sig, handler in previous.items(): signal.signal(sig, handler)
    counts = {outcome: sum(t['outcome'] == outcome for t in collector.tests) for outcome in ('passed', 'failed', 'skipped')}
    report = {'schemaVersion': 1, 'environment': safe_metadata(metadata), 'exitCode': exit_code,
              'reportStatus': status, 'durationSeconds': round(max(0, time.monotonic() - start), 3),
              'xctest': counts, 'swiftTesting': collector.swift_testing,
              'truncated': collector.truncated, 'tests': collector.tests}
    try: write_report(output, report)
    except OSError:
        # Keep original failures; fail successful tests if their result cannot be
        # published. Never leave an old report or print a filesystem error body.
        exit_code = exit_code or 73
        print(json.dumps({'reportStatus': 'reportWriteFailed', 'exitCode': exit_code}))
        return exit_code
    print(json.dumps({'reportStatus': status, 'exitCode': exit_code, 'xctest': counts, 'swiftTesting': collector.swift_testing}, sort_keys=True))
    return exit_code

def environment(root, selection):
    def capture(command):
        try: return subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=15).stdout
        except (OSError, subprocess.TimeoutExpired): return ''
    version = re.search(r'Swift version ([0-9]+\.[0-9]+(?:\.[0-9]+)?)', capture(['swift', '--version']))
    tz = os.environ.get('TZ', 'unspecified')
    machine = platform.machine()
    system = platform.system()
    return {'sourceRevision': capture(['git', 'rev-parse', 'HEAD']).strip(),
            'sourceDirty': bool(capture(['git', 'status', '--porcelain'])),
            'swiftVersion': version.group(1) if version else None,
            'timezone': tz if tz in ('UTC', 'Asia/Shanghai') else 'unspecified',
            'platform': system if system in ('Darwin', 'Linux', 'Windows') else 'other',
            'architecture': machine if machine in ('arm64', 'x86_64', 'aarch64') else 'other', 'selection': selection}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--selection', choices=('utc', 'shanghai', 'local'), default='local')
    parser.add_argument('--timeout-seconds', type=int, default=1500, choices=range(1, 1701), metavar='1..1700')
    parser.add_argument('arguments', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    forwarded = args.arguments[1:] if args.arguments[:1] == ['--'] else args.arguments
    return run_tests([str(root / 'Scripts/travel-cat-swift.sh'), 'test', *forwarded], args.output,
                     public_test_names(root), timeout=args.timeout_seconds, metadata=environment(root, args.selection))

if __name__ == '__main__': raise SystemExit(main())
