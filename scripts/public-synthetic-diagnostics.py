#!/usr/bin/env python3
"""Bound diagnostic work and print only validated, synthetic app witness scalars.

The caller owns simulator shutdown/deletion. No files are enumerated or uploaded.
"""
import argparse
import contextlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import time


BUNDLE = 'dev.galaxybigbird.ApartmentFinder'
PROBES = ('toolbar', 'production', 'bannerPassThrough', 'toolbarRecheck')
DEVICE_PATTERN = re.compile(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z')
MAX_BYTES = 8192
SCHEMA_FIELDS = (
    'schemaVersion', 'probe', 'sequence', 'lastEvent', 'scenePhase',
    'rootAppearances', 'coordinatorInstance', 'actionCount', 'lastAction',
    'fixturePhase', 'coordinatorPhase', 'documentCount', 'writeFailures',
    'requiresPrivatePack', 'privatePackImportPending', 'loading', 'requestPresent',
    'manifestSheetAppeared', 'manifestPickerRequested', 'settingsPresented',
    'packPickerRequested', 'errorPresent',
    'bannerHitTestingDisabled', 'documentPickerWasPresented',
    'pickerObservationCompleted',
)
INTEGER_RULES = {
    'schemaVersion': (1, 1), 'sequence': (1, 4096), 'rootAppearances': (0, 64),
    'coordinatorInstance': (0, 64), 'actionCount': (0, 64),
    'documentCount': (0, 3), 'writeFailures': (0, 64),
}
ENUM_RULES = {
    'probe': PROBES,
    'lastEvent': ('rootAppeared', 'sceneChanged', 'actionEntered', 'fixtureStarted',
                  'fixtureReady', 'fixtureFailed', 'openStarted', 'requestPublished',
                  'readFailed', 'loadingEnded', 'manifestSheetAppeared',
                  'manifestPickerChanged', 'settingsChanged', 'packPickerChanged',
                  'documentPickerObserved'),
    'scenePhase': ('unknown', 'active', 'inactive', 'background'),
    'lastAction': ('none', 'mixed', 'manifestImport', 'share', 'productionImport'),
    'fixturePhase': ('idle', 'installing', 'ready', 'failed'),
    'coordinatorPhase': ('idle', 'reading', 'published', 'failed', 'rejected'),
}
BOOLEAN_FIELDS = (
    'requiresPrivatePack', 'privatePackImportPending', 'loading', 'requestPresent',
    'manifestSheetAppeared', 'manifestPickerRequested', 'settingsPresented',
    'packPickerRequested', 'errorPresent',
    'bannerHitTestingDisabled', 'documentPickerWasPresented',
    'pickerObservationCompleted',
)


def _unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError()
        value[key] = item
    return value


def _reject_constant(_value):
    raise ValueError()


def read_witness(container, probe):
    """Read one fixed file through no-follow directory fds, with an 8 KiB cap."""
    if probe not in PROBES:
        return 'invalid', None
    try:
        root = Path(container)
        if not root.is_absolute() or '..' in root.parts:
            return 'invalid', None
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        with contextlib.ExitStack() as handles:
            directory = os.open('/', directory_flags)
            handles.callback(os.close, directory)
            # Inspect every ancestor without following symlinks, including the
            # container itself. Relative opens prevent path replacement escapes.
            for component in root.parts[1:] + ('Library', 'Caches', 'SyntheticUIDiagnostics'):
                directory = os.open(component, directory_flags, dir_fd=directory)
                handles.callback(os.close, directory)
            descriptor = os.open(probe + '.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=directory)
            handles.callback(os.close, descriptor)
            information = os.fstat(descriptor)
            if not stat.S_ISREG(information.st_mode) or information.st_size > MAX_BYTES:
                return 'invalid', None
            raw = bytearray()
            while len(raw) <= MAX_BYTES:
                chunk = os.read(descriptor, MAX_BYTES + 1 - len(raw))
                if not chunk:
                    break
                raw.extend(chunk)
            if len(raw) > MAX_BYTES:
                return 'invalid', None
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=_unique_object,
                           parse_constant=_reject_constant)
        if type(value) is not dict or set(value) != set(SCHEMA_FIELDS):
            return 'invalid', None
        for key, (low, high) in INTEGER_RULES.items():
            if type(value[key]) is not int or not low <= value[key] <= high:
                return 'invalid', None
        for key, allowed in ENUM_RULES.items():
            if type(value[key]) is not str or value[key] not in allowed:
                return 'invalid', None
        if value['probe'] != probe or any(type(value[key]) is not bool for key in BOOLEAN_FIELDS):
            return 'invalid', None
        # Reconstruct rather than emitting any original JSON, bytes, or strings
        # outside the allowlists. Field order is fixed for readable runner logs.
        return 'valid', {key: value[key] for key in SCHEMA_FIELDS}
    except FileNotFoundError:
        return 'missing', None
    except (OSError, ValueError, TypeError, RecursionError):
        return 'invalid', None


def _print_missing_container():
    print('syntheticDiagnostics=containerUnavailable')
    for probe in PROBES:
        print('syntheticWitness=' + probe + ';status=missing')


def _container_for_device(device):
    # subprocess.run(timeout=...) performs an unbounded communicate after kill
    # on POSIX. A descendant retaining stdout must not consume cleanup time.
    process = subprocess.Popen(
        ['xcrun', 'simctl', 'get_app_container', device, BUNDLE, 'data'],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=8)
        return output if process.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, UnicodeError):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            process.wait(timeout=2)
        except (OSError, subprocess.SubprocessError):
            pass
        return None
    finally:
        process.stdout.close()


