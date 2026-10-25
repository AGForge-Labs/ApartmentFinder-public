"""Electronic locker feed contracts; fixtures contain no real property claims."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class DigitalLockerExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.export_count = 0
        self.catalog = dict(schemaVersion=1, packVersion='fixture', generatedAt='2026-10-24',
            scopeZIPs=['89123'], sources=[dict(id='amenity', title='Fictional electronic locker evidence',
            url='https://example.invalid/amenities', retrievedAt='2026-10-24'),
            dict(id='position', title='Fictional locker location', url='https://example.invalid/map', retrievedAt='2026-10-24')],
            communities=[dict(id='fictional', name='Fictional', address='100 Fictional Rd', zip='89123',
            aliases=[], sourceIDs=['amenity'], researchStatus='reviewed', gapNotes=[])],
            coverage=dict(inventoryComplete=False, notes=[]))
        self.evidence = dict(status='present', brand='Luxer One', placementDescription='Inside the leasing lobby',
            sourceIDs=['amenity'], checkedAt='2026-10-24')

    def export(self):
        self.export_count += 1
        self.output = self.root / ('output-' + str(self.export_count))
        self.catalog['communities'][0]['digitalLocker'] = self.evidence
        (self.source / 'catalog.json').write_text(json.dumps(self.catalog))
        for name in ('locations.geojson', 'paths.geojson'):
            (self.source / name).write_text(json.dumps(dict(type='FeatureCollection', schemaVersion=1, packVersion='fixture', features=[])))
        return subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/public-catalog.py'), 'prepare',
            '--source', str(self.source), '--output', str(self.output), '--version', '2026.10.24.1-test'],
            text=True, capture_output=True)

    def test_existence_only_evidence_survives_without_a_fabricated_coordinate(self):
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads((self.output / 'public-catalog.json').read_text())['communities'][0]['digitalLocker']
        self.assertEqual(actual['status'], 'present')
        self.assertEqual(actual['brand'], 'Luxer One')
        self.assertNotIn('point', actual)

    def test_explicit_electronic_evidence_can_have_an_unpublished_brand(self):
        self.evidence.pop('brand')
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads((self.output / 'public-catalog.json').read_text())['communities'][0]['digitalLocker']
        self.assertEqual(actual['status'], 'present')
        self.assertNotIn('brand', actual)

    def test_separately_sourced_point_survives(self):
        self.evidence['point'] = dict(longitude=-115.1, latitude=36.1, locationSourceIDs=['position'], precision='sourceMapped')
        result = self.export()
        self.assertEqual(result.returncode, 0, result.stderr)
        actual = json.loads((self.output / 'public-catalog.json').read_text())['communities'][0]['digitalLocker']['point']
        self.assertEqual(actual, dict(longitude=-115.1, latitude=36.1, locationSourceIDs=['position'], precision='sourceMapped'))

    def test_invalid_or_unsupported_evidence_cannot_enter_the_feed(self):
        for label, changes in [('usps', dict(brand='USPS keyed parcel boxes')),
                ('unnamed', dict(brand='')), ('unresolved', dict(sourceIDs=['missing'])),
                ('no-positive-proof', dict(sourceIDs=[])), ('bad-date', dict(checkedAt='tomorrow')),
                ('unexpected', dict(gateCode='private')),
                ('negative-point', dict(status='absent', point=dict(longitude=-115.1, latitude=36.1, locationSourceIDs=['position'], precision='sourceMapped'))),
                ('unknown-point-source', dict(point=dict(longitude=-115.1, latitude=36.1, locationSourceIDs=['missing'], precision='sourceMapped')))]:
            with self.subTest(case=label):
                self.evidence = dict(status='present', brand='Luxer One', sourceIDs=['amenity'], checkedAt='2026-10-24')
                self.evidence.update(changes)
                self.assertNotEqual(self.export().returncode, 0)

    def test_explicit_negative_and_unresearched_remain_distinct(self):
        for status, sources in [('absent', ['amenity']), ('unknown', [])]:
            with self.subTest(status=status):
                self.evidence = dict(status=status, sourceIDs=sources, checkedAt='2026-10-24')
                result = self.export()
                self.assertEqual(result.returncode, 0, result.stderr)
                actual = json.loads((self.output / 'public-catalog.json').read_text())['communities'][0]['digitalLocker']
                self.assertEqual(actual['status'], status)
                self.assertNotIn('point', actual)

    def test_henderson_and_north_las_vegas_are_in_scope_but_other_cities_are_not(self):
        for zip_code, accepted in [('89012', True), ('89031', True), ('89101', True), ('90210', False), ('89027', False)]:
            with self.subTest(zip=zip_code):
                self.catalog['scopeZIPs'] = [zip_code]
                self.catalog['communities'][0]['zip'] = zip_code
                result = self.export()
                self.assertEqual(result.returncode == 0, accepted, result.stderr)
