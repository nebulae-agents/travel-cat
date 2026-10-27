"""Preview packaging contracts: isolated identity and real runtime resources."""
import hashlib
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'prepare-agent-preview.py'
PROJECT = SCRIPT.parent.parent

class AgentPreviewPackagingTests(unittest.TestCase):
    def test_unique_identity_and_exact_python_resources_without_cache(self):
        with tempfile.TemporaryDirectory() as root:
            result = subprocess.run([sys.executable, str(SCRIPT), '--project-root', str(PROJECT), '--root', root,
                '--name', 'TravelCatNativeAcceptance', '--bundle-id', 'com.nebulae.travelcat.acceptance.unique'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            app = pathlib.Path(result.stdout.strip())
            self.assertEqual(app.name, 'TravelCatNativeAcceptance.app')
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['CFBundleIdentifier'], 'com.nebulae.travelcat.acceptance.unique')
            self.assertEqual(info['CFBundleExecutable'], 'TravelCatNativeAcceptance')
            source = PROJECT / 'Sources/TravelCatApp/Resources/AgentRuntime'
            target = app / 'Contents/Resources/AgentRuntime'
            self.assertEqual(sorted(p.name for p in target.iterdir()), sorted(p.name for p in source.glob('*.py')))
            for p in source.glob('*.py'):
                self.assertEqual(hashlib.sha256(p.read_bytes()).digest(), hashlib.sha256((target / p.name).read_bytes()).digest())
            again = subprocess.run([sys.executable, str(SCRIPT), '--project-root', str(PROJECT), '--root', root,
                '--name', 'TravelCatNativeAcceptance', '--bundle-id', 'com.nebulae.travelcat.acceptance.unique'], capture_output=True)
            self.assertNotEqual(again.returncode, 0, 'Never reuse a launched or stale preview app in place')

    def test_rejects_invalid_identity_before_creating_bundle(self):
        with tempfile.TemporaryDirectory() as root:
            for name, bundle in [('../escape', 'com.example.safe'), ('Safe', 'invalid id'), ('Safe', 'com..invalid')]:
                result = subprocess.run([sys.executable, str(SCRIPT), '--project-root', str(PROJECT), '--root', root,
                    '--name', name, '--bundle-id', bundle], capture_output=True)
                self.assertNotEqual(result.returncode, 0)
            self.assertEqual(list(pathlib.Path(root).iterdir()), [])

if __name__ == '__main__': unittest.main()
