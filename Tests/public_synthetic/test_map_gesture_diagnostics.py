import contextlib
import importlib.util
import json
import io
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('map_diagnostics', ROOT / 'scripts/public-map-gesture-diagnostics.py')
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)
NONCE = '12345678-1234-1234-1234-123456789abc'

def packet(mode='production'):
    return {'schemaVersion':1, 'mode':mode, 'runNonce':NONCE, 'samples':100, 'armed':True,
            'mapAcquisitions':1, 'maxVisibleMaps':1, 'discoveryTruncated':False, 'pinchRecognizerCount':1,
            'mapBounds':[0,0,402,874], 'mapWindowFrame':[0,0,402,874],
            'probeWindowFrame':[0,116,402,369], 'safeInsets':[116,0,389,0],
            'zoomEnabled':True, 'scrollEnabled':True, 'interactionEnabled':True,
            'initialCamera':[36.06882,-115.2497,1083,270,0,1083],
            'lastCamera':[36.06882,-115.2497,1083,270,0,1083],
            'minDistance':1083, 'maxDistance':1083,
            'firstMapTwoTouchSample':50, 'gestureMinDistance':1083, 'gestureMaxDistance':1083,
            'recognizers':[{'kind':2, 'insideMap':True, 'enabled':True, 'states':[0,1,2],
                            'maxTouches':2, 'points':[[100,250,1,0],[300,350,1,0]]}],
            'hitGrid':[[100,250,1,0]] * 9}

class MapGestureDiagnosticsTests(unittest.TestCase):
    def test_accepts_only_fixed_schema_and_bounded_scalars(self):
        self.assertEqual(diagnostics.validate(packet(), 'production'), packet())
        for key, value in [('ownerNotes','PRIVATE'), ('samples',True), ('runNonce','private/path'),
                           ('maxDistance',float('nan')), ('hitGrid',[[100,200,'private',0]] * 9)]:
            candidate = packet(); candidate[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                diagnostics.validate(candidate, 'production')

    def test_recognizer_counts_states_and_touch_samples_are_bounded(self):
        for change in [dict(states=list(range(7))), dict(points=[[1,2,1,0]] * 9),
                       dict(maxTouches=9), dict(enabled='private'), dict(kind=0)]:
            candidate = packet(); candidate['recognizers'][0].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                diagnostics.validate(candidate, 'production')
        candidate = packet(); candidate['recognizers'] *= 33
        with self.assertRaises(ValueError): diagnostics.validate(candidate, 'production')

    def test_control_requires_same_native_geometry_actual_zoom_and_single_map(self):
        production, bare = packet(), packet('bare')
        self.assertFalse(diagnostics.comparison(production, bare)['bareZoomChanged'])
        bare['gestureMinDistance'] = 800
        result = diagnostics.comparison(production, bare)
        self.assertTrue(result['bareZoomChanged'])
        self.assertTrue(result['sameNativeGeometry'])
        self.assertFalse(result['releaseEligible'])
        bare['probeWindowFrame'][3] -= 10
        self.assertFalse(diagnostics.comparison(production, bare)['sameNativeGeometry'])
        bare['maxVisibleMaps'] = 2
        self.assertFalse(diagnostics.comparison(production, bare)['bareZoomChanged'])

    def test_startup_motion_or_ancestor_touches_cannot_qualify_bare_control(self):
        production, bare = packet(), packet('bare')
        bare['minDistance'] = 700
        self.assertFalse(diagnostics.comparison(production, bare)['bareZoomChanged'])
        bare['firstMapTwoTouchSample'] = 0
        bare['gestureMinDistance'] = bare['gestureMaxDistance'] = 0
        self.assertFalse(diagnostics.comparison(production, bare)['bareTwoTouchObserved'])
        bare['firstMapTwoTouchSample'] = 50
        bare['gestureMinDistance'], bare['gestureMaxDistance'] = 800, 1083
        bare['recognizers'][0]['insideMap'] = False
        with self.assertRaises(ValueError): diagnostics.validate(bare, 'bare')
        bare['recognizers'][0]['insideMap'] = True
        for key, value in [('mapAcquisitions',2), ('discoveryTruncated',True)]:
            candidate = dict(bare); candidate[key] = value
            self.assertFalse(diagnostics.comparison(production, candidate)['bareZoomChanged'])

    def test_duplicate_keys_are_rejected_before_logging(self):
        with self.assertRaises(ValueError):
            json.loads('{"mode":"production","mode":"bare"}', object_pairs_hook=diagnostics.unique_object)

    def test_stale_launch_receipt_is_rejected_before_packet_output(self):
        bare = packet('bare'); bare['runNonce'] = 'ffffffff-1234-1234-1234-123456789abc'
        output = io.StringIO()
        with patch.object(diagnostics.subprocess, 'run', return_value=SimpleNamespace(stdout=b'/synthetic/container\n')), \
             patch.object(diagnostics, 'read_packet', side_effect=[packet(), bare]), contextlib.redirect_stdout(output):
            status = diagnostics.main(['--device', NONCE, '--run-nonce', NONCE])
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), 'syntheticMapGesture=unavailableOrInvalid\n')

    @unittest.skipUnless(os.name == 'posix', 'Secure collector uses runner POSIX directory descriptors')
    def test_reader_rejects_symlinked_fixed_file_and_unknown_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            cache = root / 'Library/Caches/SyntheticUIDiagnostics'
            cache.mkdir(parents=True)
            file = cache / 'map-gesture-production.json'
            file.write_text(json.dumps(packet()))
            self.assertEqual(diagnostics.read_packet(root, 'production')['runNonce'], NONCE)
            other = root / 'other.json'; other.write_text(json.dumps(packet()))
            file.unlink(); file.symlink_to(other)
            with self.assertRaises(OSError): diagnostics.read_packet(root, 'production')
            with self.assertRaises(ValueError): diagnostics.read_packet(root, '../other')

if __name__ == '__main__':
    unittest.main()
