#!/usr/bin/env python3
"""Read only two fixed synthetic cache packets; never enumerate or upload files."""
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
MODES = ('production', 'bare')
FIELDS = {'schemaVersion', 'mode', 'runNonce', 'samples', 'mapAcquisitions', 'maxVisibleMaps', 'discoveryTruncated', 'pinchRecognizerCount', 'armed', 'mapBounds', 'mapWindowFrame',
          'probeWindowFrame', 'safeInsets', 'zoomEnabled', 'scrollEnabled',
          'interactionEnabled', 'initialCamera', 'lastCamera', 'minDistance',
          'maxDistance', 'firstMapTwoTouchSample', 'gestureMinDistance', 'gestureMaxDistance', 'recognizers', 'hitGrid'}

def require(value):
    if not value:
        raise ValueError('Invalid synthetic map packet')

def integer(value, minimum, maximum):
    require(type(value) is int and minimum <= value <= maximum)

def numbers(value, length, limit):
    require(type(value) is list and len(value) == length)
    require(all(type(x) in (int, float) and math.isfinite(x) and abs(x) <= limit for x in value))

def point(value):
    numbers(value, 4, 10000)
    require(value[2] in (0, 1) and value[3] in (0, 1))

UUID_PATTERN = r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}'

def validate(packet, mode):
    require(mode in MODES and type(packet) is dict and set(packet) == FIELDS)
    require(packet['mode'] == mode)
    require(type(packet['runNonce']) is str and re.fullmatch(UUID_PATTERN, packet['runNonce']))
    integer(packet['schemaVersion'], 1, 1)
    integer(packet['samples'], 1, 1800)
    integer(packet['mapAcquisitions'], 1, 64)
    integer(packet['maxVisibleMaps'], 1, 64)
    integer(packet['firstMapTwoTouchSample'], 0, packet['samples'])
    integer(packet['pinchRecognizerCount'], 0, 32)
    for key in ('armed', 'zoomEnabled', 'scrollEnabled', 'interactionEnabled', 'discoveryTruncated'):
        require(type(packet[key]) is bool)
    for key in ('mapBounds', 'mapWindowFrame', 'probeWindowFrame', 'safeInsets'):
        numbers(packet[key], 4, 10000)
    for key in ('mapBounds', 'mapWindowFrame', 'probeWindowFrame'):
        require(packet[key][2] > 0 and packet[key][3] > 0)
    for key in ('initialCamera', 'lastCamera'):
        numbers(packet[key], 6 if packet['armed'] else 0, 40_000_000)
        if packet['armed']:
            camera = packet[key]
            require(abs(camera[0]) <= 90 and abs(camera[1]) <= 180 and
                    0 < camera[2] <= 40_000_000 and -360 <= camera[3] <= 720 and abs(camera[4]) <= 90)
    for key in ('minDistance', 'maxDistance', 'gestureMinDistance', 'gestureMaxDistance'):
        require(type(packet[key]) in (int, float) and math.isfinite(packet[key]) and 0 <= packet[key] <= 40_000_000)
    require(packet['maxDistance'] >= packet['minDistance'])
    require(packet['gestureMaxDistance'] >= packet['gestureMinDistance'])
    if packet['firstMapTwoTouchSample']:
        require(packet['armed'] and packet['gestureMinDistance'] > 0)
    else:
        require(packet['gestureMinDistance'] == packet['gestureMaxDistance'] == 0)
    require(type(packet['recognizers']) is list and len(packet['recognizers']) <= 32)
    for recognizer in packet['recognizers']:
        require(type(recognizer) is dict and set(recognizer) == {'kind', 'insideMap', 'enabled', 'states', 'maxTouches', 'points'})
        require(type(recognizer['insideMap']) is bool and type(recognizer['enabled']) is bool)
        integer(recognizer['kind'], 0, 2)
        integer(recognizer['maxTouches'], 0, 8)
        require(type(recognizer['states']) is list and len(recognizer['states']) <= 6)
        for state in recognizer['states']:
            integer(state, 0, 5)
        require(len(recognizer['states']) == len(set(recognizer['states'])))
        require(type(recognizer['points']) is list and len(recognizer['points']) <= 8)
        for value in recognizer['points']:
            point(value)
    require(packet['pinchRecognizerCount'] == sum(r['kind'] == 2 for r in packet['recognizers']))
    if packet['firstMapTwoTouchSample']:
        require(any(r['insideMap'] and r['maxTouches'] >= 2 for r in packet['recognizers']))
    require(type(packet['hitGrid']) is list and len(packet['hitGrid']) in (0, 9))
    for value in packet['hitGrid']:
        point(value)
    return packet

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result

