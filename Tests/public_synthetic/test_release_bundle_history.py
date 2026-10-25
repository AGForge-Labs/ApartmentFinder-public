"""Actual reviewed bundle deltas are sealed before any historical projection."""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest

import reviewed_bundle_history as previous
import reviewed_release_bundle_history as current


class ReleaseBundleHistoryTests(unittest.TestCase):
    def test_exact_release_projects_previous_whole_snapshot_without_mutation(self):
        values = current.load_current_resources()
        before = current.fingerprint(values)
        projected = current.project_to_previous(values)
        self.assertEqual(current.fingerprint(values), before)
        self.assertEqual(values['public-catalog.json']['packVersion'],
                         '2026.10.25.13-public-valley-ventana-provider-unit-areas')
        self.assertEqual((len(values['public-catalog.json']['communities']),
                          len(values['public-locations.geojson']['features']),
                          len(values['public-catalog.json']['sources'])), (193, 28458, 1076))
        self.assertEqual((len(projected['public-catalog.json']['communities']),
                          len(projected['public-locations.geojson']['features']),
                          len(projected['public-catalog.json']['sources'])), (186, 23533, 939))
        self.assertEqual(projected['public-locations.geojson']['features'],
                         values['public-locations.geojson']['features'][:23533])
        self.assertEqual(projected['public-catalog.json']['sources'], values['public-catalog.json']['sources'][:939])
        self.assertEqual(projected['public-catalog.json']['unitBuildingAssociations'],
                         values['public-catalog.json']['unitBuildingAssociations'])
        self.assertEqual(projected['public-catalog.json']['unitFloorReferences'],
                         values['public-catalog.json']['unitFloorReferences'])
        self.assertEqual(projected['public-paths.geojson']['features'], values['public-paths.geojson']['features'])
        self.assertEqual(current.historical_resources(), previous.historical_resources(projected))

    def test_changed_old_added_or_reordered_features_and_sources_fail_before_projection(self):
        values = current.load_current_resources()
        for mutation in ('old-coordinate', 'new-coordinate', 'old-source', 'new-source', 'reorder', 'path'):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(values)
                if mutation in ('old-coordinate', 'new-coordinate'):
                    index = 0 if mutation == 'old-coordinate' else -1
                    changed['public-locations.geojson']['features'][index]['geometry']['coordinates'][0] += .0001
                elif mutation in ('old-source', 'new-source'):
                    index = 0 if mutation == 'old-source' else -1
                    changed['public-catalog.json']['sources'][index]['url'] = 'https://example.invalid/unreviewed'
                elif mutation == 'reorder':
                    changed['public-locations.geojson']['features'][0:2] = reversed(changed['public-locations.geojson']['features'][0:2])
                else:
                    changed['public-paths.geojson']['features'][0]['properties']['confirmed'] = True
                before = current.fingerprint(changed)
                with self.assertRaises(AssertionError):
                    current.project_to_previous(changed)
                self.assertEqual(current.fingerprint(changed), before)

    def test_locker_address_metadata_and_malformed_resource_sets_are_rejected(self):
        values = current.load_current_resources()
        for mutation in ('locker', 'address', 'version', 'date', 'scope', 'missing-file', 'extra-file'):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(values)
                if mutation == 'locker':
                    community = next(c for c in changed['public-catalog.json']['communities'] if c['id'] == 'parkside-villas')
                    community['digitalLocker']['provider'] = 'Unreviewed vendor'
                elif mutation == 'address':
                    changed['known-addresses.json']['entries'][0]['address'] = 'Unreviewed address'
                elif mutation == 'version':
                    changed['public-catalog.json']['packVersion'] += '-unreviewed'
                elif mutation == 'date':
                    changed['public-catalog.json']['generatedAt'] = '2000-01-01'
                elif mutation == 'scope':
                    changed['public-catalog.json']['scopeZIPs'].append('00000')
                elif mutation == 'missing-file':
                    del changed['public-paths.geojson']
                else:
                    changed['private.json'] = {}
                with self.assertRaises(AssertionError):
                    current.project_to_previous(changed)

    def test_raw_resource_review_index_and_byte_budget_mismatches_fail(self):
        for name, mutation in [('public-catalog.json', 'same-length'),
                               ('public-locations.geojson', 'oversize'),
                               ('public-catalog-review.json', 'same-length'),
                               ('known-addresses.json', 'same-length')]:
            with self.subTest(resource=name, mutation=mutation), tempfile.TemporaryDirectory() as folder:
                directory = Path(folder)
                for source in (current.ROOT / 'data').iterdir():
                    if source.is_file(): shutil.copyfile(source, directory / source.name)
                path = directory / name
                body = path.read_bytes()
                path.write_bytes(body + b' ' if mutation == 'oversize' else b'!' + body[1:])
                with self.assertRaises(AssertionError):
                    current.load_current_resources(directory)

    def test_unchanged_legacy_layer_and_seal_keep_original_mutation_guards(self):
        root = Path(previous.__file__).parent
        self.assertEqual(hashlib.sha256((root / 'reviewed_bundle_history.py').read_bytes()).hexdigest(),
                         '262aa1bc99bbb6c820a355232aecc605fc199ad35323c7b45204a158c81bfb36')
        self.assertEqual(hashlib.sha256((root / 'reviewed-valley-history-seal.json').read_bytes()).hexdigest(),
                         'f3804100f8608db6888b6516d3c29e59eb071e43cda597bbe2732815eca1bf17')
        previous_values = current.load_reviewed_resources()
        old_projection = current.historical_resources(previous_values)
        self.assertEqual(old_projection, previous.historical_resources(previous_values))
        changed = copy.deepcopy(previous_values)
        changed['public-locations.geojson']['features'][0]['geometry']['coordinates'][0] += .0001
        with self.assertRaises(AssertionError):
            current.historical_resources(changed)


if __name__ == '__main__':
    unittest.main()
