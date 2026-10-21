import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('style_watch', ROOT / 'scripts/public-map-style-watch.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MapStyleWatchTests(unittest.TestCase):
    def test_stack_output_contains_only_known_modules_and_bounded_symbols(self):
        raw = ' + 100 AG::Graph::update() (in AttributeGraph) + 32 [0x1234]\n'
        raw += ' + 100 DISALLOWED_MARKER /private/path discarded=value (in UnknownModule) + 4\n'
        raw += ' + 50 ' + 'x' * 300 + '/private/path (in SwiftUI) + 7\n'
        frames = MODULE.safe_frames(raw)
        self.assertEqual(frames[0], {'module': 'AttributeGraph', 'function': 'AG::Graph::update()', 'thread': 'unknown'})
        self.assertEqual(len(frames), 2)
        self.assertEqual(len(frames[1]['function']), 160)
        self.assertNotIn('/private', repr(frames))
        self.assertNotIn('DISALLOWED_MARKER', repr(frames))

    def test_stack_output_is_capped_and_deduplicated(self):
        raw = '\n'.join(' + 1 method' + str(i) + '() (in MapKit) + 4' for i in range(100))
        self.assertEqual(len(MODULE.safe_frames(raw)), 48)
        self.assertEqual(len(MODULE.safe_frames(raw.splitlines()[0] + '\n' + raw.splitlines()[0])), 1)

    def test_thread_classification_requires_an_observed_header(self):
        raw = '100 Thread_123 DispatchQueue_1: com.apple.main-thread (serial)\n'
        raw += ' + 100 AG::Graph::update() (in AttributeGraph) + 32\n'
        raw += '100 Thread_456 DispatchQueue_2: other (serial)\n'
        raw += ' + 100 AG::Graph::update() (in AttributeGraph) + 32\n'
        frames = MODULE.safe_frames(raw)
        self.assertEqual([frame['thread'] for frame in frames], ['main', 'other'])

    def test_failed_sampling_reports_fixed_phase_and_duration_without_exception_details(self):
        device = '12345678-1234-1234-1234-123456789012'
        path = '/coresimulator/devices/' + device + '/data/ApartmentFinder.app/ApartmentFinder'
        results = [subprocess.CompletedProcess([], 0, '42 ' + path),
                   subprocess.CompletedProcess([], 0, '24.9'),
                   subprocess.TimeoutExpired('PRIVATE_MARKER', 8)]
        with tempfile.TemporaryDirectory() as folder, patch.dict(os.environ, RUNNER_TEMP=folder), patch.object(MODULE.subprocess, 'run', side_effect=results):
            packet = MODULE.capture(device, 'afterDrag25', 'app', MODULE.TARGETS['app'])
        self.assertEqual(packet['status'], 'commandTimedOut')
        self.assertEqual(packet['failurePhase'], 'sample')
        self.assertGreaterEqual(packet['durationMilliseconds'], 0)
        self.assertNotIn('PRIVATE_MARKER', json.dumps(packet))