def collect(device):
    """Resolve only the selected device's exact app; toolbar is required."""
    if type(device) is not str or not DEVICE_PATTERN.fullmatch(device):
        print('syntheticDiagnostics=invalidDevice')
        return 1
    try:
        output = _container_for_device(device)
        if type(output) is not str:
            _print_missing_container()
            return 1
        container = output.rstrip('\n')
        if (not container.startswith('/') or len(container) > 4096
                or any(character in container for character in ('\n', '\r', '\0'))):
            _print_missing_container()
            return 1
    except (OSError, subprocess.SubprocessError, UnicodeError):
        _print_missing_container()
        return 1

    toolbar_observed = False
    for probe in PROBES:
        status, value = read_witness(container, probe)
        line = 'syntheticWitness=' + probe + ';status=' + status
        if status == 'valid':
            fields = (key + '=' + (str(item).lower() if type(item) is bool else str(item))
                      for key, item in value.items())
            line += ';' + ';'.join(fields)
        print(line)
        if status == 'valid':
            evidence = ('observed' if value['rootAppearances'] > 0 and value['writeFailures'] == 0
                        else 'inconclusive')
            print('syntheticEvidence=' + probe + ';status=' + evidence)
        if probe == 'toolbar':
            toolbar_observed = status == 'valid' and evidence == 'observed'
    return 0 if toolbar_observed else 1


def _stop_process(process):
    """Never use an unbounded wait while reserving time for caller cleanup."""
    for action, seconds in ((signal.SIGTERM, 5), (signal.SIGKILL, 2)):
        try:
            os.killpg(process.pid, action)
        except ProcessLookupError:
            pass
        except OSError:
            print('syntheticDiagnostics=terminationFailed')
        try:
            process.wait(timeout=seconds)
            if action == signal.SIGKILL:
                return
        except subprocess.TimeoutExpired:
            pass
        except (OSError, subprocess.SubprocessError):
            print('syntheticDiagnostics=terminationFailed')
            if action == signal.SIGKILL:
                return
    print('syntheticDiagnostics=terminationIncomplete')


def run_command(command, deadline_epoch):
    """Inherit command output, retaining its nonzero result or deadline 124."""
    if deadline_epoch <= time.time():
        print('syntheticDiagnostics=deadlineExceeded')
        return 124
    try:
        process = subprocess.Popen(command, start_new_session=True)
    except (OSError, ValueError, subprocess.SubprocessError):
        print('syntheticDiagnostics=launchFailed')
        return 127
    try:
        remaining = max(0, deadline_epoch - time.time())
        status = process.wait(timeout=remaining)
        return status if status >= 0 else 128 - status
    except subprocess.TimeoutExpired:
        print('syntheticDiagnostics=deadlineExceeded')
        _stop_process(process)
        return 124
    except (OSError, subprocess.SubprocessError):
        print('syntheticDiagnostics=waitFailed')
        _stop_process(process)
        return 1


class _ArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        print('syntheticDiagnostics=invalidArguments', file=sys.stderr)
        raise SystemExit(2)


def main(argv=None):
    parser = _ArgumentParser(prog='public-synthetic-diagnostics')
    modes = parser.add_subparsers(dest='mode', required=True)
    for name in ('run', 'work', 'collect'):
        mode = modes.add_parser(name)
        if name != 'collect':
            mode.add_argument('--deadline-epoch', type=int, required=True)
        if name != 'work':
            mode.add_argument('--device', required=True)
        if name != 'collect':
            mode.add_argument('command', nargs=argparse.REMAINDER)
    arguments = parser.parse_args(argv)
    if arguments.mode != 'work' and not DEVICE_PATTERN.fullmatch(arguments.device):
        parser.error('')
    if arguments.mode == 'collect':
        return collect(arguments.device)
    if len(arguments.command) < 2 or arguments.command[0] != '--':
        parser.error('')
    if arguments.mode == 'work':
        return run_command(arguments.command[1:], arguments.deadline_epoch)

    build_status = 1
    collection_status = 1
    try:
        build_status = run_command(arguments.command[1:], arguments.deadline_epoch)
    except Exception:
        print('syntheticDiagnostics=runFailed')
    finally:
        try:
            collection_status = collect(arguments.device)
        except Exception:
            print('syntheticDiagnostics=collectionFailed')
    return build_status if build_status != 0 else collection_status


if __name__ == '__main__':
    try:
        result = main()
    except Exception:
        print('syntheticDiagnostics=wrapperFailed')
        result = 1
    raise SystemExit(result)
