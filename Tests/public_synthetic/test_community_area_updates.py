"""Public community centers are useful anchors, never evidence for unit doors."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CommunityAreaUpdateTests(unittest.TestCase):
    def test_reported_silverado_properties_have_distinct_official_community_centers(self):
        catalog = json.loads((ROOT / 'data/public-catalog.json').read_bytes())
        communities = {c['id']: c for c in catalog['communities']}
        sources = {s['id']: s for s in catalog['sources']}
        features = json.loads((ROOT / 'data/public-locations.geojson').read_bytes())['features']
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
                self.assertFalse([f for f in features if f['properties']['communityID'] == cid],
                                 'A community map center must not fabricate building or unit points')
        self.assertNotEqual(communities['lyric'].get('longitude'), communities['trend'].get('longitude'))

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
