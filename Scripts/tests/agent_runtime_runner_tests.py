"""Only pre-run, validated test IDs may enter runtime CI annotations."""
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
import weakref

ROOT = Path(__file__).resolve().parents[2]
ENTRY = ROOT / 'Scripts/run-agent-runtime-contracts.py'
PRIVATE = 'private-canary-DO-NOT-ANNOTATE'


class RuntimeRunnerTests(unittest.TestCase):
    def load_runner(self):
        self.assertTrue(ENTRY.is_file(), 'Safe runtime contract runner is not implemented')
        spec = importlib.util.spec_from_file_location('runtime_contract_runner', ENTRY)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def run_cases(self, case, *, github_actions='true'):
        module = self.load_runner()
        normal, annotations = io.StringIO(), io.StringIO()
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(case)
        status = module.run(suite, stream=normal, annotation_stream=annotations, github_actions=github_actions)
        return status, normal.getvalue(), annotations.getvalue()

    def test_success_preserves_normal_runner_and_emits_no_annotations(self):
        class Passing(unittest.TestCase):
            def test_pass(self): self.assertEqual(1, 1)
        status, normal, annotations = self.run_cases(Passing)
        self.assertEqual(status, 0)
        self.assertIn('Ran 1 test', normal); self.assertIn('OK', normal)
        self.assertEqual(annotations, '')

    def test_failures_errors_and_subtests_use_the_static_parent_id(self):
        class Cases(unittest.TestCase):
            def test_failure(self): self.fail(PRIVATE)
            def test_error(self): raise RuntimeError(PRIVATE)
            def test_subtests(self):
                for n in range(2):
                    with self.subTest(payload=PRIVATE, n=n): self.fail(PRIVATE)
        # Local classes include <locals>; use ordinary discoverable IDs for these fixtures.
        Cases.__qualname__ = 'StaticCases'
        status, normal, annotations = self.run_cases(Cases)
        self.assertEqual(status, 1); self.assertIn(PRIVATE, normal)
        self.assertIn('FAILED (failures=3, errors=1)', normal)
        self.assertNotIn(PRIVATE, annotations)
        lines = annotations.splitlines()
        self.assertEqual(len(lines), 3)
        for name in ('test_error', 'test_failure', 'test_subtests'):
            self.assertTrue(any('Runtime contract failed ' + __name__ + '.StaticCases.' + name + '::' in line for line in lines))
        self.assertTrue(all(line.endswith('Agent runtime contract did not pass.') for line in lines))

    def test_runtime_id_mutation_cannot_publish_a_dynamic_id(self):
        class Changing(unittest.TestCase):
            def test_change(self):
                self.id = lambda: 'dynamic.payload_' + PRIVATE
                self.fail(PRIVATE)
        Changing.__qualname__ = 'StaticChanging'
        status, _, annotations = self.run_cases(Changing)
        self.assertEqual(status, 1)
        self.assertIn(__name__ + '.StaticChanging.test_change', annotations)
        self.assertNotIn('dynamic', annotations); self.assertNotIn(PRIVATE, annotations)

    def test_unsafe_pre_run_ids_are_never_annotated(self):
        for unsafe in ('payload\n::error title=leak::' + PRIVATE, 'unicode.秘密', 'params(x=private)', '', 'safe%0Ainjection'):
            class Unsafe(unittest.TestCase):
                def id(self): return unsafe
                def test_fail(self): self.fail(PRIVATE)
            status, normal, annotations = self.run_cases(Unsafe)
            self.assertEqual(status, 1); self.assertIn('FAILED', normal)
            self.assertEqual(annotations, '')

    def test_github_actions_must_be_explicitly_true(self):
        class Failing(unittest.TestCase):
            def test_fail(self): self.fail(PRIVATE)
        Failing.__qualname__ = 'StaticFailing'
        for enabled in ('', 'false', 'TRUE', '1'):
            status, _, annotations = self.run_cases(Failing, github_actions=enabled)
            self.assertEqual(status, 1); self.assertEqual(annotations, '')

    def test_annotation_ids_are_deduplicated_and_capped_without_stopping_tests(self):
        methods = {}
        for n in range(12):
            def fail(self):
                for _ in range(2):
                    with self.subTest(payload=PRIVATE): self.fail(PRIVATE)
            methods['test_' + str(n).zfill(2)] = fail
        case = type('ManyFailures', (unittest.TestCase,), methods)
        status, normal, annotations = self.run_cases(case)
        self.assertEqual(status, 1); self.assertIn('Ran 12 tests', normal)
        self.assertIn('failures=24', normal)
        self.assertEqual(len(annotations.splitlines()), 10)
        self.assertEqual(len(set(annotations.splitlines())), 10)
        self.assertNotIn(PRIVATE, annotations)

    def test_unknown_test_object_cannot_spoof_a_whitelisted_id(self):
        module = self.load_runner()
        class Known(unittest.TestCase):
            def test_known(self): pass
        Known.__qualname__ = 'Known'
        known = Known('test_known')
        ids = module.discovered_ids(unittest.TestSuite([known]))
        stream = unittest.runner._WritelnDecorator(io.StringIO())
        result = module.FailureIDResult(stream, True, 1, ids=ids)
        unknown = Known('test_known')
        result.addFailure(unknown, (AssertionError, AssertionError(PRIVATE), None))
        self.assertEqual(result.failed_ids, [])

    def test_whitelist_keeps_exact_objects_alive_to_prevent_identity_reuse(self):
        module = self.load_runner()
        def fixture_case(): pass
        case = unittest.FunctionTestCase(fixture_case)
        reference = weakref.ref(case)
        ids = module.discovered_ids(unittest.TestSuite([case]))
        del case
        self.assertIsNotNone(reference(), 'A disposed passing case must not free an ID that another object can reuse')
        self.assertTrue(ids)

    def test_class_setup_and_teardown_errors_use_discovered_static_fixture_ids(self):
        for phase in ('setUpClass', 'tearDownClass'):
            def broken(cls): raise RuntimeError(PRIVATE)
            case = type('StaticClassFixture', (unittest.TestCase,), {
                phase: classmethod(broken), 'test_pass': lambda self: None})
            status, normal, annotations = self.run_cases(case)
            self.assertEqual(status, 1); self.assertIn(PRIVATE, normal)
            self.assertEqual(annotations, '::error title=Runtime contract failed ' + __name__ + '.StaticClassFixture.' + phase + '::Agent runtime contract did not pass.\n')
            self.assertNotIn(PRIVATE, annotations)

    def test_module_setup_and_teardown_errors_use_discovered_static_fixture_ids(self):
        name = 'safe_runtime_fixture_module'
        for phase in ('setUpModule', 'tearDownModule'):
            fixture = types.ModuleType(name)
            def broken(): raise RuntimeError(PRIVATE)
            setattr(fixture, phase, broken)
            previous = sys.modules.get(name)
            sys.modules[name] = fixture
            try:
                case = type('StaticModuleFixture', (unittest.TestCase,), {
                    '__module__': name, 'test_pass': lambda self: None})
                status, normal, annotations = self.run_cases(case)
            finally:
                if previous is None: sys.modules.pop(name, None)
                else: sys.modules[name] = previous
            self.assertEqual(status, 1); self.assertIn(PRIVATE, normal)
            self.assertEqual(annotations, '::error title=Runtime contract failed ' + name + '.' + phase + '::Agent runtime contract did not pass.\n')
            self.assertNotIn(PRIVATE, annotations)

    def test_unknown_suite_error_holder_has_only_a_fixed_marker(self):
        module = self.load_runner()
        class Known(unittest.TestCase):
            def test_known(self): pass
        Known.__qualname__ = 'Known'
        ids = module.discovered_ids(unittest.TestSuite([Known('test_known')]))
        stream = unittest.runner._WritelnDecorator(io.StringIO())
        result = module.FailureIDResult(stream, True, 1, ids=ids)
        holder = unittest.suite._ErrorHolder('setUpClass (' + __name__ + '.Known)' + PRIVATE + '\n::error title=leak::' + PRIVATE)
        result.addError(holder, (RuntimeError, RuntimeError(PRIVATE), None))
        self.assertEqual(result.failed_ids, ['unittest.suite.unknown_fixture_failure'])
        self.assertNotIn(PRIVATE, ''.join(result.failed_ids))

    def test_cli_discovers_complete_pattern_and_retains_failure_exit_code(self):
        self.load_runner()
        with tempfile.TemporaryDirectory(prefix='runtime-runner-') as temporary:
            root = Path(temporary); (root / 'Scripts').mkdir()
            shutil.copy2(ENTRY, root / 'Scripts' / ENTRY.name)
            tests = root / 'Tests/AgentRuntimeTests'; tests.mkdir(parents=True)
            (tests / 'test_synthetic.py').write_text('import unittest\nclass Synthetic(unittest.TestCase):\n def test_pass(self): pass\n def test_fail(self): self.fail("' + PRIVATE + '")\n')
            (tests / 'ignored.py').write_text('raise RuntimeError("must not discover ignored file")\n')
            env = dict(os.environ, GITHUB_ACTIONS='true', PYTHONDONTWRITEBYTECODE='1')
            result = subprocess.run([sys.executable, '-B', str(root / 'Scripts' / ENTRY.name)], cwd=temporary, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Ran 2 tests', result.stderr); self.assertIn(PRIVATE, result.stderr)
        self.assertEqual(result.stdout, '::error title=Runtime contract failed test_synthetic.Synthetic.test_fail::Agent runtime contract did not pass.\n')


if __name__ == '__main__': unittest.main()
