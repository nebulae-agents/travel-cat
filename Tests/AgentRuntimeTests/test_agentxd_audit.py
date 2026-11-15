"""Lifecycle audit outbox: no real Keychain, models, or user roots."""
import copy
import json
from unittest.mock import patch

import test_agentxd_runs as fixtures
from agentxd import RunStore
from agentxd_runs import CommandError


class MemoryAudit:
    def __init__(self):
        self.rows = {}
        self.fail = False

    def append(self, record):
        if self.fail:
            raise OSError('private error must not escape')
        key = record['eventId']
        if key in self.rows and self.rows[key] != record:
            raise ValueError('conflicting event')
        self.rows[key] = copy.deepcopy(record)

    def records(self, run_id):
        return [v for v in self.rows.values() if v['taskId'] == run_id]

    def verify(self):
        return len(self.rows)


class TestAuditedCommands(fixtures.TestPilotCommands):
    def setUp(self):
        super().setUp()
        self.audit = MemoryAudit()
        self.store.audit = self.audit

    def test_lifecycle_metadata_and_repeat_create(self):
        _, run = self.service.create('key', self.body)
        self.assertTrue(self.children[0].launched.wait(2))
        self.service.create('key', self.body)
        self.service.stop(run['id'], 'stop')
        self.children[0].finish.set()
        self.service.close()
        rows = self.audit.records(run['id'])
        self.assertEqual([r['kind'] for r in rows], ['model.request.started', 'model.request.cancel_requested', 'model.request.cancelled'])
        self.assertEqual(len({r['eventId'] for r in rows}), 3)
        self.assertNotIn('hello', json.dumps(rows))
        self.assertNotIn('System', json.dumps(rows))
        self.assertEqual(rows[0]['requestTextBytes'], len(b'Systemhello'))
        self.assertEqual(self.store.get(run['id'])['auditStatus'], 'confirmed')

    def test_start_failure_never_launches_child_and_blocks_new_run(self):
        self.audit.fail = True
        with self.assertRaises(CommandError) as rejected:
            self.service.create('key', self.body)
        self.assertEqual(rejected.exception.reason, 'audit_unavailable')
        self.assertFalse(any(child.launched.is_set() for child in self.children))
        run = self.store.list_runs()[0]
        self.assertEqual((run['status'], run['auditStatus']), ('failed', 'pending'))
        with self.assertRaises(CommandError):
            self.service.create('another', self.body)

    def test_terminal_audit_failure_preserves_result_and_recovers_without_duplicate(self):
        _, run = self.service.create('key', self.body)
        child = self.children[0]
        self.assertTrue(child.launched.wait(2))
        worker = self.service.workers[run['id']][1]
        self.audit.fail = True
        child.finish.set()
        worker.join(3)
        saved = self.store.get(run['id'])
        self.assertEqual((saved['status'], saved['auditStatus']), ('completed', 'pending'))
        self.audit.fail = False
        self.make()
        self.assertEqual(self.store.get(run['id'])['auditStatus'], 'confirmed')
        self.assertEqual(len(self.audit.rows), 2)
        self.make()
        self.assertEqual(len(self.audit.rows), 2)

    def test_cancel_audit_failure_still_signals_stop(self):
        _, run = self.service.create('key', self.body)
        self.assertTrue(self.children[0].launched.wait(2))
        self.audit.fail = True
        code, pending = self.service.stop(run['id'], 'stop')
        self.assertEqual((code, self.children[0].stops), (202, 1))
        self.assertEqual(pending['auditStatus'], 'pending')
        self.assertTrue(pending['auditFailure'])
        self.assertNotIn('private error', pending['auditFailure'])
        self.children[0].finish.set()

    def test_cancel_run_write_failure_still_signals_stop(self):
        _, run = self.service.create('key', self.body)
        self.assertTrue(self.children[0].launched.wait(2))
        with patch('agentxd.write_json', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                self.service.stop(run['id'], 'stop')
        self.assertEqual(self.children[0].stops, 1)
        self.children[0].finish.set()

    def test_ack_write_crash_replays_identical_event(self):
        import agentxd
        original = agentxd.write_json
        def fail_ack(path, run):
            if run.get('auditStatus') == 'confirmed':
                raise OSError('crash after append')
            return original(path, run)
        with patch('agentxd.write_json', side_effect=fail_ack):
            with self.assertRaises(CommandError):
                self.service.create('key', self.body)
        self.make()
        self.assertEqual(len(self.audit.rows), 2)
        self.assertEqual(self.store.list_runs()[0]['auditStatus'], 'confirmed')

    def test_legacy_history_is_not_backfilled(self):
        old = dict(id='legacy', appID='pilot', instanceID='pi', status='completed', revision=1)
        self.store.insert(old)
        self.make()
        self.assertEqual(self.audit.rows, {})
        self.assertNotIn('auditStatus', self.store.get('legacy'))

    def test_authenticated_query_checks_chain_and_cli_reads_same_run(self):
        import http.client
        import threading
        import subprocess
        import sys
        from pathlib import Path
        from http.server import ThreadingHTTPServer
        from agentxd import Handler
        _, run = self.service.create('key', self.body)
        self.assertTrue(self.children[0].launched.wait(2))
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        server.authorization = b'Bearer fixture'
        server.store, server.pilot = self.store, self.service
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            client = http.client.HTTPConnection('127.0.0.1', server.server_port)
            path = '/v1/apps/pilot/runs/' + run['id'] + '/audit'
            client.request('GET', path)
            response = client.getresponse()
            self.assertEqual(response.status, 401)
            response.read()
            client.request('GET', path, headers={'Authorization':'Bearer fixture'})
            response = client.getresponse()
            self.assertEqual(response.status, 200)
            result = json.load(response)
            self.assertEqual(result['records'], self.audit.records(run['id']))
            self.assertTrue(result['verified'])
            client.close()
            endpoint = self.store.directory.parents[2] / '.agentxd-endpoint.json'
            endpoint.write_text(json.dumps(dict(port=server.server_port,token='fixture')))
            endpoint.chmod(0o600)
            cli = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[2] / 'Scripts/agentx'),
                                  '--root', str(endpoint.parent), 'run', 'audit', '--app', 'pilot', '--run', run['id']],
                                 capture_output=True, text=True)
            self.assertEqual(cli.returncode, 0, cli.stderr)
            self.assertEqual(json.loads(cli.stdout), result)
        finally:
            server.shutdown()
            thread.join()
            server.server_close()
            self.children[0].finish.set()

    def test_cancel_signals_before_waiting_for_audit_helper(self):
        _, run = self.service.create('key', self.body)
        child = self.children[0]
        self.assertTrue(child.launched.wait(2))
        original = self.audit.append
        def append(row):
            if row['kind'] == 'model.request.cancel_requested':
                self.assertEqual(child.stops, 1)
            original(row)
        self.audit.append = append
        self.service.stop(run['id'], 'stop')
        child.finish.set()

    def test_new_event_does_not_reinsert_already_acknowledged_retired_events(self):
        _, run = self.service.create('key', self.body)
        child = self.children[0]
        self.assertTrue(child.launched.wait(2))
        self.audit.rows.clear()  # Simulate normal retention after acknowledged start.
        worker = self.service.workers[run['id']][1]
        child.finish.set()
        worker.join(3)
        self.assertEqual([r['kind'] for r in self.audit.rows.values()], ['model.request.completed'])
