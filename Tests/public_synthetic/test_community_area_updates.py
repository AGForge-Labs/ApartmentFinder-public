"""Public community centers are useful anchors, never evidence for unit doors."""
import json
from pathlib import Path
import unittest

from reviewed_bundle_history import historical_resources

ROOT = Path(__file__).resolve().parents[2]


class CommunityAreaUpdateTests(unittest.TestCase):
    def test_reported_silverado_properties_have_distinct_official_community_centers(self):
        catalog = json.loads((ROOT / 'data/public-catalog.json').read_bytes())
        communities = {c['id']: c for c in catalog['communities']}
        sources = {s['id']: s for s in catalog['sources']}
        for cid, street, latitude, longitude, url in (
            ('lyric', '304 East Silverado Ranch Boulevard', 36.01408, -115.159018,
             'https://www.lyriclv.com/mapsanddirections'),
            ('trend', '240 East Silverado Ranch Boulevard', 36.01422151644452, -115.16156023077903,
             'https://trendlv.com/'),
        ):
            with self.subTest(community=cid):
                c = communities[cid]
                self.assertEqual((c['address'], c['zip']), (street, '89183'))
                self.assertEqual((c.get('latitude'), c.get('longitude')), (latitude, longitude))
                proof = c.get('publicEvidence', {}).get('coordinate', {})
                self.assertEqual(proof.get('kind'), 'operatorPublishedPropertyPoint')
                self.assertIn(url, [sources[s]['url'] for s in proof.get('sourceIDs', [])])
                self.assertIn('not a unit, entrance or delivery destination', ' '.join(c['gapNotes']))
        self.assertNotEqual(communities['lyric'].get('longitude'), communities['trend'].get('longitude'))

    def test_silverado_estimates_have_separate_unit_evidence_and_never_reuse_community_centers_as_doors(self):
        # These exact six original entrance estimates retain their full qualifiers.
        historical = historical_resources()
        catalog = historical['public-catalog.json']
        communities = {c['id']: c for c in catalog['communities']}
        sources = {s['id']: s for s in catalog['sources']}
        features = historical['public-locations.geojson']['features']
        expected = {
            'lyric': ('304 E SILVERADO RANCH BLVD', {'1014': ('2', '', None)}),
            'trend': ('240 E SILVERADO RANCH BLVD', {
                '1016': ('5', '2', '10564261'), '1046': ('6', '2', '10564284'),
                '1056': ('7', '2', '10564301'), '1060': ('7', '2', '10564303'), '1082': ('8', '2', '10564322')}),
        }
        for cid, (street, identities) in expected.items():
            with self.subTest(community=cid):
                community = communities[cid]
                local = [f for f in features if f['properties']['communityID'] == cid]
                self.assertEqual(len(local), len(identities))
                self.assertEqual({f['properties']['unit'] for f in local}, set(identities))
                center_sources = set(community['publicEvidence']['coordinate']['sourceIDs'])
                for feature in local:
                    p = feature['properties']
                    estimate = p['entranceSideEstimate']
                    self.assertEqual((p['address'], p['building'], p['floor']),
                        (street, identities[p['unit']][0], identities[p['unit']][1]))
                    self.assertEqual((p['kind'], p['verification']), ('unitPosition', 'estimated'))
                    self.assertIs(p['identityUncertain'], True)
                    self.assertFalse(set(p) & {'referenceKind', 'sourceUnitID'})
                    for flag in ('uncertaintyCalibrated', 'doorCoordinatesVerified', 'entranceCoordinatesVerified', 'physicalSignageVerified'):
                        self.assertIs(estimate[flag], False)
                    self.assertEqual(estimate.get('sourceUnitID'), identities[p['unit']][2])
                    self.assertEqual(feature['geometry']['type'], 'Point')
                    self.assertNotEqual(feature['geometry']['coordinates'], [community['longitude'], community['latitude']])
                    self.assertTrue(p['sourceIDs'])
                    self.assertTrue(center_sources.isdisjoint(p['sourceIDs']), 'Community-center provenance cannot supply unit entrance geometry')
                    urls = {sources[source]['url'] for source in p['sourceIDs']}
                    self.assertIn('not a verified entrance or exact door', p['notes'])
                    self.assertIn('uncalibrated', p['notes'])
                    self.assertIn(estimate['evidenceNotes'], p['notes'])
                    if cid == 'lyric':
                        self.assertEqual(estimate['sharedUnits'], ['1013', '1014'])
                        self.assertEqual(estimate['frontage'], [])
                        self.assertEqual(estimate['dwellingFloorEvidence'], 'unknown')
                        self.assertIsNone(estimate.get('dwellingFloor'))
                        self.assertEqual(estimate['workingAllowanceMeters'], 10)
                        self.assertIn('https://resource.rentcafe.com/image/upload/f_auto,q_auto/s3/2/55533/p1941965-lyric_sitemap_resized.png', urls)
                    else:
                        self.assertEqual(estimate['dwellingFloorEvidence'], 'currentExplicit')
                        self.assertEqual(estimate['dwellingFloor'], '2')
                        self.assertEqual(estimate['workingAllowanceMeters'], 20)
                        self.assertEqual(estimate['sharedUnits'], [])
                        self.assertEqual(len(estimate['frontage']), 2)
                        self.assertIn('ENTRY FROM BELOW', estimate['evidenceNotes'])
                        self.assertIn('https://sightmap.com/app/api/v1/5evekqr1vqo/sightmaps/93749', urls)

    def test_lyric_operator_labels_are_retained_without_floor_or_door_inference(self):
        catalog = json.loads((ROOT / 'data/public-catalog.json').read_bytes())
        rows = [a for a in catalog['unitBuildingAssociations'] if a['communityID'] == 'lyric']
        self.assertEqual(len(rows), 376)
        for unit, building in [('1193', '15'), ('2171', '13')]:
            matches = [a for a in rows if a['unit'] == unit]
            self.assertEqual(len(matches), 1)
            row = matches[0]
            self.assertEqual((row['address'], row['building'], row['identifierKind']),
                             ('304 E SILVERADO RANCH BLVD', building, 'operatorMap'))
            self.assertFalse(set(row) & {'referencePlaceID', 'mapFloor', 'latitude', 'longitude'})


if __name__ == '__main__':
    unittest.main()
