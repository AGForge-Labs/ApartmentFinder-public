#!/usr/bin/env python3
"""Sample only the selected clean simulator's two synthetic test processes.

No raw stack, process list, hierarchy, screenshot or environment is emitted.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import time

MODULES = {
    'ApartmentFinder', 'ApartmentFinder.debug.dylib', 'ApartmentFinderUITests',
    'SwiftUI', 'SwiftUICore', 'AttributeGraph', 'MapKit', 'VectorKit',
    'UIKitCore', 'QuartzCore', 'XCTest', 'XCTestCore', 'XCUIAutomation',
    'AXRuntime', 'AccessibilityUtilities', 'libsystem_kernel.dylib',
    'libsystem_pthread.dylib', 'libdispatch.dylib',
}
TARGETS = {
    'app': '/ApartmentFinder.app/ApartmentFinder',
    'testRunner': '/ApartmentFinderUITests-Runner.app/ApartmentFinderUITests-Runner',
}


def safe_frames(raw):
    """Reconstruct at most 48 known-module function names; never echo raw input."""
    result = []
    thread = 'unknown'
    for line in raw.splitlines():
        if re.search(r'\bThread_\d+\b', line):
            thread = 'main' if 'com.apple.main-thread' in line else 'other'
        match = re.search(r'^\s*[+|!: ]*\d+\s+(.+?)\s+\(in ([^)]+)\)', line)
        if not match or match[2] not in MODULES:
            continue
        symbol = match[1].split(' + ')[0]
        symbol = re.sub(r'[^A-Za-z0-9_.$:+<>(), \[\]&*-]', '?', symbol)[:160]
        value = {'module': match[2], 'function': symbol, 'thread': thread}
        if value not in result:
            result.append(value)
        if len(result) == 48:
            break
    return result


def bounded_log_tail(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 32_000_000:
            return ''
        os.lseek(descriptor, max(0, info.st_size - 65536), os.SEEK_SET)
        return os.read(descriptor, 65536).decode('utf-8', errors='replace')
    finally:
        os.close(descriptor)


def capture(device, phase, target, suffix):
    packet = {'phase': phase, 'target': target, 'status': 'unavailable'}
    started = time.monotonic()
    stage = 'processLookup'
    try:
        listing = subprocess.run(['ps', '-axww', '-o', 'pid=,comm='],
                                 capture_output=True, text=True, timeout=5, check=True)
        if len(listing.stdout) > 1_000_000:
            raise ValueError()
        needle = '/coresimulator/devices/' + device.lower() + '/data/'
        matches = []
        for line in listing.stdout.splitlines():
            fields = line.strip().split(None, 1)
            if (len(fields) == 2 and fields[0].isdigit() and needle in fields[1].lower()
                    and fields[1].endswith(suffix)):
                matches.append(int(fields[0]))
        if len(matches) != 1:
            packet['status'] = 'processMissing' if not matches else 'processAmbiguous'
            return packet
        pid = matches[0]
        packet['pid'] = pid
        stage = 'cpuRead'
        cpu = subprocess.run(['ps', '-p', str(pid), '-o', '%cpu='],
                             capture_output=True, text=True, timeout=5, check=True)
        value = float(cpu.stdout.strip())
        if math.isfinite(value) and 0 <= value <= 6400:
            packet['cpuPercent'] = value
        with tempfile.TemporaryDirectory(prefix='finder-style-sample-', dir=os.environ['RUNNER_TEMP']) as folder:
            output = Path(folder) / 'stack.txt'
            stage = 'sample'
            sample = subprocess.run(['sample', str(pid), '2', '-file', str(output)],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
            packet['exitStatus'] = sample.returncode
            if sample.returncode:
                packet['status'] = 'sampleExit'
                return packet
            stage = 'output'
            if not output.is_file():
                packet['status'] = 'outputMissing'
                return packet
            if output.stat().st_size > 512000:
                packet['status'] = 'outputOversize'
                return packet
            stage = 'parsing'
            packet['frames'] = safe_frames(output.read_text(errors='replace'))
            packet['status'] = 'sampled' if packet['frames'] else 'noKnownFrames'
    except subprocess.TimeoutExpired:
        packet['status'] = 'commandTimedOut'
        packet['failurePhase'] = stage
    except subprocess.CalledProcessError as error:
        packet['status'] = 'commandExit'
        packet['failurePhase'] = stage
        packet['exitStatus'] = error.returncode
    except (OSError, ValueError, subprocess.SubprocessError):
        packet['status'] = 'unavailable'
        packet['failurePhase'] = stage
    finally:
        packet['durationMilliseconds'] = round((time.monotonic() - started) * 1000, 3)
    return packet


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--log', type=Path, required=True)
    parser.add_argument('--case-count', type=int, choices=(1, 3), default=1)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', args.device):
        return 2
    root = Path(os.environ['RUNNER_TEMP']).resolve()
    if args.log.name != 'map-style-diagnostic.log' or args.log.resolve().parent != root:
        return 2
    deadline = time.monotonic() + args.case_count * 600 + 180
    drag = None
    completed = 0
    # Beyond the original eight-second deadline; an AX query may still be blocked.
    # Sampling is diagnostic evidence, never an acceptance result.
    delays = (25, 45, 75)
    while time.monotonic() < deadline:
        try:
            text = bounded_log_tail(args.log)
        except OSError:
            text = ''
        if drag is None and 'MAP-APPEARANCE background drag' in text:
            drag = time.monotonic()
        if drag is not None and time.monotonic() - drag >= delays[completed]:
            for target, suffix in TARGETS.items():
                packet = capture(args.device, 'afterDrag' + str(delays[completed]), target, suffix)
                packet['captureFinishedSecondsAfterDrag'] = round(time.monotonic() - drag, 3)
                print('MAP-STYLE-STACK ' + json.dumps(packet, separators=(',', ':')), flush=True)
            completed += 1
            if completed == len(delays):
                return 0
        time.sleep(0.5)
    print('MAP-STYLE-STACK ' + json.dumps({'status': 'watchDeadline', 'samples': completed}), flush=True)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
