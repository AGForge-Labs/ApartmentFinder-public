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
        self.assertEqual(row['unitPositions'], dict(total=2, estimated=1, sourceMapped=1))

    def test_checked_in_inventory_is_deterministic_and_covers_every_catalog_record(self):
        catalog = json.loads((ROOT / 'data/public-catalog.json').read_bytes())
        features = json.loads((ROOT / 'data/public-locations.geojson').read_bytes())['features']
        result = AUDIT.build_audit(catalog, features)
        self.assertEqual(result, AUDIT.build_audit(catalog, list(reversed(features))))
        self.assertEqual(result, json.loads((ROOT / 'docs/public-community-geography-audit.json').read_bytes()))
        self.assertEqual({r['communityID'] for r in result['communities']}, {c['id'] for c in catalog['communities']})
        self.assertEqual(len(result['communities']), len(catalog['communities']))
        self.assertEqual(result['allCatalog']['unitBuildingAssociations'], len(catalog['unitBuildingAssociations']))


if __name__ == '__main__':
    unittest.main()
