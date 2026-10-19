"""Local, synthetic-only tests; simctl is always mocked and no simulator runs."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/public-synthetic-diagnostics.py'
SPEC = importlib.util.spec_from_file_location('public_synthetic_diagnostics', SCRIPT)
DIAGNOSTICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DIAGNOSTICS)
DEVICE = '00000000-1111-2222-3333-444444444444'


def witness(probe='toolbar', **changes):
    value = {
        'schemaVersion': 1, 'probe': probe, 'sequence': 1,
        'lastEvent': 'rootAppeared', 'scenePhase': 'active',
        'rootAppearances': 1, 'coordinatorInstance': 1, 'actionCount': 0,
        'lastAction': 'none', 'fixturePhase': 'idle', 'coordinatorPhase': 'idle',
        'documentCount': 0, 'writeFailures': 0,
        'requiresPrivatePack': False, 'privatePackImportPending': False,
        'loading': False, 'requestPresent': False, 'manifestSheetAppeared': False,
        'manifestPickerRequested': False, 'settingsPresented': False,
        'packPickerRequested': False, 'errorPresent': False,
    }
    value.update(changes)
    return value


class WitnessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.container = Path(self.temporary.name).resolve()
        self.directory = self.container / 'Library/Caches/SyntheticUIDiagnostics'
        self.directory.mkdir(parents=True)

    def write(self, value=None, probe='toolbar', raw=None):
        path = self.directory / (probe + '.json')
        path.write_bytes(raw if raw is not None else json.dumps(value or witness(probe)).encode())
        return path

    def read(self, probe='toolbar'):
        return DIAGNOSTICS.read_witness(self.container, probe)

    def collect(self):
        output = io.StringIO()
        process = mock.Mock(returncode=0)
        process.communicate.return_value = (str(self.container) + '\n', None)
        with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen', return_value=process) as simctl:
            with contextlib.redirect_stdout(output):
                status = DIAGNOSTICS.collect(DEVICE)
        return status, output.getvalue(), simctl

    def test_valid_zero_action_count_is_distinct_from_a_missing_witness(self):
        self.assertEqual(self.read(), ('missing', None))
        self.write()
        status, value = self.read()
        self.assertEqual(status, 'valid')
        self.assertEqual(value, witness())
        self.assertEqual(value['actionCount'], 0)

    def test_valid_output_is_reconstructed_with_only_schema_scalars(self):
        self.write()
        status, output, _ = self.collect()
        self.assertEqual(status, 0)
        expected = 'syntheticWitness=toolbar;status=valid;' + ';'.join(
            key + '=' + (str(value).lower() if type(value) is bool else str(value))
            for key, value in witness().items())
        self.assertIn(expected + '\n', output)
        self.assertIn('syntheticWitness=production;status=missing\n', output)
        self.assertIn('syntheticEvidence=toolbar;status=observed\n', output)
        self.assertNotIn(str(self.container), output)
        self.assertNotIn(DEVICE, output)

    def test_missing_required_toolbar_fails_without_inventing_zero_attempts(self):
        status, output, _ = self.collect()
        self.assertEqual(status, 1)
        self.assertEqual(output, 'syntheticWitness=toolbar;status=missing\n'
                         'syntheticWitness=production;status=missing\n')
        self.assertNotIn('actionCount=', output)

    def test_unobserved_root_or_write_failure_is_explicitly_inconclusive(self):
        for changes in ({'rootAppearances': 0}, {'writeFailures': 1}):
            with self.subTest(changes=changes):
                self.write(witness(**changes))
                status, output, _ = self.collect()
                self.assertEqual(status, 1)
                self.assertIn('syntheticEvidence=toolbar;status=inconclusive\n', output)
                self.assertNotIn('status=observed', output)

    def test_collect_resolves_only_the_requested_device_and_bundle_with_an_eight_second_limit(self):
        self.write()
        _, _, simctl = self.collect()
        simctl.assert_called_once_with(
            ['xcrun', 'simctl', 'get_app_container', DEVICE,
             'dev.galaxybigbird.ApartmentFinder', 'data'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, start_new_session=True)
        simctl.return_value.communicate.assert_called_once_with(timeout=8)

    def test_invalid_required_toolbar_fails_without_echoing_its_contents(self):
        self.write(raw=b'{"private-address":"DO-NOT-PRINT"}')
        status, output, _ = self.collect()
        self.assertEqual(status, 1)
        self.assertIn('syntheticWitness=toolbar;status=invalid\n', output)
        self.assertNotIn('DO-NOT-PRINT', output)
        self.assertNotIn('actionCount=', output)

    def test_valid_production_witness_is_printed(self):
        self.write()
        self.write(witness('production', lastAction='productionImport', actionCount=1),
                   probe='production')
        status, output, _ = self.collect()
        self.assertEqual(status, 0)
        self.assertIn('syntheticWitness=production;status=valid;', output)
        self.assertIn('lastAction=productionImport;', output)

    def test_rejects_unknown_missing_and_duplicate_keys(self):
        unknown = witness(privateAddress='DO-NOT-PRINT')
        missing = witness()
        del missing['loading']
        for value in (unknown, missing):
            with self.subTest(keys=list(value)):
                self.write(value)
                self.assertEqual(self.read(), ('invalid', None))
        raw = json.dumps(witness())[:-1] + ',"actionCount":1}'
        self.write(raw=raw.encode())
        self.assertEqual(self.read(), ('invalid', None))

    def test_rejects_every_enum_outside_its_allowlist(self):
        for key in ('probe', 'lastEvent', 'scenePhase', 'lastAction',
                    'fixturePhase', 'coordinatorPhase'):
            with self.subTest(key=key):
                self.write(witness(**{key: 'unknown-private-value'}))
                self.assertEqual(self.read(), ('invalid', None))
        self.write(witness(probe='production'))
        self.assertEqual(self.read(), ('invalid', None))

    def test_accepts_every_declared_enum_value(self):
        values = {
            'lastEvent': ('rootAppeared', 'sceneChanged', 'actionEntered',
                          'fixtureStarted', 'fixtureReady', 'fixtureFailed',
                          'openStarted', 'requestPublished', 'readFailed',
                          'loadingEnded', 'manifestSheetAppeared',
                          'manifestPickerChanged', 'settingsChanged', 'packPickerChanged'),
            'scenePhase': ('unknown', 'active', 'inactive', 'background'),
            'lastAction': ('none', 'mixed', 'manifestImport', 'share', 'productionImport'),
            'fixturePhase': ('idle', 'installing', 'ready', 'failed'),
            'coordinatorPhase': ('idle', 'reading', 'published', 'failed', 'rejected'),
        }
        for key, allowed in values.items():
            for value in allowed:
                with self.subTest(key=key, value=value):
                    self.write(witness(**{key: value}))
                    self.assertEqual(self.read()[0], 'valid')

    def test_integer_ranges_are_strict_and_booleans_are_not_integers(self):
        ranges = {'schemaVersion': (1, 1), 'sequence': (1, 4096),
                  'rootAppearances': (0, 64), 'coordinatorInstance': (0, 64),
                  'actionCount': (0, 64), 'documentCount': (0, 3), 'writeFailures': (0, 64)}
        for key, (low, high) in ranges.items():
            for value in (low, high):
                self.write(witness(**{key: value}))
                self.assertEqual(self.read()[0], 'valid', (key, value))
            for value in (low - 1, high + 1, True, False, 1.0, '1', None):
                with self.subTest(key=key, value=value):
                    self.write(witness(**{key: value}))
                    self.assertEqual(self.read(), ('invalid', None))

    def test_boolean_fields_require_exact_booleans(self):
        keys = ('requiresPrivatePack', 'privatePackImportPending', 'loading',
                'requestPresent', 'manifestSheetAppeared', 'manifestPickerRequested',
                'settingsPresented', 'packPickerRequested', 'errorPresent')
        for key in keys:
            for value in (True, False):
                self.write(witness(**{key: value}))
                self.assertEqual(self.read()[0], 'valid', (key, value))
            for value in (0, 1, 'false', None, [], {}):
                with self.subTest(key=key, value=value):
                    self.write(witness(**{key: value}))
                    self.assertEqual(self.read(), ('invalid', None))

    def test_enum_fields_require_strings(self):
        for key in ('probe', 'lastEvent', 'scenePhase', 'lastAction',
                    'fixturePhase', 'coordinatorPhase'):
            for value in (True, 1, None, [], {}):
                with self.subTest(key=key, value=value):
                    self.write(witness(**{key: value}))
                    self.assertEqual(self.read(), ('invalid', None))

    def test_rejects_nonobjects_malformed_utf8_and_nonfinite_json(self):
        for raw in (b'[]', b'null', b'1', b'{', b'\xff',
                    json.dumps(witness()).replace('"sequence": 1', '"sequence": NaN').encode()):
            with self.subTest(raw=raw):
                self.write(raw=raw)
                self.assertEqual(self.read(), ('invalid', None))

    def test_size_limit_includes_padding_and_accepts_exactly_8192_bytes(self):
        raw = json.dumps(witness()).encode()
        self.write(raw=raw + b' ' * (8192 - len(raw)))
        self.assertEqual(self.read()[0], 'valid')
        self.write(raw=raw + b' ' * (8193 - len(raw)))
        self.assertEqual(self.read(), ('invalid', None))

    def test_bounded_read_handles_short_regular_file_reads_without_ignoring_trailing_bytes(self):
        self.write()
        read = os.read
        with mock.patch.object(DIAGNOSTICS.os, 'read',
                               side_effect=lambda descriptor, size: read(descriptor, min(size, 7))):
            self.assertEqual(self.read()[0], 'valid')
            self.write(raw=json.dumps(witness()).encode() + b'INVALID-TAIL')
            self.assertEqual(self.read(), ('invalid', None))

    def test_rejects_file_symlinks_even_to_valid_in_container_file(self):
        target = self.container / 'valid.json'
        target.write_text(json.dumps(witness()))
        (self.directory / 'toolbar.json').symlink_to(target)
        self.assertEqual(self.read(), ('invalid', None))

    def test_rejects_parent_directory_symlinks_and_container_symlinks(self):
        self.write()
        link = self.container / 'alias'
        link.symlink_to(self.directory, target_is_directory=True)
        original = self.directory
        self.directory.rename(self.container / 'renamed')
        original.symlink_to(self.container / 'renamed', target_is_directory=True)
        self.assertEqual(self.read(), ('invalid', None))
        alias = self.container / 'container-alias'
        alias.symlink_to(self.container, target_is_directory=True)
        self.assertEqual(DIAGNOSTICS.read_witness(alias, 'toolbar'), ('invalid', None))

    def test_rejects_path_escape_and_unrecognized_probe_without_enumeration(self):
        self.write()
        for path in (Path('relative'), self.container / '..' / self.container.name):
            self.assertEqual(DIAGNOSTICS.read_witness(path, 'toolbar'), ('invalid', None))
        self.assertEqual(DIAGNOSTICS.read_witness(self.container, '../private'), ('invalid', None))
        with mock.patch.object(os, 'listdir', side_effect=AssertionError('no enumeration')):
            with mock.patch.object(os, 'scandir', side_effect=AssertionError('no enumeration')):
                self.assertEqual(self.read()[0], 'valid')

    def test_rejects_nonregular_file_without_blocking(self):
        os.mkfifo(self.directory / 'toolbar.json')
        started = time.monotonic()
        self.assertEqual(self.read(), ('invalid', None))
        self.assertLess(time.monotonic() - started, 1)

    def test_container_resolution_errors_are_fixed_tokens_with_no_exception_data(self):
        cases = (OSError('SECRET-PATH'), subprocess.SubprocessError('SECRET-ARGV'))
        for error in cases:
            output = io.StringIO()
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen', side_effect=error):
                    with contextlib.redirect_stdout(output):
                        self.assertEqual(DIAGNOSTICS.collect(DEVICE), 1)
                self.assertEqual(output.getvalue(), 'syntheticDiagnostics=containerUnavailable\n'
                                 'syntheticWitness=toolbar;status=missing\n'
                                 'syntheticWitness=production;status=missing\n')

    def test_container_timeout_kills_its_group_and_never_communicates_without_a_bound(self):
        process = mock.Mock(pid=12345)
        process.communicate.side_effect = subprocess.TimeoutExpired('SECRET', 8)
        process.wait.side_effect = subprocess.TimeoutExpired('SECRET', 2)
        output = io.StringIO()
        with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen', return_value=process):
            with mock.patch.object(DIAGNOSTICS.os, 'killpg') as killpg:
                with contextlib.redirect_stdout(output):
                    self.assertEqual(DIAGNOSTICS.collect(DEVICE), 1)
        process.communicate.assert_called_once_with(timeout=8)
        process.wait.assert_called_once_with(timeout=2)
        process.stdout.close.assert_called_once_with()
        killpg.assert_called_once_with(12345, signal.SIGKILL)
        self.assertNotIn('SECRET', output.getvalue())

    def test_bad_container_resolution_output_and_invalid_device_are_not_echoed(self):
        for result in (subprocess.CompletedProcess([], 1, 'SECRET'),
                       subprocess.CompletedProcess([], 0, 'relative-secret'),
                       subprocess.CompletedProcess([], 0, '/secret\n/other')):
            with self.subTest(result=result):
                process = mock.Mock(returncode=result.returncode)
                process.communicate.return_value = (result.stdout, None)
                with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen', return_value=process):
                    output = io.StringIO()
                    with contextlib.redirect_stdout(output):
                        self.assertEqual(DIAGNOSTICS.collect(DEVICE), 1)
                    self.assertNotIn('SECRET', output.getvalue())
                    self.assertNotIn('secret', output.getvalue())
        with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen') as simctl:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(DIAGNOSTICS.collect('SECRET-DEVICE'), 1)
            simctl.assert_not_called()


class ProcessTests(unittest.TestCase):
    def test_local_process_success_and_failure_preserve_status(self):
        for status in (0, 7, 65):
            with self.subTest(status=status):
                self.assertEqual(DIAGNOSTICS.run_command(
                    [sys.executable, '-c', 'raise SystemExit(' + str(status) + ')'],
                    time.time() + 5), status)

    def test_signal_exit_uses_the_shell_128_plus_signal_status(self):
        self.assertEqual(DIAGNOSTICS.run_command(
            [sys.executable, '-c', 'import os, signal; os.kill(os.getpid(), signal.SIGTERM)'],
            time.time() + 5), 128 + signal.SIGTERM)

    def test_local_timeout_is_bounded_and_returns_124(self):
        started = time.monotonic()
        with contextlib.redirect_stdout(io.StringIO()):
            status = DIAGNOSTICS.run_command(
                [sys.executable, '-c', 'import time; time.sleep(60)'], time.time() + .1)
        self.assertEqual(status, 124)
        self.assertLess(time.monotonic() - started, 2)

    def test_expired_cutoff_does_not_launch_any_process(self):
        with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen') as popen:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(DIAGNOSTICS.run_command(['secret-command'], time.time() - 1), 124)
            popen.assert_not_called()

    def test_process_inherits_output_owns_session_and_termination_waits_are_bounded(self):
        process = mock.Mock(pid=12345)
        process.wait.side_effect = [subprocess.TimeoutExpired('secret', 1),
                                   subprocess.TimeoutExpired('secret', 5),
                                   subprocess.TimeoutExpired('secret', 2)]
        with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen', return_value=process) as popen:
            with mock.patch.object(DIAGNOSTICS.os, 'killpg') as killpg:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(DIAGNOSTICS.run_command(['some-command'], time.time() + 10), 124)
        popen.assert_called_once_with(['some-command'], start_new_session=True)
        self.assertLessEqual(process.wait.call_args_list[0].kwargs['timeout'], 10)
        self.assertEqual(process.wait.call_args_list[1:], [mock.call(timeout=5), mock.call(timeout=2)])
        self.assertEqual(killpg.call_args_list,
                         [mock.call(12345, signal.SIGTERM), mock.call(12345, signal.SIGKILL)])

    def test_timeout_keeps_124_even_when_process_group_disappears_or_wait_fails(self):
        for error in (ProcessLookupError('SECRET'), PermissionError('SECRET')):
            process = mock.Mock(pid=12345)
            process.wait.side_effect = [subprocess.TimeoutExpired('SECRET', 1),
                                       subprocess.SubprocessError('SECRET'), 0]
            output = io.StringIO()
            with self.subTest(error=type(error).__name__):
                with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen', return_value=process):
                    with mock.patch.object(DIAGNOSTICS.os, 'killpg', side_effect=error):
                        with contextlib.redirect_stdout(output):
                            self.assertEqual(DIAGNOSTICS.run_command(['SECRET'], time.time() + 1), 124)
                self.assertNotIn('SECRET', output.getvalue())

    def test_timeout_kills_remaining_group_even_when_parent_exits_on_term(self):
        process = mock.Mock(pid=12345)
        process.wait.side_effect = [subprocess.TimeoutExpired('SECRET', 1), 0, 0]
        with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen', return_value=process):
            with mock.patch.object(DIAGNOSTICS.os, 'killpg') as killpg:
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(DIAGNOSTICS.run_command(['command'], time.time() + 1), 124)
        self.assertEqual(killpg.call_args_list,
                         [mock.call(12345, signal.SIGTERM), mock.call(12345, signal.SIGKILL)])

    def test_launch_errors_do_not_print_exception_argv_or_path(self):
        output = io.StringIO()
        with mock.patch.object(DIAGNOSTICS.subprocess, 'Popen', side_effect=OSError('SECRET')):
            with contextlib.redirect_stdout(output):
                self.assertEqual(DIAGNOSTICS.run_command(['SECRET'], time.time() + 1), 127)
        self.assertEqual(output.getvalue(), 'syntheticDiagnostics=launchFailed\n')

    def test_build_nonzero_is_preserved_even_if_collection_fails_or_raises(self):
        for build_status in (7, 65, 124):
            for collector in (mock.Mock(return_value=1), mock.Mock(side_effect=OSError('SECRET'))):
                with self.subTest(build_status=build_status):
                    with mock.patch.object(DIAGNOSTICS, 'run_command', return_value=build_status):
                        with mock.patch.object(DIAGNOSTICS, 'collect', collector):
                            with contextlib.redirect_stdout(io.StringIO()):
                                status = DIAGNOSTICS.main(['run', '--deadline-epoch', '123',
                                                          '--device', DEVICE, '--', 'xcodebuild'])
                    self.assertEqual(status, build_status)
                    collector.assert_called_once_with(DEVICE)

    def test_build_success_requires_a_successful_collector(self):
        for collector_status in (0, 1):
            with mock.patch.object(DIAGNOSTICS, 'run_command', return_value=0):
                with mock.patch.object(DIAGNOSTICS, 'collect', return_value=collector_status):
                    self.assertEqual(DIAGNOSTICS.main(['run', '--deadline-epoch', '123',
                        '--device', DEVICE, '--', 'xcodebuild', '-quiet']), collector_status)

    def test_work_shares_deadline_runner_but_never_collects_or_cleans_up(self):
        with mock.patch.object(DIAGNOSTICS, 'run_command', return_value=124) as run:
            with mock.patch.object(DIAGNOSTICS, 'collect') as collect:
                self.assertEqual(DIAGNOSTICS.main(['work', '--deadline-epoch', '123',
                    '--', 'xcrun', 'simctl', 'boot', DEVICE]), 124)
        run.assert_called_once_with(['xcrun', 'simctl', 'boot', DEVICE], 123)
        collect.assert_not_called()

    def test_collect_cli_does_not_start_build(self):
        with mock.patch.object(DIAGNOSTICS, 'collect', return_value=1) as collect:
            with mock.patch.object(DIAGNOSTICS, 'run_command') as run:
                self.assertEqual(DIAGNOSTICS.main(['collect', '--device', DEVICE]), 1)
        collect.assert_called_once_with(DEVICE)
        run.assert_not_called()

    def test_cli_errors_are_fixed_tokens_without_argument_echo(self):
        cases = ([], ['SECRET'], ['run', '--deadline-epoch', 'SECRET', '--device', DEVICE],
                 ['run', '--deadline-epoch', '1', '--device', DEVICE, '--'],
                 ['run', '--deadline-epoch', '1', '--device', 'SECRET', '--', 'xcodebuild'])
        for arguments in cases:
            with self.subTest(arguments=arguments):
                output = io.StringIO()
                with contextlib.redirect_stderr(output):
                    with self.assertRaises(SystemExit) as failure:
                        DIAGNOSTICS.main(arguments)
                self.assertEqual(failure.exception.code, 2)
                self.assertEqual(output.getvalue(), 'syntheticDiagnostics=invalidArguments\n')


if __name__ == '__main__':
    unittest.main()
