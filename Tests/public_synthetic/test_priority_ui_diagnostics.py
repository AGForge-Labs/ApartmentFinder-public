import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / file)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


UI = module('priority_ui', 'public_priority_ui.py')
CLEANUP = module('priority_cleanup', 'public-map-style-cleanup.py')


class PriorityUIDiagnosticTests(unittest.TestCase):
    def test_partitions_are_disjoint_and_cover_all_original_ui_cases(self):
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        warm = UI.selected_cases('map-style-warm-diagnostics', profile)
        remaining = UI.selected_cases('reviewed-geography-regression', profile)
        self.assertEqual(len(warm['ui']), 3)
        self.assertEqual(len(remaining['ui']), 5)
        self.assertFalse(set(warm['ui']) & set(remaining['ui']))
        self.assertEqual(set(warm['ui'] + remaining['ui']), set(profile['ui']))
        self.assertEqual(warm['native'] + remaining['native'], [])
        self.assertEqual((len(profile['core']), len(profile['native']), len(profile['ui'])), (143, 71, 8))
        for altered in (profile['ui'][:-1], profile['ui'][:-1] + profile['ui'][:1],
                        profile['ui'][:-1] + ['ApartmentFinderUITests/Other/testDifferent']):
            with self.assertRaises(AssertionError):
                UI.selected_cases('reviewed-geography-regression', {**profile, 'ui': altered})

    def test_warm_comparison_requires_actual_three_case_order(self):
        rows = ["Test Case '-[ApartmentFinderUITests." + value.split('/')[1] + ' ' + value.split('/')[2] + "]' started." for value in UI.WARM]
        UI.verify_warm_order('\n'.join(rows))
        for altered in (rows[::-1], rows[1:], rows + rows[:1]):
            with self.assertRaises(AssertionError):
                UI.verify_warm_order('\n'.join(altered))

    def test_geography_fallback_keeps_all_three_original_bodies_and_full_profile(self):
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        before = json.dumps(profile, sort_keys=True)
        cases = UI.selected_cases('reviewed-geography-only-regression', profile)
        self.assertEqual(cases['native'], [])
        self.assertEqual(len(cases['ui']), 3)
        self.assertEqual(set(cases['ui']), {identity for identity in profile['ui'] if '/Reviewed89123GeographyUITests/' in identity})
        self.assertEqual(json.dumps(profile, sort_keys=True), before)

    def test_ontrac_observation_selects_only_original_source_pin_case_without_changing_full_gate(self):
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        before = json.dumps(profile, sort_keys=True)
        cases = UI.selected_cases('ontrac-pan-observation', profile)
        self.assertEqual(cases, {'native': [], 'ui': [
            'ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport']})
        self.assertEqual(json.dumps(profile, sort_keys=True), before)
        self.assertEqual((len(profile['core']), len(profile['native']), len(profile['ui'])), (143, 71, 8))

    def test_cleanup_reports_only_selected_state_and_rejects_ambiguous_malformed_input(self):
        selected = {'udid': 'selected', 'state': 'Shutdown', 'name': 'PRIVATE_MARKER'}
        unrelated = {'udid': 'other', 'state': 'Booted', 'name': 'OTHER_PRIVATE'}
        def raw(rows): return json.dumps({'devices': {'runtime': rows}})
        self.assertEqual(CLEANUP.selected_state(raw([unrelated, selected]), 'selected'), 'Shutdown')
        self.assertEqual(CLEANUP.selected_state(raw([unrelated]), 'selected'), 'absent')
        self.assertEqual(CLEANUP.selected_state(raw([selected, selected]), 'selected'), 'ambiguous')
        for value in ('not json', '[]', '{"devices":{"x":[42]}}'):
            self.assertEqual(CLEANUP.selected_state(value, 'selected'), 'unavailable')

    def test_cleanup_timeout_is_retained_even_if_later_deletion_succeeds(self):
        device = '12345678-1234-1234-1234-123456789012'
        packets = [{'status': 'timedOut', 'after': 'Booted'}, {'status': 'complete', 'after': 'absent'}]
        with patch.object(sys, 'argv', ['cleanup', '--device', device]), patch.object(CLEANUP, 'operation', side_effect=packets):
            self.assertEqual(CLEANUP.main(), 1)
        process = Mock(pid=123)
        process.wait.side_effect = [subprocess.TimeoutExpired('PRIVATE_MARKER', 10), 0]
        with patch.object(CLEANUP, 'state', side_effect=['Booted', 'Shutdown']), patch.object(CLEANUP.subprocess, 'Popen', return_value=process), patch.object(CLEANUP.os, 'killpg', create=True) as kill, patch.object(CLEANUP.signal, 'SIGKILL', 9, create=True):
            packet = CLEANUP.operation(device, 'shutdown')
        self.assertEqual(packet['status'], 'timedOut')
        self.assertEqual(packet['before'], 'Booted')
        self.assertEqual(packet['after'], 'Shutdown')
        self.assertEqual([call.kwargs['timeout'] for call in process.wait.call_args_list], [10, 2])
        kill.assert_called_once()
        self.assertNotIn('PRIVATE_MARKER', json.dumps(packet))
