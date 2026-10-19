"""Public bundle export checks use invented fixtures only."""
import json
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class PublicCatalogExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source = self.directory / 'source'
        self.source.mkdir()
        self.output = self.directory / 'output'
        self.evidence = None
        self.additions = None
        self.catalog = dict(schemaVersion=1, packVersion='fixture-v1', generatedAt='2026-01-01T00:00:00Z',
            scopeZIPs=['89113','89148'], sources=[dict(id='official-fixture', title='Published fictional property',
            url='https://example.invalid/map', retrievedAt='2026-01-01T00:00:00Z')],
            communities=[dict(id='fictional', name='Fictional Apartments', address='100 Fictional Rd', zip='89113',
                aliases=[], sourceIDs=['official-fixture'], researchStatus='mapped', gapNotes=['PRIVATE FREE TEXT'],
                latitude=0.0, longitude=0.0, privateNotes='DO NOT COPY')],
            coverage=dict(inventoryComplete=False, notes=['PRIVATE COVERAGE TEXT']), resident='DO NOT COPY')
        self.locations = dict(type='FeatureCollection', schemaVersion=1, packVersion='fixture-v1', features=[
            dict(type='Feature', id='fictional-unit-001', geometry=dict(type='Point', coordinates=[0.0,0.0]),
                properties=dict(communityID='fictional', address='100 Fictional Rd', building='A', unit='001', floor='1',
                    kind='unitPosition', verification='sourceMapped', sourceIDs=['official-fixture'],
                    notes='PRIVATE PIN TEXT', gateCode='DO NOT COPY', identityUncertain=True))])
        self.paths = dict(type='FeatureCollection', schemaVersion=1, packVersion='fixture-v1', features=[])

    def run_export(self, valid=True):
        for name, payload in [('catalog.json', self.catalog), ('locations.geojson', self.locations), ('paths.geojson', self.paths)]:
            (self.source / name).write_text(json.dumps(payload))
        command = [sys.executable, '-B', str(ROOT / 'scripts/public-catalog.py'), 'prepare',
            '--source', str(self.source), '--output', str(self.output), '--version', '2026.10.19.1-public']
        if self.additions is not None:
            path = self.directory / 'additions.json'; path.write_text(json.dumps(self.additions))
            command += ['--additions', str(path)]
        if self.evidence is not None:
            path = self.directory / 'evidence.json'; path.write_text(json.dumps(self.evidence))
            command += ['--evidence', str(path)]
        result = subprocess.run(command, text=True, capture_output=True)
        if valid:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Public catalog:", result.stderr)
        return result

    def test_export_keeps_source_identity_and_precision_without_copying_private_text(self):
        self.run_export()
        catalog = json.loads((self.output / 'public-catalog.json').read_text())
        places = json.loads((self.output / 'public-locations.geojson').read_text())
        self.assertEqual(catalog['packVersion'], '2026.10.19.1-public')
        self.assertEqual(catalog['communities'][0]['address'], '100 Fictional Rd')
        feature = places['features'][0]
        self.assertEqual(feature['geometry']['coordinates'], [0.0,0.0])
        self.assertEqual(feature['properties']['unit'], '001')
        self.assertTrue(feature['properties']['identityUncertain'])
        self.assertIn('not an entrance or exact door', feature['properties']['notes'])
        public = ''.join(p.read_text() for p in self.output.iterdir())
        for text in ('PRIVATE FREE TEXT','PRIVATE COVERAGE TEXT','PRIVATE PIN TEXT','DO NOT COPY','gateCode','resident','privateNotes'):
            self.assertNotIn(text, public)
        self.assertFalse(catalog['coverage']['inventoryComplete'])

    def test_unperformed_field_verification_is_rejected(self):
        self.locations['features'][0]['properties']['verification'] = 'fieldVerified'
        self.run_export(valid=False)
        self.assertFalse(self.output.exists())

    def test_published_estimates_remain_estimated_and_qualified(self):
        self.locations['features'][0]['properties']['verification'] = 'estimated'
        self.run_export()
        p = json.loads((self.output / 'public-locations.geojson').read_text())['features'][0]['properties']
        self.assertEqual(p['verification'], 'estimated')
        self.assertIn('May be inaccurate', p['notes'])

    def test_exact_doors_and_confirmed_personal_paths_are_rejected(self):
        self.locations['features'][0]['properties']['kind'] = 'door'
        self.run_export(valid=False)
        self.locations['features'][0]['properties']['kind'] = 'unitPosition'
        self.paths['features'] = [dict(type='Feature', id='private-path', geometry=dict(type='LineString', coordinates=[[0,0],[0,0.001]]),
            properties=dict(communityID='fictional', fromNode='a', toNode='b', mode='walk', oneWay=False,
                blocked=False, stairs=False, confirmed=True, sourceIDs=['official-fixture'], notes='PRIVATE PATH'))]
        self.run_export(valid=False)

    def test_credentials_and_dangling_sources_are_rejected(self):
        self.catalog['sources'][0]['url'] = 'https://example.invalid/map?api_key=SECRET'
        self.run_export(valid=False)
        self.catalog['sources'][0]['url'] = 'https://example.invalid/map'
        self.locations['features'][0]['properties']['sourceIDs'] = ['missing']
        self.run_export(valid=False)

    def test_validator_rejects_mutated_resource_digest_and_extra_fields(self):
        self.run_export()
        path = self.output / 'public-locations.geojson'
        value = json.loads(path.read_text())
        value['features'][0]['properties']['accessCode'] = 'PRIVATE'
        path.write_text(json.dumps(value))
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/public-catalog.py'), 'validate',
            '--directory', str(self.output)], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_known_address_index_is_public_and_keeps_zero_unit_data_out(self):
        self.run_export()
        index = json.loads((self.output / 'known-addresses.json').read_text())
        self.assertEqual(index['entries'], [dict(address='100 Fictional Rd', deliveryAddresses=[])])
        self.assertNotIn('001', json.dumps(index))

    def test_synthetic_no_bundle_switch_is_explicit_and_isolated(self):
        support = (ROOT / 'App/UITestSupport.swift').read_text()
        self.assertIn('static var loadPublicCatalog: Bool', support)
        gate = support.split('static var loadPublicCatalog: Bool',1)[1].split('static func preferences()',1)[0]
        for value in ('targetEnvironment(simulator)', 'enabled', 'storeURL() != nil', '--without-public-catalog'):
            self.assertIn(value, gate)
        self.assertIn('loadPublicCatalog: UITestSupport.loadPublicCatalog', (ROOT / 'App/ApartmentFinderApp.swift').read_text())
        ui = (ROOT / 'UITests/OnTracFlowTests.swift').read_text()
        self.assertIn('app.launchArguments.append("--without-public-catalog")', ui)
        self.assertIn('XCTAssertTrue(packImport.isHittable)', ui)

    def test_riley_split_rejects_unreviewed_source_shape_instead_of_inventing_pins(self):
        self.catalog['packVersion'] = self.locations['packVersion'] = self.paths['packVersion'] = '2026.10.14.1'
        self.catalog['communities'][0].update(id='alcove', address='6355 S Riley St')
        self.locations['features'][0]['properties'].update(communityID='alcove', address='6355 S Riley St')
        self.run_export(valid=False)
        self.assertFalse(self.output.exists())

    def test_extra_delivery_exception_metadata_is_rejected(self):
        self.catalog['deliveryAreaExceptions'] = [dict(communityID='fictional', postalZIP='89118', privateNotes='PRIVATE EXCEPTION TEXT')]
        self.run_export(valid=False)
        self.assertFalse(self.output.exists())

    def test_unreviewed_graph_links_are_never_exported(self):
        self.locations['features'][0]['properties'].update(approachID='PRIVATE APPROACH', graphNodeID='PRIVATE GRAPH')
        self.run_export()
        public = (self.output / 'public-locations.geojson').read_text()
        self.assertNotIn('PRIVATE', public)
        self.assertNotIn('approachID', public)
        self.assertNotIn('graphNodeID', public)

    def test_source_version_metadata_cannot_carry_arbitrary_objects(self):
        private = {'privateNotes': 'SYNTHETIC-VERSION-LEAK'}
        self.catalog['packVersion'] = self.locations['packVersion'] = self.paths['packVersion'] = private
        self.run_export(valid=False)
        self.assertFalse(self.output.exists())

    def test_non_boolean_identity_uncertainty_is_rejected(self):
        self.locations['features'][0]['properties']['identityUncertain'] = 1
        self.run_export(valid=False)

    def test_review_manifest_rejects_unknown_fields(self):
        self.run_export()
        path = self.output / 'public-catalog-review.json'
        value = json.loads(path.read_text()); value['privateNotes'] = 'SYNTHETIC MANIFEST LEAK'
        path.write_text(json.dumps(value))
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/public-catalog.py'), 'validate',
            '--directory', str(self.output)], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_generated_timestamp_must_be_a_real_scalar_timestamp(self):
        self.run_export()
        path = self.output / 'public-catalog.json'
        value = json.loads(path.read_text()); value['generatedAt'] = {'privateNotes': 'SYNTHETIC DATE LEAK'}
        path.write_text(json.dumps(value))
        manifest = self.output / 'public-catalog-review.json'; review = json.loads(manifest.read_text())
        review['resourcesSHA256']['public-catalog.json'] = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(review))
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/public-catalog.py'), 'validate',
            '--directory', str(self.output)], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_field_level_coordinate_confidence_and_outside_area_qualification_are_preserved(self):
        self.evidence = [dict(communityID='fictional', communityType='apartment', areaScope='nearbyOutsideFocus',
            addressSourceIDs=['official-fixture'], coordinate=dict(kind='operatorPublishedPropertyPoint', sourceIDs=['official-fixture']))]
        self.run_export()
        community = json.loads((self.output / 'public-catalog.json').read_text())['communities'][0]
        self.assertIn('publicEvidence', community)
        self.assertEqual(community['publicEvidence']['coordinate']['kind'], 'operatorPublishedPropertyPoint')
        self.assertTrue(any('operator publishes' in note for note in community['gapNotes']))
        self.assertTrue(any('outside the focused' in note for note in community['gapNotes']))

    def test_unknown_field_evidence_metadata_is_rejected(self):
        self.evidence = [dict(communityID='fictional', communityType='apartment', areaScope='core',
            addressSourceIDs=['official-fixture'], coordinate=dict(kind='operatorPublishedPropertyPoint',
                sourceIDs=['official-fixture'], privateNotes='SYNTHETIC LEAK'))]
        self.run_export(valid=False)
        self.assertFalse(self.output.exists())

    def test_reviewed_public_property_enrichment_keeps_identity_and_drops_free_text(self):
        self.additions = dict(sources=[], communities=[], communityEnrichments=[dict(id='fictional',
            deliveryAddresses=['100 Fictional Rd','110 Fictional Rd'], aliasesToAdd=['Fictional Public Condominiums'],
            latitude=0.001, longitude=0.002, sourceIDsToAdd=['official-fixture'],
            coordinateMethod='PRIVATE FREE TEXT', coordinateScope='PRIVATE FREE TEXT')])
        self.run_export()
        community = json.loads((self.output / 'public-catalog.json').read_text())['communities'][0]
        self.assertEqual(community['id'], 'fictional')
        self.assertEqual(community['address'], '100 Fictional Rd')
        self.assertIn('deliveryAddresses', community)
        self.assertEqual(community['deliveryAddresses'], ['100 Fictional Rd','110 Fictional Rd'])
        self.assertEqual(community['latitude'], 0.001)
        self.assertEqual(community['longitude'], 0.002)
        self.assertNotIn('PRIVATE', json.dumps(community))

    def test_unknown_property_enrichment_fields_are_rejected(self):
        self.additions = dict(sources=[], communities=[], communityEnrichments=[dict(id='fictional', resident='SYNTHETIC LEAK')])
        self.run_export(valid=False)

    def test_source_versions_must_match_before_export(self):
        self.paths['packVersion'] = 'other-v2'
        self.run_export(valid=False)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
