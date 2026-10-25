"""Freeze the three admitted side hypotheses and preserve every 26.1 public fact."""
import hashlib
import importlib.util
import json
from pathlib import Path
import unittest

from reviewed_bundle_history import historical_resources


ROOT = Path(__file__).resolve().parents[2]
VERSION = '2026.10.22.2-public-data-refresh'
PREFIX = 'entrance-estimate:destinations-pebble:1450-e-pebble-rd:unit-'
NEW_IDS = {PREFIX + unit for unit in ('2047', '2096', '3031')}
NEW_FEATURES_SHA256 = 'e561cbf2d8c8afd37ea957437152c02bfbb1857aeb21ea55089ea07f06f595cb'
NEW_METADATA_SHA256 = '2374b6cefe6b0076c7dd79ce42e14740da7409af9889649039560101dd325a85'
BASELINE_HASHES = {
    'catalogBody': 'bd79a23daad999334fd3db2e5375d247fa6ce3d3a7954c82f060ac19e40da44b',
    'sources': '6a06a9d0a9081e1af140341c4a35b13cbafc2f8adb8af4db92238119a68f6f20',
    'communities': 'ea51ba622170eb07b7276b55f406e3b97539a28af1f32b84d7f90d07430c3818',
    'associations': '4b7551ff7d577284a350855569a238718615a1cdeed50275cca1561e9aa4c600',
    'floorReferences': '51c1b883ba1bb6270b0a56ec273717e8baf53a609e3fdac2d31295376d2a55d0',
    'locations': 'f545bceb5604b1201e2db8a6a0e057e8a4b9d0ec2a47e7049639d62e3545c7d3',
    'paths': '5f601eba93b5bd25d7a624e40d3e5231c0ecea98dd3faa42b2d7ef73af8280ff',
    'addressIndex': 'cbd6de3d52dea4312711e953c1317d457499341442707688ff2c33122abcadab',
}
OLD_PROOF_SHA256 = '1c5d362d342889b93e8e3f9814591ffc49f6072abc2d199963042910c5696f6f'


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                    ensure_ascii=False).encode()).hexdigest()


def read(name):
    return historical_resources()[name]


