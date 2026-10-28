"""Offline policy and filesystem tests for exact Swift cache inputs."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / '.github/workflows/ci.yml').read_text()
NORMALIZE = textwrap.dedent(WORKFLOW.split("python3 - <<'PYTHON'\n", 1)[1].split('\n          PYTHON', 1)[0])

class CICachePolicyTests(unittest.TestCase):
    def test_cache_covers_compile_invocation_and_all_source_resources(self):
        for source in ('Package.swift', 'Package.resolved', 'Scripts/travel-cat-swift.sh',
                       'Scripts/swift_test_report.py', '.github/workflows/ci.yml', 'Sources/**', 'Tests/**'):
            self.assertIn("'" + source + "'", WORKFLOW)
        self.assertNotIn('restore-keys:', WORKFLOW)
        self.assertIn('path: ${{ steps.swift-cache.outputs.scratch-path }}', WORKFLOW)
    def test_concurrency_keeps_events_and_protected_refs_separate(self):
        self.assertIn('${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}-', WORKFLOW)
        self.assertIn("(github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/')) && github.run_id", WORKFLOW)
        self.assertIn("cancel-in-progress: ${{ github.ref != 'refs/heads/main' && !startsWith(github.ref, 'refs/tags/') }}", WORKFLOW)
        for step in ('Agent runtime contracts', 'Swift tests (UTC)', 'Prompt tests (Asia/Shanghai)', 'Preserve sanitized Swift test results', 'Public upload audit'):
            self.assertIn('- name: '+step, WORKFLOW)
    def fixture(self, directory):
        root = Path(directory) / 'source'; root.mkdir()
        subprocess.run(['git', 'init', '-q', str(root)], check=True)
        for name in ('Package.swift', 'Sources/Probe.swift', 'Tests/ProbeTests.swift', 'Sources/TravelUI/Resources/fixture.png'):
            p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(b'public fixture\n')
        self.commit(root)
        return root
    def commit(self, root):
        subprocess.run(['git','add','--all'], cwd=root, check=True)
        subprocess.run(['git','-c','user.name=CI fixture','-c','user.email=ci@example.invalid',
                        'commit','-qm','fixture'],cwd=root,check=True)
    def normalize(self, root):
        return subprocess.run([sys.executable,'-c',NORMALIZE],cwd=root,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    def test_cache_observation_contains_only_boolean_and_public_revision(self):
        code=textwrap.dedent(WORKFLOW.split("python3 - <<'CACHE_OBSERVATION'\n",1)[1].split('\n          CACHE_OBSERVATION',1)[0])
        import json
        with tempfile.TemporaryDirectory() as d:
            root=self.fixture(d)
            env=os.environ.copy();env['RUNNER_TEMP']=d;env['TRAVEL_CAT_CACHE_HIT']='private-canary'
            subprocess.run([sys.executable,'-c',code],cwd=root,env=env,check=True)
            output=Path(d)/'travel-cat-cache-observation.json'
            value=json.loads(output.read_text())
            self.assertEqual(set(value),{'schemaVersion','cacheHit','sourceRevision'})
            self.assertFalse(value['cacheHit']);self.assertNotIn('canary',output.read_text())
            env['TRAVEL_CAT_CACHE_HIT']='true'
            subprocess.run([sys.executable,'-c',code],cwd=root,env=env,check=True)
            self.assertTrue(json.loads(output.read_text())['cacheHit'])

    def test_normalization_changes_only_tracked_swift_timestamps(self):
        with tempfile.TemporaryDirectory() as d:
            root=self.fixture(d)
            untracked=root/'Sources/untracked.swift';untracked.write_bytes(b'keep')
            paths=list(root.rglob('*.swift'))+[root/'Sources/TravelUI/Resources/fixture.png']
            for p in paths: os.utime(p,ns=(1_000_000_000,2_000_000_000))
            before={p:(p.read_bytes(),p.stat().st_mtime_ns) for p in paths}
            result=self.normalize(root);self.assertEqual(result.returncode,0,result.stderr.decode())
            for p in paths:
                self.assertEqual(p.read_bytes(),before[p][0])
                if p==untracked or p.suffix=='.png': self.assertEqual(p.stat().st_mtime_ns,before[p][1])
                else: self.assertNotEqual(p.stat().st_mtime_ns,before[p][1])
    def test_symlink_or_missing_input_fails_before_any_timestamp_is_changed(self):
        for kind in ('symlink','missing'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as d:
                root=self.fixture(d)
                target=root/'Sources/Probe.swift'
                if kind=='symlink':
                    target.unlink();target.symlink_to(root/'Tests/ProbeTests.swift');self.commit(root)
                else: target.unlink()
                package=root/'Package.swift';os.utime(package,ns=(1_000_000_000,2_000_000_000))
                result=self.normalize(root)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(package.stat().st_mtime_ns,2_000_000_000)

if __name__=='__main__': unittest.main()
