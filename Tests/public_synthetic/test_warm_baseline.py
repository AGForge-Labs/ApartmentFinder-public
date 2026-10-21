import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from public_priority_ui import WARM, selected_cases


class FrozenWarmBaselineTests(unittest.TestCase):
    def test_control_executes_existing_three_methods_and_keeps_old_full_profile(self):
        profile = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        before = json.dumps(profile, sort_keys=True)
        result = selected_cases('map-style-warm-diagnostics', profile)
        self.assertEqual(result, {'native': [], 'ui': list(WARM)})
        self.assertEqual(len(result['ui']), 3)
        self.assertEqual(json.dumps(profile, sort_keys=True), before)
        for altered in ({**profile, 'ui': []}, {**profile, 'native': []}):
            with self.assertRaises(AssertionError):
                selected_cases('map-style-warm-diagnostics', altered)
