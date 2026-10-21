"""Public export fixtures use invented coordinates and no private source text."""
import copy
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
        self.assertEqual(list(catalog['sources'][0]), ['retrievedAt', 'id', 'url', 'title'])
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

    def test_authorized_manifest_zips_export_without_inventing_extra_positions(self):
        # These fixed ZIPs describe the public catalog coverage.
        for public_scope_zip in ('89123', '89183', '89052', '89014', '89044'):
            with self.subTest(zip=public_scope_zip):
                self.output = self.directory / ('zip-' + public_scope_zip)
                self.catalog['scopeZIPs'] = [public_scope_zip]
                self.catalog['communities'][0]['zip'] = public_scope_zip
                self.run_export()
                self.run_validate()
                catalog = json.loads((self.output / 'public-catalog.json').read_bytes())
                positions = json.loads((self.output / 'public-locations.geojson').read_bytes())
                self.assertEqual(catalog['scopeZIPs'], [public_scope_zip])
                self.assertEqual(len(positions['features']), 1)
                self.assertEqual(positions['features'][0]['properties']['unit'], '001')
                self.assertEqual(positions['features'][0]['properties']['verification'], 'sourceMapped')
                self.assertFalse(catalog['coverage']['inventoryComplete'])

    def test_new_zip_support_still_rejects_undeclared_and_unsupported_scope(self):
        for index, (scope, public_scope_zip, county) in enumerate(((['89123'], '89123', ['89014']),
                                                         (['99999'], '99999', []))):
            with self.subTest(scope=scope, zip=public_scope_zip, county=county):
                self.output = self.directory / ('rejected-' + str(index))
                self.catalog['scopeZIPs'] = scope
                self.catalog['communities'][0].update(zip=public_scope_zip, countyZIPs=county)
                self.run_export(valid=False)
                self.assertFalse(self.output.exists())
        # Preparation deliberately declares ZIPs of allowed appended communities.
        self.output = self.directory / 'declared-then-mutated'
        self.catalog['scopeZIPs'] = ['89123']
        self.catalog['communities'][0].update(zip='89052', countyZIPs=[])
        self.run_export()
        path = self.output / 'public-catalog.json'
        catalog = json.loads(path.read_bytes())
        self.assertEqual(catalog['scopeZIPs'], ['89052', '89123'])
        catalog['scopeZIPs'] = ['89123']
        path.write_text(json.dumps(catalog))
        review_path = self.output / 'public-catalog-review.json'
        review = json.loads(review_path.read_bytes())
        review['resourcesSHA256'][path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        review_path.write_text(json.dumps(review))
        result = self.run_validate(valid=False)
        self.assertIn('Community outside public ZIP scope', result.stderr)

    def test_metadata_only_henderson_addition_preserves_mapped_baseline(self):
        self.run_export()
        baseline = {name: json.loads((self.output / name).read_bytes()) for name in
                    ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson')}
        self.output = self.directory / 'with-address-only-community'
        self.additions = dict(sources=[dict(id='new-official', title='Fictional official address',
            url='https://example.invalid/property', retrievedAt='2026-10-20T00:00:00Z')],
            communities=[dict(id='fictional-henderson', name='Fictional Henderson Apartments',
                address='200 Fictional Pkwy', deliveryAddresses=['210 Fictional Pkwy'], zip='89052',
                aliases=[], sourceIDs=['new-official'], researchStatus='addressOnly', gapNotes=[])])
        self.run_export(); self.run_validate()
        catalog = json.loads((self.output / 'public-catalog.json').read_bytes())
        self.assertIn('89052', catalog['scopeZIPs'])
        new = catalog['communities'][-1]
        self.assertNotIn('latitude', new); self.assertNotIn('longitude', new)
        self.assertEqual(catalog['communities'][0], baseline['public-catalog.json']['communities'][0])
        self.assertEqual(catalog['sources'][0], baseline['public-catalog.json']['sources'][0])
        for name in ('public-locations.geojson', 'public-paths.geojson'):
            self.assertEqual(json.loads((self.output / name).read_bytes()), baseline[name])
        entries = json.loads((self.output / 'known-addresses.json').read_bytes())['entries']
        self.assertIn(dict(address='200 Fictional Pkwy', deliveryAddresses=['210 Fictional Pkwy']), entries)
        self.assertFalse(catalog['coverage']['inventoryComplete'])

    def configure_building_reference(self):
        feature = self.locations['features'][0]
        feature['id'] = 'fictional-legal-building-A'
        feature['properties'].update(unit='', floor='', kind='building', building='A', verification='sourceMapped',
            referenceKind='assessorLegalBuildingPolygon', identityUncertain=False)
        self.catalog['unitBuildingAssociations'] = [dict(id='fictional-legal-001', communityID='fictional',
            address='100 Fictional Rd', unit='001', building='A', identifierKind='municipalLegal',
            sourceIDs=['official-fixture'], referencePlaceID=feature['id'])]
        return feature

    def test_operator_building_areas_retain_occurrence_precision_and_exact_unit_joins(self):
        feature = self.configure_building_reference()
        feature['properties'].update(referenceKind='operatorMapBuildingArea',
            estimatedHorizontalUncertaintyM=20, mapLabelOccurrenceID='fictional-left-lobe')
        self.catalog['unitBuildingAssociations'][0].update(identifierKind='operatorMap', mapFloor='Floor 2', sourceUnitID='synthetic-unit-2')
        self.run_export(); self.run_validate()
        point = json.loads((self.output / 'public-locations.geojson').read_bytes())['features'][0]
        self.assertEqual(point['properties']['estimatedHorizontalUncertaintyM'], 20)
        self.assertEqual(point['properties']['mapLabelOccurrenceID'], 'fictional-left-lobe')
        self.assertIn('working uncertainty', point['properties']['notes'])
        self.assertIn('not a unit position, entrance or exact door', point['properties']['notes'])
        association = json.loads((self.output / 'public-catalog.json').read_bytes())['unitBuildingAssociations'][0]
        self.assertEqual(association['sourceUnitID'], 'synthetic-unit-2')
        self.assertEqual(association['referencePlaceID'], feature['id'])

    def test_source_unit_identity_is_preserved_without_deduplicating_stacked_floors(self):
        original = self.locations['features'][0]
        original['properties']['sourceUnitID'] = 'synthetic-unit-first-floor'
        upper = copy.deepcopy(original); upper['id'] = 'fictional-unit-101'
        upper['properties'].update(unit='101', floor='2', sourceUnitID='synthetic-unit-second-floor')
        self.locations['features'].append(upper)
        self.run_export(); self.run_validate()
        points = json.loads((self.output / 'public-locations.geojson').read_bytes())['features']
        self.assertEqual([p['geometry']['coordinates'] for p in points], [[0, 0], [0, 0]])
        self.assertEqual([p['properties']['sourceUnitID'] for p in points],
            ['synthetic-unit-first-floor', 'synthetic-unit-second-floor'])

    def test_historical_alias_and_floor_only_evidence_stay_separate_from_physical_pins(self):
        self.configure_building_reference()
        self.catalog['unitBuildingAssociations'][0].update(historicalLegalAlias=True, historicalFloor='second')
        self.catalog['unitFloorReferences'] = [dict(id='fictional-floor-only', communityID='fictional',
            address='100 Fictional Rd', unit='002', floor='5', sourceIDs=['official-fixture'], sourceRevision='2019-01-11')]
        self.run_export(); self.run_validate()
        catalog = json.loads((self.output / 'public-catalog.json').read_bytes())
        self.assertTrue(catalog['unitBuildingAssociations'][0]['historicalLegalAlias'])
        self.assertEqual(catalog['unitBuildingAssociations'][0]['historicalFloor'], 'second')
        self.assertEqual(catalog['unitFloorReferences'], self.catalog['unitFloorReferences'])
        self.assertEqual(len(json.loads((self.output / 'public-locations.geojson').read_bytes())['features']), 1)

    def test_typed_building_references_keep_associations_separate_from_unit_positions(self):
        self.configure_building_reference()
        self.run_export(); self.run_validate()
        catalog = json.loads((self.output / 'public-catalog.json').read_bytes())
        points = json.loads((self.output / 'public-locations.geojson').read_bytes())['features']
        self.assertEqual(catalog.get('unitBuildingAssociations'), self.catalog['unitBuildingAssociations'])
        self.assertEqual(len(points), 1)
        p = points[0]['properties']
        self.assertEqual(p.get('referenceKind'), 'assessorLegalBuildingPolygon')
        self.assertEqual((p['kind'], p['unit'], p['floor']), ('building', '', ''))
        self.assertIn('legal-building reference', p['notes'])
        self.assertIn('physical signs', p['notes'])
        self.assertIn('not a unit position', p['notes'])

    def test_no_point_operator_association_does_not_create_geometry(self):
        self.configure_building_reference()
        self.locations['features'] = []
        a = self.catalog['unitBuildingAssociations'][0]
        a.pop('referencePlaceID'); a['identifierKind'] = 'operatorMap'
        self.run_export(); self.run_validate()
        catalog = json.loads((self.output / 'public-catalog.json').read_bytes())
        self.assertEqual(catalog.get('unitBuildingAssociations'), [a])
        self.assertEqual(json.loads((self.output / 'public-locations.geojson').read_bytes())['features'], [])

    def test_map_floor_is_a_schematic_label_and_cannot_be_inferred_for_legal_records(self):
        self.configure_building_reference(); self.locations['features'] = []
        a = self.catalog['unitBuildingAssociations'][0]
        a.pop('referencePlaceID'); a.update(identifierKind='operatorMap', mapFloor='2')
        self.run_export(); self.run_validate()
        public = json.loads((self.output / 'public-catalog.json').read_bytes())['unitBuildingAssociations'][0]
        self.assertEqual(public['mapFloor'], '2')
        self.assertNotIn('referencePlaceID', public)
        self.output = self.directory / 'false-legal-floor'
        a['identifierKind'] = 'municipalLegal'
        self.run_export(valid=False)

    def test_building_reference_rejects_false_precision_and_bad_joins(self):
        for index, mutation in enumerate(('unit-kind', 'unit', 'floor', 'estimated', 'unknown-kind',
                                          'missing-reference', 'other-street', 'operator-reference', 'wrong-building', 'duplicate-unit')):
            with self.subTest(mutation=mutation):
                self.output = self.directory / ('bad-reference-' + str(index))
                f = self.configure_building_reference(); a = self.catalog['unitBuildingAssociations'][0]
                if mutation == 'unit-kind': f['properties']['kind'] = 'unitPosition'
                if mutation == 'unit': f['properties']['unit'] = '001'
                if mutation == 'floor': f['properties']['floor'] = '1'
                if mutation == 'estimated': f['properties']['verification'] = 'estimated'
                if mutation == 'unknown-kind': f['properties']['referenceKind'] = 'door'
                if mutation == 'missing-reference': a['referencePlaceID'] = 'missing'
                if mutation == 'other-street': a['address'] = '999 Other Rd'
                if mutation == 'operator-reference': a['identifierKind'] = 'operatorMap'
                if mutation == 'wrong-building': a['building'] = 'B'
                if mutation == 'duplicate-unit':
                    other = dict(a, id='second-association', building='B'); other.pop('referencePlaceID')
                    self.catalog['unitBuildingAssociations'].append(other)
                self.run_export(valid=False)
                self.assertFalse(self.output.exists())

    def test_large_public_catalog_uses_compact_json_within_native_loader_limit(self):
        self.catalog['sources'][0]['title'] = 'x' * 1900
        self.catalog['communities'][0]['aliases'] = ['Public alias ' + str(i) + ' ' + 'x'*150 for i in range(11_500)]
        self.run_export(); self.run_validate()
        path = self.output / 'public-catalog.json'
        self.assertLessEqual(path.stat().st_size, 3_000_000)
        value = json.loads(path.read_bytes())
        self.assertEqual(value['communities'][0]['aliases'], self.catalog['communities'][0]['aliases'])
        self.output = self.directory / 'reviewed-public-growth'
        self.catalog['communities'][0]['aliases'] = ['Public alias ' + str(i) + ' ' + 'x'*150 for i in range(17_000)]
        self.run_export(); self.run_validate()
        path = self.output / 'public-catalog.json'
        self.assertGreater(path.stat().st_size, 2_000_000)
        self.assertLessEqual(path.stat().st_size, 3_000_000)
        self.assertNotIn(b'\n  "', path.read_bytes(), 'Reviewed growth must use compact JSON before increasing the bounded budget')
        self.assertEqual(json.loads(path.read_bytes())['communities'][0]['aliases'],
                         self.catalog['communities'][0]['aliases'])
        self.output = self.directory / 'oversized-catalog'
        self.catalog['communities'][0]['aliases'] *= 2
        self.run_export(valid=False)
        self.assertFalse(self.output.exists())

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

    def configure_disputed_unit(self):
        # Only the reserved public identity is real; all fixture geometry is invented.
        sources = ['spanish-ridge-7380-county-unit-labels', 'spanish-ridge-7380-county-unit-buildings']
        self.catalog['sources'] = [dict(id=source, title='Synthetic published source',
            url='https://example.invalid/map', retrievedAt='2026-01-01T00:00:00Z') for source in sources]
        self.catalog['communities'][0].update(id='spanish-ridge-7380', address='7380 W RUSSELL RD', sourceIDs=sources)
        feature = self.locations['features'][0]
        feature['id'] = 'spanish-ridge-7380-unit-county-2179616-201'
        feature['properties'].update(communityID='spanish-ridge-7380', address='7380 W RUSSELL RD',
            building='', unit='201', floor='', sourceIDs=sources,
            notes='ARBITRARY RAW NOTE: Building A has been verified; secret resident detail')
        return feature

    def test_reserved_unit_identity_cannot_be_reclassified_as_building_reference(self):
        f = self.configure_disputed_unit()
        f['properties'].update(kind='building', unit='', floor='', building='A',
            referenceKind='assessorLegalBuildingPolygon')
        self.run_export(valid=False)
        self.assertFalse(self.output.exists())

    def run_validate(self, valid=True):
        result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/public-catalog.py'), 'validate',
            '--directory', str(self.output)], text=True, capture_output=True)
        if valid:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def write_locations_with_reviewed_digest(self, value):
        path = self.output / 'public-locations.geojson'
        path.write_text(json.dumps(value))
        manifest = self.output / 'public-catalog-review.json'
        review = json.loads(manifest.read_text())
        review['resourcesSHA256'][path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(review))

    def test_disputed_unit_retains_fixed_qualifier_without_copying_raw_notes(self):
        original = copy.deepcopy(self.configure_disputed_unit())
        self.run_export()
        feature = json.loads((self.output / 'public-locations.geojson').read_text())['features'][0]
        self.assertEqual(feature['properties']['notes'],
            'Published unit position; not an entrance or exact door. Verify the physical street, unit and building on arrival. '
            'Building A for 201 is not asserted. Building and floor remain unknown.')
        original['properties'].pop('notes')
        original['properties'].pop('gateCode')
        actual = copy.deepcopy(feature)
        actual['properties'].pop('notes')
        self.assertEqual(actual, original)
        self.assertNotIn('ARBITRARY RAW NOTE', (self.output / 'public-locations.geojson').read_text())
        self.run_validate()

    def test_disputed_unit_rejects_unreviewed_field_or_source_shape_before_export(self):
        feature = self.configure_disputed_unit()
        original = copy.deepcopy(feature['properties'])
        mutations = [dict(communityID='fictional'), dict(address='7340 W RUSSELL RD'), dict(building='A'),
            dict(unit='202'), dict(floor='2'), dict(kind='building'), dict(verification='estimated'),
            dict(sourceIDs=['spanish-ridge-7380-county-unit-labels']),
            dict(sourceIDs=['spanish-ridge-7380-county-unit-labels', 'spanish-ridge-7380-county-unit-labels']),
            dict(sourceIDs=['spanish-ridge-7380-county-unit-labels', 'unreviewed-source'])]
        self.catalog['sources'].append(dict(id='unreviewed-source', title='Synthetic replacement source',
            url='https://example.invalid/replacement', retrievedAt='2026-01-01T00:00:00Z'))
        self.catalog['communities'].append(dict(id='fictional', name='Another Fictional Property',
            address='100 Fictional Rd', zip='89113', aliases=[], sourceIDs=['unreviewed-source'],
            researchStatus='mapped', gapNotes=[]))
        for index, mutation in enumerate(mutations):
            with self.subTest(mutation=mutation):
                feature['properties'] = dict(copy.deepcopy(original), **mutation)
                self.output = self.directory / ('rejected-' + str(index))
                result = self.run_export(valid=False)
                self.assertIn('Unreviewed disputed unit source shape', result.stderr)
                self.assertFalse(self.output.exists())

    def test_disputed_unit_source_order_does_not_change_reviewed_identity(self):
        feature = self.configure_disputed_unit()
        feature['properties']['sourceIDs'] = list(reversed(feature['properties']['sourceIDs']))
        self.run_export()
        exported = json.loads((self.output / 'public-locations.geojson').read_text())['features'][0]
        self.assertIn('Building A for 201 is not asserted', exported['properties']['notes'])
        self.assertEqual(exported['properties']['sourceIDs'], feature['properties']['sourceIDs'])
        self.run_validate()

    def test_reserved_qualifier_is_not_applied_to_other_feature_ids(self):
        feature = self.configure_disputed_unit()
        feature['id'] += '-unreviewed'
        self.run_export()
        p = json.loads((self.output / 'public-locations.geojson').read_text())['features'][0]['properties']
        self.assertEqual(p['notes'], 'Published unit position; not an entrance or exact door. '
            'Verify the physical street, unit and building on arrival.')

    def test_validator_rejects_missing_wrong_or_augmented_disputed_qualifier(self):
        self.configure_disputed_unit()
        self.run_export()
        locations = json.loads((self.output / 'public-locations.geojson').read_text())
        generic = 'Published unit position; not an entrance or exact door. Verify the physical street, unit and building on arrival.'
        expected = generic + ' Building A for 201 is not asserted. Building and floor remain unknown.'
        for note in (generic, generic + ' Building B for 201 is not asserted. Building and floor remain unknown.',
                expected + ' ARBITRARY EXTRA FREE TEXT', expected.replace('unknown.', 'verified.')):
            with self.subTest(note=note):
                locations['features'][0]['properties']['notes'] = note
                self.write_locations_with_reviewed_digest(locations)
                result = self.run_validate(valid=False)
                self.assertIn('Unexpected public position text', result.stderr)

    def test_validator_rejects_reserved_unit_field_drift_despite_fixed_qualifier(self):
        self.configure_disputed_unit()
        self.run_export()
        original = json.loads((self.output / 'public-locations.geojson').read_text())
        for mutation in (dict(building='A'), dict(address='7340 W RUSSELL RD'), dict(unit='202'),
                dict(sourceIDs=['spanish-ridge-7380-county-unit-labels'])):
            with self.subTest(mutation=mutation):
                locations = copy.deepcopy(original)
                locations['features'][0]['properties'].update(mutation)
                self.write_locations_with_reviewed_digest(locations)
                result = self.run_validate(valid=False)
                self.assertIn('Unreviewed disputed unit source shape', result.stderr)

    def configure_riley_position(self, street):
        community = 'alcove-6350' if street == '6350' else 'alcove'
        county_source = 'riley-county-' + street
        sources = ['alcove-geo-0', 'alcove-map-api-0', 'alcove-building-groups-0', county_source]
        self.catalog['sources'].extend(dict(id=source, title='Synthetic published source',
            url='https://example.invalid/map', retrievedAt='2026-01-01T00:00:00Z') for source in sources)
        self.catalog['communities'][0].update(id=community, address=street + ' S Riley St',
            sourceIDs=sources)
        feature = self.locations['features'][0]
        feature['id'] = community + ('-unit-10839817' if street == '6350' else '-unit-10839508')
        feature['properties'].update(communityID=community, address=street + ' S Riley St',
            building='6' if street == '6350' else '1', unit='138' if street == '6350' else '188',
            sourceIDs=sources, identityUncertain=False,
            notes='PRIVATE RILEY TEXT straddling both ZIPs')
        return feature

    def test_riley_positions_keep_fixed_street_scoped_zip_notes_without_raw_text(self):
        fixtures = copy.deepcopy((self.catalog, self.locations))
        generic = 'Published unit position; not an entrance or exact door. Verify the physical street, unit and building on arrival.'
        caution = ' The same unit label is not confirmed by the county parcel records; check the unit/building on arrival.'
        for street, clause in (
                ('6350', ' Street address is supported by the 6350 county parcel containing this published position. '
                    'County ZIP is 89113; the retained directory postal ZIP 89148 is not independently verified for 6350.'),
                ('6355', ' This 6355 position falls in the retained 89148 county polygon, consistent with the official postal address.')):
            for uncertain in ((None, False, True) if street == '6350' else (None, False)):
                with self.subTest(street=street, uncertain=uncertain):
                    self.catalog, self.locations = copy.deepcopy(fixtures)
                    self.output = self.directory / ('riley-' + street + '-' + str(uncertain))
                    feature = self.configure_riley_position(street)
                    if uncertain is None:
                        feature['properties'].pop('identityUncertain')
                    else:
                        feature['properties']['identityUncertain'] = uncertain
                    if uncertain is True:
                        feature['id'] = 'alcove-6350-unit-10839846'
                        feature['properties'].update(building='6', unit='327', floor='3')
                    expected = copy.deepcopy(feature)
                    expected['properties'].pop('gateCode')
                    expected['properties']['notes'] = generic + clause + (caution if street == '6350' and uncertain is True else '')
                    self.run_export()
                    actual = json.loads((self.output / 'public-locations.geojson').read_text())['features'][0]
                    self.assertEqual(actual, expected)
                    self.assertNotIn('PRIVATE RILEY TEXT', json.dumps(actual))
                    self.assertNotIn('straddling', actual['properties']['notes'])
                    self.run_validate()

    def test_riley_note_exception_rejects_unreviewed_identity_precision_and_sources(self):
        fixtures = copy.deepcopy((self.catalog, self.locations))
        for street in ('6350', '6355'):
            self.catalog, self.locations = copy.deepcopy(fixtures)
            feature = self.configure_riley_position(street)
            original = copy.deepcopy(feature)
            wrong_street = '6355' if street == '6350' else '6350'
            wrong_source = 'riley-county-' + wrong_street
            self.catalog['sources'].append(dict(id=wrong_source, title='Synthetic other county source',
                url='https://example.invalid/other', retrievedAt='2026-01-01T00:00:00Z'))
            for index, mutation in enumerate((dict(communityID='fictional'), dict(address=wrong_street + ' S Riley St'), dict(kind='building'),
                    dict(verification='estimated'), dict(sourceIDs=['official-fixture']),
                    dict(sourceIDs=['official-fixture', wrong_source]),
                    dict(sourceIDs=original['properties']['sourceIDs'] + [wrong_source]),
                    dict(building='1' if street == '6350' else '6'))):
                with self.subTest(street=street, mutation=mutation):
                    feature['properties'] = dict(copy.deepcopy(original['properties']), **mutation)
                    self.output = self.directory / ('invalid-riley-' + street + '-' + str(index))
                    result = self.run_export(valid=False)
                    self.assertIn('Unreviewed Riley position source shape', result.stderr)
                    self.assertFalse(self.output.exists())
            prefix = 'alcove-6350-unit-' if street == '6350' else 'alcove-unit-'
            for index, wrong_id in enumerate(('fictional-unit-synthetic', prefix, prefix + 'invented',
                    prefix + '1234567', prefix + '123456789', prefix + '１２３４５６７８')):
                with self.subTest(street=street, wrong_id=wrong_id):
                    feature['properties'] = copy.deepcopy(original['properties'])
                    feature['id'] = wrong_id
                    self.output = self.directory / ('invalid-riley-id-' + street + '-' + str(index))
                    result = self.run_export(valid=False)
                    self.assertIn('Unreviewed Riley position source shape', result.stderr)
                    self.assertFalse(self.output.exists())

    def test_riley_county_assertion_requires_every_reviewed_source(self):
        fixtures = copy.deepcopy((self.catalog, self.locations))
        for street in ('6350', '6355'):
            self.catalog, self.locations = copy.deepcopy(fixtures)
            feature = self.configure_riley_position(street)
            sources = list(feature['properties']['sourceIDs'])
            invalid_sources = [[source for source in sources if source != removed] for removed in sources]
            invalid_sources += [[sources[-1]], sources[:3] + [sources[0]], sources + ['official-fixture']]
            for index, source_ids in enumerate(invalid_sources):
                with self.subTest(street=street, sources=source_ids):
                    feature['properties']['sourceIDs'] = source_ids
                    self.output = self.directory / ('removed-source-' + street + '-' + str(index))
                    result = self.run_export(valid=False)
                    self.assertIn('Unreviewed Riley position source shape', result.stderr)
                    self.assertFalse(self.output.exists())
            feature['properties']['sourceIDs'] = list(reversed(sources))
            self.output = self.directory / ('reordered-sources-' + street)
            self.run_export()
            exported = json.loads((self.output / 'public-locations.geojson').read_text())['features'][0]
            self.assertEqual(exported['properties']['sourceIDs'], list(reversed(sources)))
            self.run_validate()

    def test_riley_uncertainty_is_bound_to_both_exact_reviewed_ids_and_tuples(self):
        fixtures = copy.deepcopy((self.catalog, self.locations))
        reviewed = [('alcove-6350-unit-10839846', ('6', '327', '3')),
            ('alcove-6350-unit-10839920', ('7', '303', '3'))]
        for index, (feature_id, identity) in enumerate(reviewed):
            self.catalog, self.locations = copy.deepcopy(fixtures)
            feature = self.configure_riley_position('6350')
            feature['id'] = feature_id
            feature['properties'].update(zip(('building', 'unit', 'floor'), identity))
            feature['properties']['identityUncertain'] = True
            self.output = self.directory / ('reviewed-uncertain-' + str(index))
            self.run_export()
            validated_output = self.output
            original = json.loads((self.output / 'public-locations.geojson').read_text())
            self.assertIn('same unit label is not confirmed', original['features'][0]['properties']['notes'])
            self.run_validate()
            locations = copy.deepcopy(original)
            locations['features'][0]['id'] = 'alcove-6350-unit-10839817'
            self.write_locations_with_reviewed_digest(locations)
            result = self.run_validate(valid=False)
            self.assertIn('Unreviewed Riley position source shape', result.stderr)
            for mutation_index, mutation in enumerate((dict(identityUncertain=False), dict(unit='999'),
                    dict(floor='2'), dict(building='7' if identity[0] == '6' else '6'))):
                with self.subTest(feature_id=feature_id, mutation=mutation):
                    self.output = validated_output
                    locations = copy.deepcopy(original)
                    locations['features'][0]['properties'].update(mutation)
                    self.write_locations_with_reviewed_digest(locations)
                    result = self.run_validate(valid=False)
                    self.assertIn('Unreviewed Riley position source shape', result.stderr)
                    feature['properties'] = dict(copy.deepcopy(original['features'][0]['properties']), **mutation)
                    self.output = self.directory / ('uncertainty-drift-' + str(index) + '-' + str(mutation_index))
                    result = self.run_export(valid=False)
                    self.assertIn('Unreviewed Riley position source shape', result.stderr)
                    self.assertFalse(self.output.exists())
            feature['properties'] = copy.deepcopy(original['features'][0]['properties'])
            feature['properties'].pop('identityUncertain')
            locations = copy.deepcopy(original)
            locations['features'][0]['properties'].pop('identityUncertain')
            self.output = validated_output
            self.write_locations_with_reviewed_digest(locations)
            result = self.run_validate(valid=False)
            self.assertIn('Unreviewed Riley position source shape', result.stderr)
            self.output = self.directory / ('missing-uncertainty-' + str(index))
            self.run_export(valid=False)
            self.assertFalse(self.output.exists())

    def test_riley_rejects_uncertainty_claims_and_reviewed_tuples_on_other_ids(self):
        fixtures = copy.deepcopy((self.catalog, self.locations))
        for street in ('6350', '6355'):
            for index, mutation in enumerate((dict(identityUncertain=True),
                    dict(building='6', unit='327', floor='3'), dict(building='7', unit='303', floor='3'))):
                with self.subTest(street=street, mutation=mutation):
                    self.catalog, self.locations = copy.deepcopy(fixtures)
                    feature = self.configure_riley_position(street)
                    feature['properties'].update(mutation)
                    self.output = self.directory / ('unreviewed-uncertainty-' + street + '-' + str(index))
                    result = self.run_export(valid=False)
                    self.assertIn('Unreviewed Riley position source shape', result.stderr)
                    self.assertFalse(self.output.exists())

    def test_validator_requires_exact_riley_qualifiers_and_reviewed_shape(self):
        fixtures = copy.deepcopy((self.catalog, self.locations))
        for street in ('6350', '6355'):
            self.catalog, self.locations = copy.deepcopy(fixtures)
            self.output = self.directory / ('validated-riley-' + street)
            self.configure_riley_position(street)
            self.run_export()
            original = json.loads((self.output / 'public-locations.geojson').read_text())
            note = original['features'][0]['properties']['notes']
            for mutation in (dict(notes=note.split(' Street address')[0].split(' This 6355')[0]),
                    dict(notes=note + ' PRIVATE FREE TEXT'), dict(address='100 Fictional Rd'),
                    dict(sourceIDs=['official-fixture']), dict(verification='estimated'),
                    dict(sourceIDs=['riley-county-' + street]), dict(identityUncertain=True)):
                with self.subTest(street=street, mutation=mutation):
                    locations = copy.deepcopy(original)
                    locations['features'][0]['properties'].update(mutation)
                    self.write_locations_with_reviewed_digest(locations)
                    self.run_validate(valid=False)
            locations = copy.deepcopy(original)
            locations['features'][0]['id'] = ('alcove-6350' if street == '6350' else 'alcove') + '-unit-invented'
            self.write_locations_with_reviewed_digest(locations)
            self.run_validate(valid=False)

    def test_other_position_notes_keep_exact_generic_or_estimate_policy(self):
        expected = {
            'sourceMapped': 'Published unit position; not an entrance or exact door. '
                'Verify the physical street, unit and building on arrival.',
            'estimated': 'May be inaccurate. Estimated unit position; not an entrance or exact door. '
                'Confirm the physical street, unit and building on arrival.',
        }
        for verification, note in expected.items():
            with self.subTest(verification=verification):
                self.locations['features'][0]['properties']['verification'] = verification
                self.output = self.directory / ('generic-' + verification)
                self.run_export()
                locations = json.loads((self.output / 'public-locations.geojson').read_text())
                self.assertEqual(locations['features'][0]['properties']['notes'], note)
                self.run_validate()
                locations['features'][0]['properties']['notes'] += ' ARBITRARY EXTRA FREE TEXT'
                self.write_locations_with_reviewed_digest(locations)
                result = self.run_validate(valid=False)
                self.assertIn('Unexpected public position text', result.stderr)

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

    def test_county_and_hud_property_references_keep_distinct_lower_precision_lineage(self):
        for index, kind in enumerate(('municipalBusinessLicensePropertyReference', 'hudApproximatePropertyReference',
                                      'countyPublishedAddressPropertyReference', 'countyTestAddressPropertyReference')):
            with self.subTest(kind=kind):
                self.output = self.directory / ('property-reference-' + str(index))
                self.evidence = [dict(communityID='fictional', communityType='apartment', areaScope='core',
                    addressSourceIDs=['official-fixture'], coordinate=dict(kind=kind, sourceIDs=['official-fixture']))]
                self.run_export(); self.run_validate()
                community = json.loads((self.output / 'public-catalog.json').read_bytes())['communities'][0]
                self.assertEqual(community['publicEvidence']['coordinate']['kind'], kind)
                self.assertTrue(any('not a unit' in note for note in community['gapNotes']))
                if kind == 'countyTestAddressPropertyReference':
                    self.assertTrue(any('Test service' in note and 'lower confidence' in note for note in community['gapNotes']))

    def test_conflicting_source_city_labels_remain_qualified_without_fabricated_coordinates(self):
        self.evidence = [dict(communityID='fictional', communityType='apartment', areaScope='nearbyOutsideFocus',
            addressSourceIDs=['official-fixture'], addressCityDisagreement=True,
            coordinate=dict(kind='operatorPublishedPropertyPoint', sourceIDs=['official-fixture']))]
        self.run_export(); self.run_validate()
        c = json.loads((self.output / 'public-catalog.json').read_bytes())['communities'][0]
        self.assertTrue(c['publicEvidence']['addressCityDisagreement'])
        self.assertTrue(any('disagree on the city label' in n for n in c['gapNotes']))
        self.output = self.directory / 'invalid-city-qualification'
        self.evidence[0]['addressCityDisagreement'] = 'private free text'
        self.run_export(valid=False)

    def test_single_building_configuration_keeps_unit_and_door_positions_unverified(self):
        self.evidence = [dict(communityID='fictional',communityType='seniorLiving',areaScope='core',
            addressSourceIDs=['official-fixture'],coordinate=dict(kind='operatorPublishedPropertyPoint',sourceIDs=['official-fixture']),
            singleResidentialBuilding=dict(publishedStories=4,publishedApartments=195,sourceIDs=['official-fixture']))]
        self.run_export(); self.run_validate()
        c = json.loads((self.output / 'public-catalog.json').read_bytes())['communities'][0]
        self.assertTrue(any('one residential building' in n and '195' in n and 'remain unverified' in n for n in c['gapNotes']))
        self.assertEqual(len(json.loads((self.output / 'public-locations.geojson').read_bytes())['features']),1)
        self.output = self.directory/'invalid-building-count'
        self.evidence[0]['singleResidentialBuilding']['publishedStories'] = True
        self.run_export(valid=False)

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