class PublicDataRefreshIncrementTests(unittest.TestCase):
    def test_three_side_hypotheses_keep_literal_identity_and_unverified_entry_metadata(self):
        catalog, locations = read('public-catalog.json'), read('public-locations.geojson')
        added = [f for f in locations['features'] if f['id'] in NEW_IDS]
        self.assertEqual({f['id'] for f in added}, NEW_IDS)
        self.assertEqual(len(added), 3)
        self.assertEqual(fingerprint(added), NEW_FEATURES_SHA256)
        metadata = {f['id']: f['properties']['entranceSideEstimate'] for f in added}
        self.assertEqual(fingerprint(metadata), NEW_METADATA_SHA256)
        expected = {
            '2047': ('3', '2', '1864911', '2046', [-115.13329588, 36.03011498]),
            '2096': ('7', '2', '1864960', '2097', [-115.13322462, 36.02960726]),
            '3031': ('2', '3', '1865055', '3030', [-115.13242291, 36.02922668]),
        }
        source_ids = {s['id'] for s in catalog['sources']}
        for feature in added:
            p = feature['properties']
            e = p['entranceSideEstimate']
            building, floor, source_unit, neighbor, coordinates = expected[p['unit']]
            self.assertEqual((p['communityID'], p['address'], p['building'], p['floor']),
                             ('destinations-pebble', '1450 E PEBBLE RD', building, floor))
            self.assertEqual(feature['geometry'], {'type': 'Point', 'coordinates': coordinates})
            self.assertEqual((p['kind'], p['verification'], p['identityUncertain']),
                             ('unitPosition', 'estimated', True))
            self.assertEqual((e['sourceUnitID'], e['dwellingFloorEvidence'], e['dwellingFloor']),
                             (source_unit, 'currentExplicit', floor))
            self.assertEqual(e['sharedUnits'], [])
            self.assertEqual(len(e['frontage']), 2)
            self.assertGreaterEqual(e['workingAllowanceMeters'], 20)
            for flag in ('uncertaintyCalibrated', 'doorCoordinatesVerified',
                         'entranceCoordinatesVerified', 'physicalSignageVerified'):
                self.assertIs(e[flag], False)
            self.assertIn('Unknown entrance elevation', e['entryLevelDescription'])
            for qualifier in (neighbor, '64-72%', '64.89%', 'opposite-facade', 'may be exceeded'):
                self.assertIn(qualifier, e['evidenceNotes'])
            self.assertTrue(set(p['sourceIDs']) <= source_ids)
            joins = [a for a in catalog['unitBuildingAssociations']
                     if a['communityID'] == p['communityID'] and a['address'] == p['address']
                     and a['unit'] == p['unit']]
            self.assertEqual(len(joins), 1)
            self.assertEqual((joins[0]['building'], joins[0]['sourceUnitID']), (building, source_unit))

    def test_every_26_1_fact_is_preserved_after_removing_only_the_three_declared_ids(self):
        c, l, p, i = [read(n) for n in ('public-catalog.json', 'public-locations.geojson',
                                      'public-paths.geojson', 'known-addresses.json')]
        self.assertTrue(all(v['packVersion'] == VERSION for v in (c, l, p, i)))
        old_locations = [f for f in l['features'] if f['id'] not in NEW_IDS]
        self.assertEqual(len(old_locations), 16061)
        actual = {
            'catalogBody': {k: v for k, v in c.items() if k not in ('packVersion', 'generatedAt')},
            'sources': c['sources'], 'communities': c['communities'],
            'associations': c['unitBuildingAssociations'], 'floorReferences': c['unitFloorReferences'],
            'locations': old_locations, 'paths': p['features'], 'addressIndex': i['entries'],
        }
        self.assertEqual({k: fingerprint(v) for k, v in actual.items()}, BASELINE_HASHES)
        self.assertEqual(len(l['features']), 16064)
        self.assertEqual((len(c['sources']), len(c['communities']), len(c['unitBuildingAssociations']),
                          len(c['unitFloorReferences']), len(p['features'])), (778, 162, 8015, 359, 17))

    def test_fact_only_proof_freezes_the_delta_without_rewriting_the_prior_proof(self):
        proof = json.loads((ROOT / 'docs/public-data-refresh-preservation.json').read_bytes())
        self.assertEqual(proof['schemaVersion'], 1)
        self.assertEqual(proof['packVersion'], VERSION)
        self.assertEqual(set(proof['newFeatureIDs']), NEW_IDS)
        self.assertEqual(proof['newSourceIDs'], [])
        self.assertEqual(proof['newFeaturesSHA256'], NEW_FEATURES_SHA256)
        self.assertEqual(proof['newEstimateMetadataSHA256'], NEW_METADATA_SHA256)
        self.assertEqual(proof['baselineCollectionHashes'], BASELINE_HASHES)
        self.assertEqual(proof['newVerifiedDoorCount'], 0)
        self.assertEqual(proof['newUnitBuildingAssociationCount'], 0)
        old_proof = ROOT / 'docs/estimated-entrance-side-preservation.json'
        self.assertEqual(hashlib.sha256(old_proof.read_bytes()).hexdigest(), OLD_PROOF_SHA256)

    def test_final_resources_pass_existing_public_admission(self):
        spec = importlib.util.spec_from_file_location('public_catalog_refresh_admission',
                                                     ROOT / 'scripts/public-catalog.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(module.validate(ROOT / 'data'),
                         {'communities': 186, 'positions': 23533, 'paths': 17, 'sources': 939})


if __name__ == '__main__':
    unittest.main()
