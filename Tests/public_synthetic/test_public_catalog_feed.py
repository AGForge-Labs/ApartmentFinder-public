"""Credential-free publisher fixtures; every address and coordinate is fictional."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/public-catalog-feed.py'
SPEC = importlib.util.spec_from_file_location('feed_admission', ROOT / 'scripts/public-catalog.py')
ADMISSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADMISSION)
FILES = ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson')


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode('utf-8')


class PublicCatalogFeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.source = self.directory / 'input'
        self.source.mkdir()
        self.output = self.directory / 'feed'
        community = dict(id='fictional', name='Fictional Ápartments', address='100 Fictional Rd',
            zip='89123', aliases=[], deliveryAddresses=['110 Fictional Rd'], sourceIDs=['fixture'],
            researchStatus='publicSourceInventory')
        community['gapNotes'] = ADMISSION.gap_notes(community)
        catalog = dict(schemaVersion=1, packVersion='fixture-v2', generatedAt='2026-01-01T00:00:00Z',
            scopeZIPs=['89123'], communities=[community], sources=[dict(id='fixture',
                title='Published fictional property', url='https://example.invalid/map', retrievedAt='2026-01-01T00:00:00Z')],
            coverage=dict(inventoryComplete=False, notes=copy.deepcopy(ADMISSION.COVERAGE_NOTES)))
        properties = dict(communityID='fictional', address='100 Fictional Rd', building='A', unit='001', floor='',
            kind='unitPosition', verification='estimated', identityUncertain=True, sourceIDs=['fixture'],
            entranceSideEstimate=dict(frontage=[dict(latitude=0.0, longitude=0.0), dict(latitude=0.001, longitude=0.001)],
                workingAllowanceMeters=10, uncertaintyCalibrated=False, doorCoordinatesVerified=False,
                entranceCoordinatesVerified=False, physicalSignageVerified=False,
                dwellingFloorEvidence='historicalExplicit', dwellingFloor='2', entryLevelDescription='Entry elevation unknown',
                sharedUnits=[], sourceUnitID='fictional-source-001', sourceDate='2004-12-06',
                evidenceNotes='Fictional historical frontage; no individual doorway is observed.'))
        estimate = dict(type='Feature', id='fictional-estimate-001',
            geometry=dict(type='Point', coordinates=[0.0, 0.0]), properties=properties)
        properties['notes'] = ADMISSION.position_note(estimate)
        other_street = copy.deepcopy(estimate)
        other_street['id'] = 'fictional-other-street-001'
        other_street['properties'].update(address='110 Fictional Rd', building='B', floor='3',
            verification='sourceMapped', sourceUnitID='fictional-published-001')
        other_street['properties'].pop('entranceSideEstimate')
        other_street['properties']['notes'] = ADMISSION.SOURCE_NOTE
        area = dict(type='Feature', id='fictional-area', geometry=dict(type='Point', coordinates=[0.0, 0.0]),
            properties=dict(communityID='fictional', address='100 Fictional Rd', building='A', unit='', floor='',
                kind='building', verification='sourceMapped', referenceKind='operatorMapBuildingArea',
                estimatedHorizontalUncertaintyM=20, mapLabelOccurrenceID='fictional-left-lobe', sourceIDs=['fixture']))
        area['properties']['notes'] = ADMISSION.position_note(area)
        catalog['unitBuildingAssociations'] = [dict(id='fictional-association', communityID='fictional',
            address='100 Fictional Rd', unit='001', building='A', identifierKind='operatorMap',
            sourceIDs=['fixture'], referencePlaceID='fictional-area', mapFloor='2', sourceUnitID='fictional-source-001')]
        catalog['unitFloorReferences'] = [dict(id='fictional-floor', communityID='fictional',
            address='110 Fictional Rd', unit='002', floor='5', sourceIDs=['fixture'], sourceRevision='2026-01-01')]
        self.documents = {
            'public-catalog.json': catalog,
            'public-locations.geojson': dict(type='FeatureCollection', schemaVersion=1, packVersion='fixture-v2',
                features=[estimate, other_street, area]),
            'public-paths.geojson': dict(type='FeatureCollection', schemaVersion=1, packVersion='fixture-v2', features=[]),
            'known-addresses.json': dict(schemaVersion=1, packVersion='fixture-v2',
                entries=[dict(address='100 Fictional Rd', deliveryAddresses=['110 Fictional Rd'])]),
        }
        self.write_source()

    def write_source(self):
        for name, document in self.documents.items():
            (self.source / name).write_bytes(encoded(document))
        catalog = self.documents['public-catalog.json']
        review = dict(schemaVersion=1, publicFieldsOnly=True, version=catalog['packVersion'], sourcePackVersion='fixture-v1',
            counts=dict(communities=len(catalog['communities']), sources=len(catalog['sources']),
                positions=len(self.documents['public-locations.geojson']['features']),
                paths=len(self.documents['public-paths.geojson']['features'])),
            sourceSHA256={name: '1' * 64 for name in ('catalog.json', 'locations.geojson', 'paths.geojson')},
            resourcesSHA256={name: hashlib.sha256((self.source / name).read_bytes()).hexdigest() for name in self.documents})
        (self.source / 'public-catalog-review.json').write_bytes(encoded(review))

    def run_prepare(self, *, revision='r1', sequence=1, previous=None, valid=True):
        command = [sys.executable, '-X', 'utf8', '-B', str(SCRIPT), 'prepare', '--directory', str(self.source),
            '--output', str(self.output), '--revision=' + revision, '--sequence=' + str(sequence)]
        if previous is not None:
            command += ['--previous-manifest', str(previous)]
        result = subprocess.run(command, text=True, encoding='utf-8', capture_output=True)
        if valid:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def tree(self):
        return {str(p.relative_to(self.output)): p.read_bytes() for p in self.output.rglob('*') if p.is_file()}

    def test_prepare_writes_only_three_lossless_compact_payloads_and_bound_manifests(self):
        self.run_prepare(revision='2026-10-22.1', sequence=7)
        revision = self.output / 'revisions' / '2026-10-22.1'
        manifest_bytes = (self.output / 'latest.json').read_bytes()
        self.assertLessEqual(len(manifest_bytes), 16_384)
        self.assertEqual(manifest_bytes, (revision / 'manifest.json').read_bytes())
        manifest = json.loads(manifest_bytes)
        self.assertEqual(set(manifest), {'schemaVersion', 'revision', 'sequence', 'packVersion', 'files'})
        self.assertEqual((manifest['schemaVersion'], manifest['revision'], manifest['sequence'], manifest['packVersion']),
            (1, '2026-10-22.1', 7, 'fixture-v2'))
        self.assertEqual(set(manifest['files']), set(FILES))
        self.assertEqual({p.relative_to(self.output).as_posix() for p in self.output.rglob('*') if p.is_file()},
            {'latest.json'} | {'revisions/2026-10-22.1/' + name for name in (*FILES, 'manifest.json')})
        for name in FILES:
            body = (revision / name).read_bytes()
            self.assertEqual(json.loads(body), self.documents[name])
            self.assertEqual(body, (json.dumps(self.documents[name], ensure_ascii=False, sort_keys=True,
                separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8'))
            self.assertEqual(manifest['files'][name], dict(bytes=len(body), sha256=hashlib.sha256(body).hexdigest()))
            self.assertLess(len(body), (self.source / name).stat().st_size)
        points = json.loads((revision / 'public-locations.geojson').read_bytes())['features']
        self.assertEqual([p['properties']['address'] for p in points[:2]], ['100 Fictional Rd', '110 Fictional Rd'])
        self.assertEqual([p['properties']['unit'] for p in points[:2]], ['001', '001'])
        self.assertEqual(points[0]['properties']['floor'], '')
        self.assertEqual(points[0]['properties']['entranceSideEstimate']['dwellingFloorEvidence'], 'historicalExplicit')

    def test_prepare_is_deterministic_and_does_not_rewrite_source_files(self):
        source_before = {p.name: p.read_bytes() for p in self.source.iterdir()}
        self.run_prepare()
        first = self.tree()
        self.output = self.directory / 'other-feed'
        self.run_prepare()
        self.assertEqual(self.tree(), first)
        self.assertEqual({p.name: p.read_bytes() for p in self.source.iterdir()}, source_before)

    def test_existing_revisions_are_immutable_and_sequence_must_increase(self):
        self.run_prepare()
        before = self.tree()
        for revision, sequence in (('r1', 2), ('R1', 2), ('r2', 1), ('r2', 0)):
            with self.subTest(revision=revision, sequence=sequence):
                self.run_prepare(revision=revision, sequence=sequence, valid=False)
                self.assertEqual(self.tree(), before)
        self.run_prepare(revision='r2', sequence=2)
        after = self.tree()
        for name, body in before.items():
            if name != 'latest.json':
                self.assertEqual(after[name], body)
        self.assertEqual(json.loads(after['latest.json'])['sequence'], 2)

    def test_optional_previous_manifest_rejects_replay_and_non_increasing_sequences(self):
        self.run_prepare(revision='old', sequence=7)
        previous = self.output / 'latest.json'
        self.output = self.directory / 'next-feed'
        for revision, sequence in (('old', 8), ('OLD', 8), ('new', 7), ('new', 6)):
            with self.subTest(revision=revision, sequence=sequence):
                self.run_prepare(revision=revision, sequence=sequence, previous=previous, valid=False)
                self.assertFalse(self.output.exists())
        self.run_prepare(revision='new', sequence=8, previous=previous)
        self.assertEqual(json.loads((self.output / 'latest.json').read_bytes())['sequence'], 8)

    def test_revision_and_sequence_inputs_are_bounded_and_path_safe(self):
        for revision in ('', '.', '..', '../escape', 'r/x', 'r\\x', 'https://example.invalid/r',
                'r%2fx', '-r', 'é', 'a' * 81):
            with self.subTest(revision=revision):
                self.run_prepare(revision=revision, valid=False)
                self.assertFalse(self.output.exists())
        for sequence in (0, -1, '1.5', 'True', 2 ** 63):
            with self.subTest(sequence=sequence):
                self.run_prepare(sequence=sequence, valid=False)
                self.assertFalse(self.output.exists())
        self.run_prepare(revision='a' * 80, sequence=2 ** 63 - 1)

    def test_unknown_input_files_private_backup_and_workflow_inputs_are_rejected(self):
        for name in ('backup.json', 'manifest.csv', 'private-notes.txt', 'release.yml'):
            with self.subTest(name=name):
                extra = self.source / name
                extra.write_text('{"recipient":"SYNTHETIC PRIVATE FIELD"}', encoding='utf-8')
                self.run_prepare(valid=False)
                self.assertFalse(self.output.exists())
                extra.unlink()
        (self.source / '.github').mkdir()
        self.run_prepare(valid=False)
        self.assertFalse(self.output.exists())

    def test_public_admission_rejects_private_fields_precision_weakening_bad_geometry_and_joins(self):
        original = copy.deepcopy(self.documents)
        mutations = [lambda d: d['public-catalog.json'].update(privateNotes='SYNTHETIC PRIVATE FIELD'),
            lambda d: d['public-locations.geojson']['features'][0]['properties'].update(recipient='SYNTHETIC PRIVATE FIELD'),
            lambda d: d['public-locations.geojson']['features'][0]['properties'].update(gateCode='SYNTHETIC PRIVATE FIELD'),
            lambda d: d['public-locations.geojson']['features'][0]['properties'].update(accessCode='SYNTHETIC PRIVATE FIELD'),
            lambda d: d['public-locations.geojson']['features'][0]['properties'].update(approachID='SYNTHETIC PRIVATE FIELD'),
            lambda d: d['public-locations.geojson']['features'][0]['properties'].update(graphNodeID='SYNTHETIC PRIVATE FIELD'),
            lambda d: d['public-locations.geojson']['features'][0]['properties']['entranceSideEstimate'].update(doorCoordinatesVerified=True),
            lambda d: d['public-locations.geojson']['features'][0]['properties']['entranceSideEstimate'].update(uncertaintyCalibrated=0),
            lambda d: d['public-locations.geojson']['features'][0]['properties'].update(kind='door', verification='fieldVerified'),
            lambda d: d['public-locations.geojson']['features'][0]['geometry'].update(coordinates=[0, 91]),
            lambda d: d['public-locations.geojson']['features'].append(copy.deepcopy(d['public-locations.geojson']['features'][0])),
            lambda d: d['public-catalog.json']['unitBuildingAssociations'][0].update(referencePlaceID='missing'),
            lambda d: d['public-catalog.json']['sources'][0].update(url='https://example.invalid/map?token=SYNTHETIC'),
            lambda d: d['public-paths.geojson'].update(packVersion='other'),
            lambda d: d['public-paths.geojson'].update(features=[dict(type='Feature', id='fictional-path',
                geometry=dict(type='LineString', coordinates=[[0, 0], [0, 0.001]]), properties=dict(
                    communityID='fictional', fromNode='a', toNode='b', mode='walk', oneWay=False,
                    blocked=False, stairs=False, confirmed=True, sourceIDs=['fixture'], notes=ADMISSION.PATH_NOTE))])]
        for index, mutation in enumerate(mutations):
            with self.subTest(mutation=index):
                self.documents = copy.deepcopy(original)
                mutation(self.documents)
                self.write_source()
                self.run_prepare(valid=False)
                self.assertFalse(self.output.exists())

    def test_missing_review_digest_tampering_and_unknown_review_fields_are_rejected(self):
        review_path = self.source / 'public-catalog-review.json'
        review = review_path.read_bytes()
        review_path.unlink()
        self.run_prepare(valid=False)
        self.assertFalse(self.output.exists())
        review_path.write_bytes(review)
        (self.source / 'public-paths.geojson').write_bytes((self.source / 'public-paths.geojson').read_bytes() + b' ')
        self.run_prepare(valid=False)
        self.assertFalse(self.output.exists())
        self.write_source()
        value = json.loads(review)
        value['privateNotes'] = 'SYNTHETIC PRIVATE FIELD'
        review_path.write_bytes(encoded(value))
        self.run_prepare(valid=False)
        self.assertFalse(self.output.exists())

    def test_duplicate_json_keys_and_unsupported_collection_schema_are_rejected(self):
        catalog_path = self.source / 'public-catalog.json'
        body = catalog_path.read_bytes()
        catalog_path.write_bytes(body.replace(b'"schemaVersion": 1', b'"schemaVersion": 1, "schemaVersion": 1', 1))
        review_path = self.source / 'public-catalog-review.json'
        review = json.loads(review_path.read_bytes())
        review['resourcesSHA256']['public-catalog.json'] = hashlib.sha256(catalog_path.read_bytes()).hexdigest()
        review_path.write_bytes(encoded(review))
        result = self.run_prepare(valid=False)
        self.assertIn('Duplicate JSON object key', result.stderr)
        self.assertFalse(self.output.exists())
        for name in FILES:
            for schema in (2, True):
                with self.subTest(name=name, schema=schema):
                    self.documents[name]['schemaVersion'] = schema
                    self.write_source()
                    self.run_prepare(valid=False)
                    self.assertFalse(self.output.exists())
                    self.documents[name]['schemaVersion'] = 1

    def test_native_resource_budgets_are_checked_before_reading_and_output_creation(self):
        for name, maximum in (('public-catalog.json', 3_000_000),
                ('public-locations.geojson', 64_000_000), ('public-paths.geojson', 16_000_000)):
            with self.subTest(name=name):
                self.write_source()
                with (self.source / name).open('wb') as stream:
                    stream.truncate(maximum + 1)
                self.run_prepare(valid=False)
                self.assertFalse(self.output.exists())

    def test_previous_manifest_has_closed_schema_strict_int64_and_bounded_descriptors(self):
        self.run_prepare()
        manifest = json.loads((self.output / 'latest.json').read_bytes())
        self.output = self.directory / 'new-feed'
        previous = self.directory / 'previous.json'
        mutations = [dict(privateNotes='SYNTHETIC PRIVATE FIELD'), dict(schemaVersion=True), dict(schemaVersion=2),
            dict(sequence=True), dict(sequence=0), dict(sequence=2 ** 63), dict(revision='../escape'),
            dict(packVersion={'privateNotes': 'SYNTHETIC'})]
        for index, mutation in enumerate(mutations):
            with self.subTest(mutation=index):
                previous.write_bytes(encoded(dict(copy.deepcopy(manifest), **mutation)))
                self.run_prepare(revision='new', sequence=2, previous=previous, valid=False)
                self.assertFalse(self.output.exists())
        for descriptor in (dict(bytes=True, sha256='1' * 64), dict(bytes=0, sha256='1' * 64),
                dict(bytes=3_000_001, sha256='1' * 64), dict(bytes=20, sha256='A' * 64),
                dict(bytes=20, sha256='1' * 64, url='https://example.invalid/payload')):
            with self.subTest(descriptor=descriptor):
                value = copy.deepcopy(manifest)
                value['files']['public-catalog.json'] = descriptor
                previous.write_bytes(encoded(value))
                self.run_prepare(revision='new', sequence=2, previous=previous, valid=False)
                self.assertFalse(self.output.exists())
        for remove in (True, False):
            value = copy.deepcopy(manifest)
            if remove:
                value['files'].pop('public-paths.geojson')
            else:
                value['files']['known-addresses.json'] = dict(bytes=1, sha256='1' * 64)
            previous.write_bytes(encoded(value))
            self.run_prepare(revision='new', sequence=2, previous=previous, valid=False)
            self.assertFalse(self.output.exists())
        previous.write_bytes(encoded(manifest) + b' ' * 16_384)
        self.run_prepare(revision='new', sequence=2, previous=previous, valid=False)
        self.assertFalse(self.output.exists())

    def test_existing_feed_must_remain_json_only_and_its_revision_bytes_must_verify(self):
        self.run_prepare()
        before = self.tree()
        extra = self.output / '.github'
        extra.mkdir()
        self.run_prepare(revision='r2', sequence=2, valid=False)
        self.assertEqual(self.tree(), before)
        extra.rmdir()
        payload = self.output / 'revisions' / 'r1' / 'public-paths.geojson'
        payload.write_bytes(payload.read_bytes() + b' ')
        invalid_before = self.tree()
        self.run_prepare(revision='r2', sequence=2, valid=False)
        self.assertEqual(self.tree(), invalid_before)

    def test_linked_input_payload_is_rejected(self):
        target = self.directory / 'real-public-paths.json'
        source = self.source / 'public-paths.geojson'
        source.rename(target)
        try:
            os.symlink(target, source)
        except OSError as error:
            if getattr(error, 'winerror', None) == 1314:
                self.skipTest('Windows symlink privilege is unavailable')
            raise
        self.run_prepare(valid=False)
        self.assertFalse(self.output.exists())

    def test_output_cannot_overlap_public_input(self):
        before = {p.name: p.read_bytes() for p in self.source.iterdir()}
        for output in (self.source, self.source / 'feed'):
            with self.subTest(output=output):
                self.output = output
                self.run_prepare(valid=False)
                self.assertEqual({p.name: p.read_bytes() for p in self.source.iterdir()}, before)

    def test_failed_latest_replacement_never_changes_previous_selection(self):
        self.run_prepare()
        latest = (self.output / 'latest.json').read_bytes()
        spec = importlib.util.spec_from_file_location('feed_publisher', SCRIPT)
        publisher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(publisher)
        with mock.patch.object(publisher.os, 'replace', side_effect=OSError('synthetic replacement failure')):
            with self.assertRaises(OSError):
                publisher.prepare(self.source, self.output, 'r2', 2)
        self.assertEqual((self.output / 'latest.json').read_bytes(), latest)
        self.assertFalse([p for p in self.output.iterdir() if p.name not in ('latest.json', 'revisions')])


if __name__ == '__main__':
    unittest.main()
