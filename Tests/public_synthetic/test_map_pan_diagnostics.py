"""Privacy and qualification checks for the failure-only, public-fixture pan probe."""
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('pan_diagnostics', ROOT / 'scripts/public-map-pan-diagnostics.py')
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)
NONCE = '12345678-1234-1234-1234-123456789abc'


def packet(mode='interactive'):
    return dict(schemaVersion=1, mode=mode, runNonce=NONCE, samples=100, armed=True,
        mapAcquisitions=1, maxVisibleMaps=1, discoveryTruncated=False, maxSampleGap=0.06,
        mapWindowFrame=[0, 0, 402, 874], safeInsets=[116, 0, 397, 0],
        initialCamera=[36.069320249007106, -115.24893638491625, 650, 0, 0, 650],
        lastCamera=[36.069320249007106, -115.24893638491625, 650, 0, 0, 650],
        scrollEnabled=True, interactionEnabled=True, panRecognizerCount=1,
        path=[[241.2, 296.5], [281.4, 296.5]], hitPath=[[241.2, 296.5, 1, 0], [281.4, 296.5, 1, 0]],
        recognizers=[dict(enabled=True, states=[0], maxTouches=0, maxTranslation=[0, 0], points=[])])


class MapPanDiagnosticsTests(unittest.TestCase):
    def test_swift_writer_and_reader_share_the_exact_receipt_fields(self):
        source = (ROOT / 'App/SyntheticMapPanProbe.swift').read_text(encoding='utf-8')
        receipt = source.split('private struct Receipt: Encodable {', 1)[1].split('\n        }', 1)[0]
        self.assertEqual(set(re.findall(r'^\s*(?:let|var) (\w+)', receipt, re.M)), diagnostics.FIELDS)

    def test_valid_packets_have_a_closed_numeric_schema(self):
        for mode in diagnostics.MODES:
            value = packet(mode)
            self.assertEqual(diagnostics.validate(value, mode), value)
        for mutation in ('notes', 'manifest', 'pathToFile'):
            value = packet(); value[mutation] = 'private'
            with self.assertRaises(ValueError): diagnostics.validate(value, 'interactive')

    def test_rejects_nonfinite_unbounded_and_duplicate_data(self):
        for key, value in [('samples', 3001), ('maxSampleGap', float('nan')),
                           ('recognizers', packet()['recognizers'] * 17), ('path', [[0, 0]])]:
            candidate = packet(); candidate[key] = value
            with self.assertRaises(ValueError): diagnostics.validate(candidate, 'interactive')
        with self.assertRaises(ValueError):
            json.loads('{"mode":"interactive","mode":"disabled"}', object_pairs_hook=diagnostics.unique_object)

    def test_qualified_comparison_needs_complete_matching_native_observation(self):
        a, b = packet(), packet('disabled')
        self.assertTrue(diagnostics.comparison(a, b)['matchedNativeSetup'])
        for key, value in [('discoveryTruncated', True), ('mapAcquisitions', 2),
                           ('maxVisibleMaps', 2), ('maxSampleGap', 0.3), ('armed', False),
                           ('scrollEnabled', False), ('interactionEnabled', False)]:
            changed = copy.deepcopy(b); changed[key] = value
            self.assertFalse(diagnostics.comparison(a, changed)['matchedNativeSetup'])
        b['initialCamera'][0] += 0.001
        self.assertFalse(diagnostics.comparison(a, b)['matchedNativeSetup'])

    def test_native_touch_delivery_and_camera_motion_are_separate_observations(self):
        a, b = packet(), packet('disabled')
        b['recognizers'][0].update(states=[0, 1, 2], maxTouches=1, maxTranslation=[40, 0])
        result = diagnostics.comparison(a, b)
        self.assertTrue(result['disabledNativePanTouchObserved'])
        self.assertFalse(result['disabledNativeCenterChanged'])
        b['lastCamera'][1] += 0.0001
        result = diagnostics.comparison(a, b)
        self.assertTrue(result['disabledNativeCenterChanged'])
        self.assertFalse(result['releaseEligible'])
        self.assertNotIn('causeProven', result)

    def test_stale_or_invalid_receipts_are_not_printed(self):
        b = packet('disabled'); b['runNonce'] = 'ffffffff-1234-1234-1234-123456789abc'
        output = io.StringIO()
        with patch.object(diagnostics.subprocess, 'run', return_value=SimpleNamespace(stdout=b'/synthetic/container\n')), \
             patch.object(diagnostics, 'read_packet', side_effect=[packet(), b]), contextlib.redirect_stdout(output):
            status = diagnostics.main(['--device', NONCE, '--run-nonce', NONCE])
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), 'syntheticMapPan=unavailableOrInvalid\n')

    @unittest.skipUnless(os.name == 'posix', 'Secure runner reader uses POSIX directory descriptors')
    def test_reader_rejects_symlink_and_unknown_fixed_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cache = root / 'Library/Caches/SyntheticUIDiagnostics'; cache.mkdir(parents=True)
            file = cache / 'map-pan-interactive.json'; file.write_text(json.dumps(packet()))
            self.assertEqual(diagnostics.read_packet(root, 'interactive')['runNonce'], NONCE)
            other = root / 'other.json'; other.write_text(json.dumps(packet()))
            file.unlink(); file.symlink_to(other)
            with self.assertRaises(OSError): diagnostics.read_packet(root, 'interactive')
            with self.assertRaises(ValueError): diagnostics.read_packet(root, '../other')

    def test_failure_is_asserted_before_teardown_diagnostics_and_witnesses_are_saved(self):
        source = (ROOT / 'UITests/MapAppearanceTests.swift').read_text(encoding='utf-8')
        assertion = source.index('XCTAssertGreaterThan(abs(originalTip.x - initialX), 5,')
        self.assertLess(source.index('panFailureWitness = PanFailureWitness('), assertion)
        self.assertLess(source.index('let originalAfterFrame = firstPin.frame'), assertion)
        self.assertIn('after=\\(originalAfterFrame)', source)
        teardown = source.split('override func tearDown()', 1)[1].split('private func expectStyle', 1)[0]
        self.assertLess(teardown.index('Map appearance final screen'), teardown.index('diagnosePanFailure('))
        helper = source.split('private func diagnosePanFailure(', 1)[1].split('private func expectStyle', 1)[0]
        self.assertNotIn('XCTAssert', helper)
        self.assertNotIn('XCTFail', helper)
        self.assertIn('witness.start', helper)
        self.assertIn('witness.end', helper)

    def test_simulator_probe_is_opt_in_read_only_and_ordinary_branch_is_direct(self):
        source = (ROOT / 'App/SyntheticMapPanProbe.swift').read_text(encoding='utf-8')
        for gate in ('#if DEBUG && targetEnvironment(simulator)', 'UITestSupport.storeURL() != nil',
                     '--tuscano-manifest', '--synthetic-map-pan-diagnostics', 'UUID(uuidString:'):
            self.assertIn(gate, source)
        for forbidden in ('addGestureRecognizer', 'addTarget', '.delegate =', '.camera =',
                          'debugDescription', 'accessibilityLabel', 'store.personal', 'print(', 'NSLog('):
            self.assertNotIn(forbidden, source)
        overlay = (ROOT / 'App/ApartmentDeliveryMap.swift').read_text(encoding='utf-8')
        self.assertIn('projectedPinContents(pins, proxy: proxy, revision: revision)\n                .allowsHitTesting(!SyntheticMapPanProbe.pinsDisabled)', overlay)
        self.assertIn('} else { projectedPinContents(pins, proxy: proxy, revision: revision) }', overlay)

    def test_baseline_is_frozen_and_does_not_replace_the_six_acceptance_cases(self):
        baseline = (ROOT / 'scripts/public-map-pan-baseline.sh').read_text(encoding='utf-8')
        self.assertIn('BASELINE_SHA=bee0e05688a6e825c4938f6483169cd6fb8e536a', baseline)
        self.assertIn('TEST_BLOB=5684a2464d19e22d1aa66f4334a09d46e416ec0e', baseline)
        self.assertIn('git worktree add --detach', baseline)
        self.assertNotIn('git push', baseline)
        self.assertIn('passed+failed==1 and skipped==0', baseline)
        self.assertIn('Baseline test identity mismatch', baseline)
        workflow = (ROOT / '.github/workflows/public-synthetic-check.yml').read_text(encoding='utf-8')
        self.assertIn('          - community-area-controls-regression', workflow)
        self.assertIn("'community-area-controls-regression':6", workflow)
        self.assertIn('EXPECTED_NATIVE_COUNT=6', workflow)
        self.assertIn('TEST_RUNNER_APARTMENTFINDER_MAP_PAN_RUN_NONCE=', workflow)
        self.assertIn('"$XCODE_STATUS" != 0', workflow)


if __name__ == '__main__':
    unittest.main()
