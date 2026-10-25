"""Optional exact public-feed compatibility fixture; no private source pack is loaded."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('retained_public_admission', ROOT / 'scripts/public-catalog.py')
ADMISSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADMISSION)

class PublicRetainedCompatibilityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        configured = os.environ.get('APARTMENTFINDER_PUBLIC_COMPAT_DIRECTORY')
        if not configured:
            raise unittest.SkipTest('Set APARTMENTFINDER_PUBLIC_COMPAT_DIRECTORY to an exact public revision for the optional compatibility check')
        cls.directory = Path(configured)
        cls.manifest = json.loads((cls.directory / 'manifest.json').read_bytes())
        cls.documents = {}
        for name in ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson'):
            body = (cls.directory / name).read_bytes()
            expected = cls.manifest['files'][name]
            if len(body) != expected['bytes'] or hashlib.sha256(body).hexdigest() != expected['sha256']:
                raise AssertionError('Compatibility fixture differs from its public manifest: ' + name)
            cls.documents[name] = json.loads(body)
        cls.feature = next(f for f in cls.documents['public-locations.geojson']['features'] if f['id'].startswith('directory-sector:trend:'))

    def test_exact_manifest_bound_public_revision_remains_admissible(self):
        ADMISSION.validate_payload(self.documents['public-catalog.json'], self.documents['public-locations.geojson'], self.documents['public-paths.geojson'])

    def test_retained_qualification_is_preserved_and_cannot_be_rebound(self):
        self.assertEqual(ADMISSION.position_note(self.feature), self.feature['properties']['notes'])
        for change in ('coordinate', 'notes', 'identity', 'source'):
            with self.subTest(change=change):
                feature = copy.deepcopy(self.feature)
                if change == 'coordinate': feature['geometry']['coordinates'][0] += 0.00001
                elif change == 'notes': feature['properties']['notes'] += ' Altered'
                elif change == 'identity': feature['properties']['unit'] = 'invented-unit'
                else: feature['properties']['sourceIDs'] = ['invented-source']
                with self.assertRaises(ValueError):
                    ADMISSION.position_note(feature)

    def test_retained_cohort_cannot_silently_drop_an_alternate_side(self):
        locations = copy.deepcopy(self.documents['public-locations.geojson'])
        locations['features'] = [f for f in locations['features'] if f['id'] != self.feature['id']]
        with self.assertRaises(ValueError):
            ADMISSION.validate_payload(self.documents['public-catalog.json'], locations, self.documents['public-paths.geojson'])
