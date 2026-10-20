"""Review the bundled public facts without claiming native/UI execution."""
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class PublicCatalogResourceTests(unittest.TestCase):
    def test_incremental_batch_preserves_all_prior_unit_positions_and_qualified_references(self):
        catalog = json.loads((ROOT / 'data/public-catalog.json').read_bytes())
        points = json.loads((ROOT / 'data/public-locations.geojson').read_bytes())['features']
        units = sorted((p for p in points if p['properties']['kind'] == 'unitPosition'), key=lambda f:f['id'])
        digest = hashlib.sha256(json.dumps(units,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()).hexdigest()
        self.assertEqual(digest, '5d7a593a41cf89aa58e6fae222b9afb6ab14446e5b1d25ff49a260d19ffb1a4f')
        self.assertEqual(len(units), 14517)
        references = [p for p in points if p['properties'].get('referenceKind')]
        self.assertEqual(len(references), 230)
        for f in references:
            p = f['properties']
            self.assertEqual((p['kind'],p['unit'],p['floor'],p['verification']),('building','','','sourceMapped'))
            for qualifier in ('courtyard','physical signs','accuracy is unknown','not a unit position'):
                self.assertIn(qualifier,p['notes'])
        self.assertEqual(len(catalog['communities']),143)
        self.assertEqual(len(catalog['unitBuildingAssociations']),4237)
        self.assertEqual(sum(a['identifierKind']=='municipalLegal' for a in catalog['unitBuildingAssociations']),3668)
        self.assertEqual(sum(a['identifierKind']=='operatorMap' for a in catalog['unitBuildingAssociations']),569)
        self.assertFalse(catalog['coverage']['inventoryComplete'])
        self.assertFalse(any(a['communityID']=='montana' and a['unit']=='1068' for a in catalog['unitBuildingAssociations']))
        self.assertFalse(any(c['id'] in ('bay-breeze-apartments','arabella') for c in catalog['communities']))
        self.assertFalse(any(c['id']=='rancho-serene' and '2014'==a['unit'] and a['communityID']==c['id']
                             for c in catalog['communities'] for a in catalog['unitBuildingAssociations']))
        self.assertEqual({z:sum(c['zip']==z for c in catalog['communities']) for z in ('89123','89183','89052','89014','89044')},
                         {'89123':20,'89183':18,'89052':16,'89014':20,'89044':4})

    def test_public_resources_fit_unchanged_native_payload_limits(self):
        limits = {'public-catalog.json':2_000_000,'public-locations.geojson':64_000_000,
                  'public-paths.geojson':16_000_000,'known-addresses.json':2_000_000}
        for name,maximum in limits.items():
            with self.subTest(resource=name):
                self.assertLessEqual((ROOT/'data'/name).stat().st_size,maximum)