def read_packet(container, mode):
    require(mode in MODES)
    root = Path(container)
    require(root.is_absolute() and '..' not in root.parts)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with contextlib.ExitStack() as handles:
        directory = os.open('/', flags)
        handles.callback(os.close, directory)
        for part in root.parts[1:] + ('Library', 'Caches', 'SyntheticUIDiagnostics'):
            directory = os.open(part, flags, dir_fd=directory)
            handles.callback(os.close, directory)
        descriptor = os.open('map-gesture-' + mode + '.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                             dir_fd=directory)
        handles.callback(os.close, descriptor)
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and 0 < info.st_size <= 16384)
        data = os.read(descriptor, 16385)
        require(len(data) == info.st_size and len(data) <= 16384)
    return validate(json.loads(data, object_pairs_hook=unique_object), mode)

def comparison(production, bare):
    same_geometry = all(all(abs(a-b) <= 1 for a, b in zip(production[key], bare[key]))
                        for key in ('mapBounds', 'mapWindowFrame', 'probeWindowFrame', 'safeInsets'))
    armed = production['armed'] and bare['armed']
    single_map = (production['mapAcquisitions'] == bare['mapAcquisitions'] == 1 and
                  production['maxVisibleMaps'] == bare['maxVisibleMaps'] == 1 and
                  not production['discoveryTruncated'] and not bare['discoveryTruncated'])
    delta = bare['gestureMaxDistance'] - bare['gestureMinDistance']
    bare_two_touch = bare['firstMapTwoTouchSample'] > 0
    return {'sameNativeGeometry': same_geometry, 'bothArmed': armed, 'singleMapPerPhase': single_map,
            'bareGestureDistanceChange': delta, 'bareZoomChanged': bool(armed and single_map and bare_two_touch and delta > 20),
            'bareTwoTouchObserved': bare_two_touch,
            'productionTwoTouchObserved': production['firstMapTwoTouchSample'] > 0,
            'diagnosticOnly': True, 'releaseEligible': False}

def main(arguments=None):
    args = list(sys.argv[1:] if arguments is None else arguments)
    if len(args) != 4 or args[0] != '--device' or not re.fullmatch(UUID_PATTERN, args[1]) or args[2] != '--run-nonce' or not re.fullmatch(UUID_PATTERN, args[3]):
        print('syntheticMapGesture=invalidDevice'); return 1
    try:
        result = subprocess.run(['xcrun', 'simctl', 'get_app_container', args[1], BUNDLE, 'data'],
                                capture_output=True, timeout=15, check=True)
        require(len(result.stdout) <= 4096)
        container = result.stdout.decode('utf-8').strip()
        packets = {mode: read_packet(container, mode) for mode in MODES}
        require(all(packet['runNonce'] == args[3] for packet in packets.values()))
        for mode in MODES:
            print('syntheticMapGesture=' + json.dumps(packets[mode], separators=(',', ':'), sort_keys=True))
        outcome = comparison(packets['production'], packets['bare'])
        print('syntheticMapGestureComparison=' + json.dumps(outcome, separators=(',', ':'), sort_keys=True))
        return int(not (outcome['sameNativeGeometry'] and outcome['bothArmed'] and outcome['singleMapPerPhase'] and outcome['bareZoomChanged']))
    except Exception:
        print('syntheticMapGesture=unavailableOrInvalid'); return 1

if __name__ == '__main__':
    raise SystemExit(main())
