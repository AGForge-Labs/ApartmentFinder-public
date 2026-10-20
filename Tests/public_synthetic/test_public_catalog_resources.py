"""Review the bundled public facts without claiming native/UI execution."""
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
ADDED_COMMUNITIES = {'ensemble-ii', 'budget-suites-las-vegas-strip', 'one-las-vegas',
                     'st-james-place', 'southpark', 'paragon-lofts'}
ADDED_SOURCES = {'p4-e1', 'p4-e2', 'p4-b1', 'p4-b2', 'p4-o1', 'p4-s1', 'p4-s2',
                 'p4-k1', 'p4-k2', 'p4-p1', 'p4-p2', 'p4-sj', 'p4-dp'}


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                    ensure_ascii=False).encode()).hexdigest()


def resources():
    return [json.loads((ROOT / 'data' / name).read_bytes()) for name in
            ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson')]

class PublicCatalogResourceTests(unittest.TestCase):
    def test_incremental_batch_preserves_all_prior_unit_positions_and_qualified_references(self):
        catalog = json.loads((ROOT / 'data/public-catalog.json').read_bytes())
        points = json.loads((ROOT / 'data/public-locations.geojson').read_bytes())['features']
        units = sorted((p for p in points if p['properties']['kind'] == 'unitPosition'), key=lambda f:f['id'])
        digest = hashlib.sha256(json.dumps(units,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(digest, '5d7a593a41cf89aa58e6fae222b9afb6ab14446e5b1d25ff49a260d19ffb1a4f')
        self.assertEqual(len(units), 14517)
        references = [p for p in points if p['properties'].get('referenceKind')]
        self.assertEqual(len(references), 255)
        for f in references:
            p = f['properties']
            self.assertEqual((p['kind'],p['unit'],p['floor'],p['verification']),('building','','','sourceMapped'))
            for qualifier in ('courtyard','physical signs','accuracy is unknown','not a unit position'):
                self.assertIn(qualifier,p['notes'])
        self.assertEqual(len(catalog['communities']),162)
        self.assertEqual(len(catalog['unitBuildingAssociations']),6373)
        self.assertEqual(sum(a['identifierKind']=='municipalLegal' for a in catalog['unitBuildingAssociations']),4223)
        self.assertEqual(sum(a['identifierKind']=='operatorMap' for a in catalog['unitBuildingAssociations']),2150)
        self.assertFalse(catalog['coverage']['inventoryComplete'])
        # The published crosswalk sante->sante is wrong for the retained catalog.
        community_ids = {c['id'] for c in catalog['communities']}
        self.assertIn('sant', community_ids); self.assertNotIn('sante', community_ids)
        self.assertEqual(sum(a['communityID']=='sant' for a in catalog['unitBuildingAssociations']),238)
        self.assertFalse(any(a['communityID']=='sante' for a in catalog['unitBuildingAssociations']))
        self.assertFalse(any(a['communityID']=='sant' and a['building']=='1' for a in catalog['unitBuildingAssociations']))
        # MODEL is a distinct source use, not an ordinary residential unit.
        self.assertFalse(any(a['communityID']=='trend' and a['unit']=='1034' for a in catalog['unitBuildingAssociations']))
        self.assertEqual(sum(a['communityID']=='trend' for a in catalog['unitBuildingAssociations']),361)
        self.assertEqual(sum(a['communityID']=='dune' for a in catalog['unitBuildingAssociations']),398)
        self.assertFalse(any(a['communityID']=='montana' and a['unit']=='1068' for a in catalog['unitBuildingAssociations']))
        self.assertFalse(any(c['id'] in ('bay-breeze-apartments','arabella') for c in catalog['communities']))
        self.assertFalse(any(c['id']=='rancho-serene' and '2014'==a['unit'] and a['communityID']==c['id']
                             for c in catalog['communities'] for a in catalog['unitBuildingAssociations']))
        self.assertEqual({z:sum(c['zip']==z for c in catalog['communities']) for z in ('89123','89183','89052','89014','89044')},
                         {'89123':31,'89183':20,'89052':20,'89014':22,'89044':4})

    def test_89123_batch_preserves_every_previously_accepted_object(self):
        catalog, locations, paths = resources()
        old = {
            'communities': [c for c in catalog['communities'] if c['id'] not in ADDED_COMMUNITIES],
            'sources': [s for s in catalog['sources'] if s['id'] not in ADDED_SOURCES],
            'associations': [a for a in catalog['unitBuildingAssociations'] if not a['id'].startswith('p4a-')],
            'locations': [f for f in locations['features'] if f['properties']['communityID'] != 'st-james-place'],
            'paths': paths['features'],
        }
        # Independently frozen from public main 862853e before this data addition.
        expected = {
            'communities': (156, '7d2b9061f68537331eb7c2cf6054c9922763ad71b22493ace3439895d680055f'),
            'sources': (671, 'ce9f882a3bff3ea768218ed5981ae9f67e7284db0e1e5a9bcb37f5e07bf68f0b'),
            'associations': (6148, 'ef888740c552778f375b574c01ae08bc31373412761c09e3448b49df166b0296'),
            'locations': (14749, '1272fcd8fe52a70100071b98be03502c1a5c40ae9218ea898d29ec3263f20feb'),
            'paths': (17, '67affb5e94806f7853896517b3f9185433e9d52b96ca7a8a5042811aea923a98'),
        }
        for name, (count, digest) in expected.items():
            with self.subTest(collection=name):
                self.assertEqual(len(old[name]), count)
                self.assertEqual(fingerprint(sorted(old[name], key=lambda x:x['id'])), digest)

    def test_six_property_identities_have_exact_address_scope_and_no_new_coordinates(self):
        catalog, _, _ = resources()
        communities = {c['id']: c for c in catalog['communities']}
        streets = {'ensemble-ii':'2775 W Agate Avenue',
                   'budget-suites-las-vegas-strip':'8440 S Las Vegas Boulevard',
                   'one-las-vegas':'8255 S Las Vegas Boulevard',
                   'st-james-place':'2615 W Gary Avenue', 'southpark':'7450 S Eastern Avenue',
                   'paragon-lofts':'2860 Blue Key Court'}
        for cid, address in streets.items():
            with self.subTest(community=cid):
                c = communities[cid]
                self.assertEqual(c['address'], address)
                self.assertEqual(c['zip'], '89123')
                self.assertNotIn('latitude', c); self.assertNotIn('longitude', c)
                self.assertNotIn('coordinate', c['publicEvidence'])
                self.assertTrue(set(c['sourceIDs']) <= ADDED_SOURCES)
        self.assertEqual(communities['ensemble-ii']['publicEvidence']['communityType'], 'seniorLiving')
        self.assertNotEqual(communities['ensemble-ii']['address'], communities['ensemble']['address'])
        self.assertIn('extended-stay', communities['budget-suites-las-vegas-strip']['name'])
        self.assertEqual(communities['st-james-place']['name'], 'Southgate Condominiums')
        self.assertIn('St James Place', communities['st-james-place']['aliases'])
        self.assertNotIn('southgate-condominiums', communities)
        self.assertEqual(communities['one-las-vegas']['deliveryAddresses'], [])

    def test_recovered_associations_match_exact_reviewed_street_unit_and_building_facts(self):
        catalog, _, _ = resources()
        added = [a for a in catalog['unitBuildingAssociations'] if a['id'].startswith('p4a-')]
        self.assertEqual(len(added), 225)
        facts = sorted([[a['communityID'], a['address'], a['unit'], a['building'], a['identifierKind']]
                        for a in added])
        self.assertEqual(fingerprint(facts), '34a6d20ddab1328a97a2da5bda51081dd887d92cb51263b9c63ff1352b101a1a')
        legal = [a for a in added if a['communityID'] == 'st-james-place']
        operator = [a for a in added if a['communityID'] == 'destinations-pebble']
        self.assertEqual((len(legal), len(operator)), (179, 46))
        for a in legal:
            self.assertEqual((a['address'], a['identifierKind'], a['sourceIDs']),
                             ('2615 W GARY AVE', 'municipalLegal', ['p4-sj']))
            self.assertTrue(a['referencePlaceID'].startswith('st-james-place:legal:'))
        for a in operator:
            self.assertEqual((a['address'], a['identifierKind'], a['sourceIDs']),
                             ('1450 E PEBBLE RD', 'operatorMap', ['p4-dp']))
            self.assertNotIn('referencePlaceID', a)
        self.assertEqual(len({a['id'] for a in added}), 225)
        for a in added:
            self.assertNotIn('mapFloor', a)
            self.assertFalse(set(a) & {'latitude', 'longitude', 'doorCoordinates', 'unitCoordinates'})

    def test_new_legal_references_preserve_reviewed_points_and_explicit_approximation(self):
        catalog, locations, _ = resources()
        references = [f for f in locations['features'] if f['properties']['communityID'] == 'st-james-place']
        self.assertEqual(len(references), 23)
        facts = sorted([[f['id'], f['geometry']['coordinates'], f['properties']['address'],
                         f['properties']['building']] for f in references])
        self.assertEqual(fingerprint(facts), 'e19ed3016c9b4423c556893522735276674326b1ed6f31ed914274f08206eb39')
        by_id = {f['id']: f['properties'] for f in references}
        for p in by_id.values():
            self.assertEqual((p['kind'], p['unit'], p['floor'], p['verification'], p['referenceKind']),
                ('building', '', '', 'sourceMapped', 'assessorLegalBuildingPolygon'))
            self.assertEqual(p['sourceIDs'], ['p4-sj'])
            self.assertIn('not a unit position, entrance or exact door', p['notes'])
        for a in catalog['unitBuildingAssociations']:
            if a['communityID'] == 'st-james-place':
                p = by_id[a['referencePlaceID']]
                self.assertEqual((p['address'], p['building']), (a['address'], a['building']))

    def test_phase_two_and_unverified_townhome_targets_remain_outside_active_catalog(self):
        catalog, locations, _ = resources()
        communities = {c['id']: c for c in catalog['communities']}
        phase_one = communities['paragon-lofts']
        self.assertEqual({phase_one['address'], *phase_one['deliveryAddresses']}, {
            '2860 Blue Key Court', '2861 Blue Key Court', '2870 Blue Key Court', '2871 Blue Key Court',
            '2868 Orange Key Court', '2869 Orange Key Court', '2878 Orange Key Court', '2879 Orange Key Court'})
        self.assertNotIn('Paragon Lofts Phase 2', phase_one['aliases'])
        self.assertIn('Phase 1', phase_one['name'])
        self.assertFalse(any(a['communityID'] in {'paragon-lofts', 'one-las-vegas'}
                             for a in catalog['unitBuildingAssociations']))
        self.assertFalse(any(f['properties']['communityID'] in ADDED_COMMUNITIES - {'st-james-place'}
                             for f in locations['features']))
        self.assertFalse(any(c['address'].startswith(('8629', '8285')) for c in communities.values()
                             if c['id'] in ADDED_COMMUNITIES))
        self.assertTrue({'belle-esprit-townhomes', 'stone-canyon-silverado', 'serenity-agate-townhomes',
                         'villa-trieste-agate-gilespie', 'square-at-wigwam-ranch',
                         'paradise-spa', 'raven-point'}.isdisjoint(communities))

    def test_public_resources_fit_unchanged_native_payload_limits(self):
        limits = {'public-catalog.json':2_000_000,'public-locations.geojson':64_000_000,
                  'public-paths.geojson':16_000_000,'known-addresses.json':2_000_000}
        for name,maximum in limits.items():
            with self.subTest(resource=name):
                self.assertLessEqual((ROOT/'data'/name).stat().st_size,maximum)
