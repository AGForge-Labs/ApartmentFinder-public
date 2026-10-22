import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('community_gap_audit', ROOT / 'scripts/public-community-gap-audit.py')
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


def community(cid, **fields):
    return dict(id=cid, name='Fictional ' + cid, address='100 Fictional Rd', zip='89123', **fields)


def feature(cid, kind, verification='sourceMapped', coordinate=None, **fields):
    return dict(geometry=dict(type='Point', coordinates=coordinate or [0, 0]),
                properties=dict(communityID=cid, kind=kind, verification=verification, **fields))


class CommunityGapAuditTests(unittest.TestCase):
    def test_associations_are_not_geographic_coverage_and_building_area_is_not_a_door(self):
        catalog = dict(packVersion='fictional', communities=[community('schematic'), community('area', longitude=1, latitude=2)],
            unitBuildingAssociations=[dict(communityID='schematic', identifierKind='operatorMap')])
        features = [feature('area', 'building', referenceKind='assessorLegalBuildingPolygon')]
        before = copy.deepcopy((catalog, features))
        result = AUDIT.build_audit(catalog, features)
        rows = {r['communityID']: r for r in result['communities']}
        self.assertTrue(rows['schematic']['gaps']['communityAreaMissing'])
        self.assertEqual(rows['schematic']['unitBuildingAssociations']['total'], 1)
        self.assertTrue(rows['schematic']['gaps']['buildingAreasMissing'])
        self.assertEqual(rows['area']['buildingAreaReferences']['qualifiedLegalPolygon'], 1)
        self.assertEqual(rows['area']['doors']['fieldVerified'], 0)
        self.assertEqual(result['priorityArea']['mappedCommunityAreas'], 1)
        self.assertEqual((catalog, features), before)

    def test_valid_geographic_doors_and_unit_confidence_are_separate_and_invalid_points_do_not_count(self):
        catalog = dict(packVersion='fictional', communities=[community('a', longitude=True, latitude=2)])
        result = AUDIT.build_audit(catalog, [feature('a', 'door', 'fieldVerified'),
            feature('a', 'door', 'sourceMapped'), feature('a', 'door', 'fieldVerified', [0, 91]),
            feature('a', 'unitPosition', 'estimated'), feature('a', 'unitPosition', 'sourceMapped')])
        row = result['communities'][0]
        self.assertFalse(row['communityArea']['mapped'])
        self.assertEqual(row['doors'], dict(geographicPoints=2, fieldVerified=1))
        self.assertEqual(row['unitPositions'], dict(total=2, estimated=1, sourceMapped=1, operatorSourceUnitReferences=0))

    def test_estimated_entrance_side_regions_are_an_explicit_subset_and_never_verified_doors(self):
        catalog = dict(packVersion='fictional', communities=[community('a'), community('b')])
        metadata = dict(frontage=[dict(latitude=0, longitude=0), dict(latitude=0.001, longitude=0)],
            workingAllowanceMeters=10, uncertaintyCalibrated=False, doorCoordinatesVerified=False,
            entranceCoordinatesVerified=False, physicalSignageVerified=False, dwellingFloorEvidence='unknown',
            entryLevelDescription='Entry elevation unknown', sharedUnits=[], evidenceNotes='Fictional source frontage only')
        features = [feature('a', 'unitPosition', 'estimated', entranceSideEstimate=metadata, identityUncertain=True),
            feature('a', 'unitPosition'), feature('a', 'door', 'fieldVerified'),
            feature('b', 'unitPosition', 'estimated')]
        before = copy.deepcopy((catalog, features))
        result = AUDIT.build_audit(catalog, features)
        rows = {row['communityID']: row for row in result['communities']}
        self.assertIn('estimatedEntranceSideRegions', rows['a'])
        self.assertEqual(rows['a']['estimatedEntranceSideRegions'], 1)
        self.assertEqual(rows['b']['estimatedEntranceSideRegions'], 0)
        self.assertEqual(result['allCatalog']['estimatedEntranceSideRegions'], 1)
        self.assertEqual(result['priorityArea']['estimatedEntranceSideRegions'], 1)
        self.assertEqual(result['allCatalog']['unitPositions'], 3)
        self.assertEqual(rows['a']['doors'], dict(geographicPoints=1, fieldVerified=1))
        self.assertEqual(rows['b']['doors'], dict(geographicPoints=0, fieldVerified=0))
        self.assertEqual(rows['a']['entrances'], 0)
        self.assertIn('subset of estimated unit positions', ' '.join(result['interpretation']))
        self.assertEqual((catalog, features), before)
        for mutation in (dict(kind='door'), dict(kind='entrance'), dict(verification='fieldVerified'),
                dict(identityUncertain=False)):
            with self.subTest(mutation=mutation):
                changed = copy.deepcopy(features)
                changed[0]['properties'].update(mutation)
                with self.assertRaises(ValueError):
                    AUDIT.build_audit(catalog, changed)
        for flag in ('uncertaintyCalibrated', 'doorCoordinatesVerified', 'entranceCoordinatesVerified', 'physicalSignageVerified'):
            for value in (True, 0):
                with self.subTest(flag=flag, value=value):
                    changed = copy.deepcopy(features)
                    changed[0]['properties']['entranceSideEstimate'][flag] = value
                    with self.assertRaises(ValueError):
                        AUDIT.build_audit(catalog, changed)

    def test_checked_in_inventory_is_deterministic_and_covers_every_catalog_record(self):
        catalog = json.loads((ROOT / 'data/public-catalog.json').read_bytes())
        features = json.loads((ROOT / 'data/public-locations.geojson').read_bytes())['features']
        result = AUDIT.build_audit(catalog, features)
        self.assertEqual(result, AUDIT.build_audit(catalog, list(reversed(features))))
        self.assertEqual(result, json.loads((ROOT / 'docs/public-community-geography-audit.json').read_bytes()))
        self.assertEqual({r['communityID'] for r in result['communities']}, {c['id'] for c in catalog['communities']})
        self.assertEqual(len(result['communities']), len(catalog['communities']))
        self.assertEqual(result['allCatalog']['unitBuildingAssociations'], len(catalog['unitBuildingAssociations']))
        self.assertEqual(result['allCatalog']['estimatedEntranceSideRegions'],
            sum(f['properties'].get('entranceSideEstimate') is not None for f in features))

    def test_final_gap_list_matches_exact_catalog_identities_and_geography(self):
        audit = json.loads((ROOT / 'docs/public-community-geography-audit.json').read_bytes())
        ledger = json.loads((ROOT / 'docs/89123-catalog-geography-gaps.json').read_bytes())
        rows = [row for row in audit['communities'] if row['postalZIP'] == '89123']
        missing = {row['communityID']: row for row in rows
                   if row['buildingAreaReferences']['total'] == 0 and row['unitPositions']['total'] == 0}
        self.assertEqual(len(rows), ledger['catalogCommunities'])
        self.assertEqual(len(missing), ledger['communitiesWithoutUnitOrBuildingGeography'])
        self.assertEqual(len(rows) - len(missing), ledger['communitiesWithSomeUnitOrBuildingGeography'])
        self.assertEqual({row['communityId'] for row in ledger['communities']}, set(missing))
        self.assertFalse(ledger['completeZIPCoverage'])
        self.assertEqual(ledger['verifiedDoorsAdded'], 0)
        for row in ledger['communities']:
            self.assertEqual(row['catalogAddress'], missing[row['communityId']]['address'])
            self.assertEqual(row['name'], missing[row['communityId']]['name'])
            self.assertTrue(row['sourceURLs'])
            self.assertTrue(all(url.startswith('https://') for url in row['sourceURLs']))


if __name__ == '__main__':
    unittest.main()
