#!/usr/bin/env python3
"""Read two fixed, nonce-bound public-fixture receipts; no uploads or enumeration."""
import contextlib
import json
import math
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

BUNDLE = 'dev.galaxybigbird.ApartmentFinder'
MODES = ('interactive', 'disabled')
UUID_PATTERN = r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'
FIELDS = {'schemaVersion', 'mode', 'runNonce', 'samples', 'armed', 'mapAcquisitions',
          'maxVisibleMaps', 'discoveryTruncated', 'maxSampleGap', 'mapWindowFrame', 'safeInsets',
          'initialCamera', 'lastCamera', 'scrollEnabled', 'interactionEnabled',
          'panRecognizerCount', 'path', 'hitPath', 'recognizers'}


def require(value):
    if not value:
        raise ValueError('Invalid synthetic pan packet')


def integer(value, low, high):
    require(type(value) is int and low <= value <= high)


def number(value, limit):
    require(type(value) in (int, float) and math.isfinite(value) and abs(value) <= limit)


def numbers(value, length, limit):
    require(type(value) is list and len(value) == length)
    for item in value:
        number(item, limit)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def validate(packet, mode):
    require(mode in MODES and type(packet) is dict and set(packet) == FIELDS)
    require(packet['mode'] == mode and type(packet['runNonce']) is str and
            re.fullmatch(UUID_PATTERN, packet['runNonce']))
    integer(packet['schemaVersion'], 1, 1)
    integer(packet['samples'], 1, 3000)
    integer(packet['mapAcquisitions'], 1, 64)
    integer(packet['maxVisibleMaps'], 1, 64)
    integer(packet['panRecognizerCount'], 0, 16)
    number(packet['maxSampleGap'], 300)
    require(packet['maxSampleGap'] >= 0)
    for key in ('armed', 'scrollEnabled', 'interactionEnabled', 'discoveryTruncated'):
        require(type(packet[key]) is bool)
    for key in ('mapWindowFrame', 'safeInsets'):
        numbers(packet[key], 4, 10000)
    require(packet['mapWindowFrame'][2] > 0 and packet['mapWindowFrame'][3] > 0)
    for key in ('initialCamera', 'lastCamera'):
        numbers(packet[key], 6 if packet['armed'] else 0, 40_000_000)
        if packet['armed']:
            camera = packet[key]
            require(abs(camera[0]) <= 90 and abs(camera[1]) <= 180 and
                    0 < camera[2] <= 40_000_000 and -360 <= camera[3] <= 720 and abs(camera[4]) <= 90)
    require(type(packet['path']) is list and len(packet['path']) == 2)
    for point in packet['path']:
        numbers(point, 2, 10000)
    require(type(packet['hitPath']) is list and len(packet['hitPath']) in (0, 2))
    for point in packet['hitPath']:
        numbers(point, 4, 10000)
        require(point[2] in (0, 1) and point[3] in (0, 1))
    require(type(packet['recognizers']) is list and len(packet['recognizers']) <= 16)
    require(packet['panRecognizerCount'] == len(packet['recognizers']))
    for recognizer in packet['recognizers']:
        require(type(recognizer) is dict and set(recognizer) ==
                {'enabled', 'states', 'maxTouches', 'maxTranslation', 'points'})
        require(type(recognizer['enabled']) is bool)
        integer(recognizer['maxTouches'], 0, 8)
        require(type(recognizer['states']) is list and len(recognizer['states']) <= 6 and
                len(recognizer['states']) == len(set(recognizer['states'])))
        for state in recognizer['states']:
            integer(state, 0, 5)
        numbers(recognizer['maxTranslation'], 2, 10000)
        require(type(recognizer['points']) is list and len(recognizer['points']) <= 8)
        for point in recognizer['points']:
            numbers(point, 2, 10000)
    return packet


def read_packet(container, mode):
    require(mode in MODES)
    root = Path(container)
    require(root.is_absolute() and '..' not in root.parts)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with contextlib.ExitStack() as handles:
        directory = os.open('/', flags); handles.callback(os.close, directory)
        for part in root.parts[1:] + ('Library', 'Caches', 'SyntheticUIDiagnostics'):
            directory = os.open(part, flags, dir_fd=directory); handles.callback(os.close, directory)
        descriptor = os.open('map-pan-' + mode + '.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory)
        handles.callback(os.close, descriptor)
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= 16384)
        data = os.read(descriptor, 16385)
        require(len(data) == info.st_size and len(data) <= 16384)
    return validate(json.loads(data, object_pairs_hook=unique_object), mode)


def comparison(a, b):
    same_geometry = all(all(abs(x-y) <= 1 for x, y in zip(a[key], b[key]))
                        for key in ('mapWindowFrame', 'safeInsets'))
    same_camera = a['armed'] and b['armed'] and all(abs(x-y) <= tolerance for x, y, tolerance in
        zip(a['initialCamera'], b['initialCamera'], (0.00001, 0.00001, 5, 1, 1, 5)))
    same_path = a['path'] == b['path']
    complete = all(p['armed'] and p['mapAcquisitions'] == p['maxVisibleMaps'] == 1 and
        not p['discoveryTruncated'] and p['maxSampleGap'] <= 0.1 and p['panRecognizerCount'] > 0 and
        p['scrollEnabled'] and p['interactionEnabled']
        for p in (a, b))
    def moved(p):
        return p['armed'] and any(abs(x-y) > 0.00001 for x, y in zip(p['initialCamera'][:2], p['lastCamera'][:2]))
    return dict(matchedNativeSetup=bool(same_geometry and same_camera and same_path and complete),
        interactiveNativePanTouchObserved=any(r['maxTouches'] > 0 for r in a['recognizers']),
        disabledNativePanTouchObserved=any(r['maxTouches'] > 0 for r in b['recognizers']),
        interactiveNativeCenterChanged=moved(a), disabledNativeCenterChanged=moved(b),
        requiresCompletedMatchedUIReplay=True, diagnosticOnly=True, releaseEligible=False)


def main(arguments=None):
    args = list(sys.argv[1:] if arguments is None else arguments)
    if len(args) != 4 or args[0] != '--device' or not re.fullmatch(UUID_PATTERN, args[1]) or \
            args[2] != '--run-nonce' or not re.fullmatch(UUID_PATTERN, args[3]):
        print('syntheticMapPan=invalidArguments'); return 1
    try:
        result = subprocess.run(['xcrun', 'simctl', 'get_app_container', args[1], BUNDLE, 'data'],
                                capture_output=True, timeout=15, check=True)
        require(len(result.stdout) <= 4096)
        packets = {mode: read_packet(result.stdout.decode('utf-8').strip(), mode) for mode in MODES}
        require(all(p['runNonce'] == args[3] for p in packets.values()))
        for mode in MODES:
            print('syntheticMapPan=' + json.dumps(packets[mode], separators=(',', ':'), sort_keys=True))
        print('syntheticMapPanComparison=' + json.dumps(comparison(*packets.values()), separators=(',', ':'), sort_keys=True))
        return 0
    except Exception:
        print('syntheticMapPan=unavailableOrInvalid'); return 1


if __name__ == '__main__':
    raise SystemExit(main())
