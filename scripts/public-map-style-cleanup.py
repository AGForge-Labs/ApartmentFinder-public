#!/usr/bin/env python3
"""Bound cleanup and report only the selected synthetic simulator's fixed state."""
import argparse
import json
import os
import re
import signal
import subprocess
import time

def selected_state(raw, device):
    try:
        value = json.loads(raw)
        if type(value) is not dict or type(value.get('devices')) is not dict:
            return 'unavailable'
        groups = value['devices'].values()
        if any(type(rows) is not list or any(type(row) is not dict for row in rows) for rows in groups):
            return 'unavailable'
        matches = [row for rows in value['devices'].values() for row in rows if row.get('udid') == device]
        if not matches:
            return 'absent'
        if len(matches) != 1:
            return 'ambiguous'
        return matches[0]['state'] if matches[0].get('state') in ('Booted', 'Shutdown', 'Booting', 'Shutting Down') else 'unknown'
    except (ValueError, KeyError, TypeError):
        return 'unavailable'


def state(device):
    process = None
    try:
        process = subprocess.Popen(['xcrun', 'simctl', 'list', 'devices', '--json'],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        output, _ = process.communicate(timeout=5)
        if process.returncode or len(output) > 1_000_000:
            return 'unavailable'
        return selected_state(output, device)
    except (OSError, subprocess.SubprocessError):
        if process is not None:
            try: os.killpg(process.pid, signal.SIGKILL)
            except OSError: pass
            try: process.wait(timeout=2)
            except (OSError, subprocess.SubprocessError): pass
        return 'unavailable'
    finally:
        if process is not None and process.stdout is not None:
            process.stdout.close()


def operation(device, name):
    started = time.monotonic()
    result = {'operation': name, 'before': state(device), 'status': 'incomplete'}
    process = None
    try:
        process = subprocess.Popen(['xcrun', 'simctl', name, device], stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            status = process.wait(timeout=10)
            result.update(status='complete' if status == 0 else 'exitFailure', exitStatus=status)
        except subprocess.TimeoutExpired:
            result['status'] = 'timedOut'
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
    except (OSError, subprocess.SubprocessError):
        result['status'] = 'unavailable'
    result['durationMilliseconds'] = round((time.monotonic() - started) * 1000, 3)
    result['after'] = state(device)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', args.device):
        return 2
    packets = [operation(args.device, name) for name in ('shutdown', 'delete')]
    for packet in packets:
        print('MAP-STYLE-CLEANUP ' + json.dumps(packet, separators=(',', ':')), flush=True)
    # Preserve the shutdown failure even when later deletion succeeds.
    return int(any(packet['status'] != 'complete' for packet in packets)
               or packets[-1]['after'] != 'absent')


if __name__ == '__main__':
    raise SystemExit(main())
