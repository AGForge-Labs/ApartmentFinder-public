"""Offline fixture extraction uses invented public data and literal expectations."""
import copy
import contextlib
import io
import hashlib
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/public-catalog-compatibility-fixtures.py'
PROFILE = ROOT / 'Tests/fixtures/public-catalog-admission-214c'
FILES = ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson')
FORMAT = 'ApartmentFinder-offline-public-compatibility-v0'
COVERAGE = [
    'Public source-derived apartment and multifamily inventory. This is not a certified exhaustive inventory.',
    'Published unit positions retain their source confidence. Estimated positions may be inaccurate; no exact doors or entrances are established.',
    'New Silverado-area records may have only a verified property name and street address. Missing unit maps remain explicit research gaps.',
    'Public map geometry is unconfirmed. OpenStreetMap contributors attribution and ODbL requirements apply to retained OSM paths.',
]
GAP = 'Public property identity and available source positions are incomplete. No exact door, entrance or current access condition is established.'
NOTE = 'Published unit position; not an entrance or exact door. Verify the physical street, unit and building on arrival.'


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + '\n').encode()


def descriptor(body):
    return {'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest()}


class OfflineCompatibilityFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve())
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.baseline = self.directory / 'baseline'
        self.bundle = self.directory / 'bundle'
        self.output = self.directory / 'result'
        self.baseline.mkdir(); self.bundle.mkdir()
        source = {'id': 's-one', 'title': 'Fictional directory', 'url': 'https://example.invalid/map',
                  'retrievedAt': '2026-01-01T00:00:00Z'}
        sources = [source, dict(source, id='s-two', title='Different literal provenance'),
                   dict(source, id='s-orphan', url='https://example.invalid/orphan')]
        community = {'id': 'fictional', 'name': 'Fictional Apartments', 'address': '100 Fictional Road',
                     'zip': '89123', 'aliases': [], 'sourceIDs': ['s-one'],
                     'researchStatus': 'publicSourceInventory', 'gapNotes': [GAP],
                     'digitalLocker': {'status': 'present', 'sourceIDs': ['s-two'],
                                       'checkedAt': '2026-01-01', 'placementDescription': 'Location not mapped.'}}
        feature = {'type': 'Feature', 'id': 'f-two', 'geometry': {'type': 'Point', 'coordinates': [0.0, 0.0]},
                   'properties': {'communityID': 'fictional', 'address': '100 Fictional Road', 'building': 'A',
                                  'unit': '001', 'floor': '', 'kind': 'unitPosition', 'verification': 'sourceMapped',
                                  'sourceIDs': ['s-one'], 'notes': NOTE}}
        self.documents = {
            FILES[0]: {'schemaVersion': 1, 'packVersion': 'fictional-baseline', 'generatedAt': '2026-01-01T00:00:00Z',
                       'scopeZIPs': ['89123'], 'sources': sources, 'communities': [community],
                       'coverage': {'inventoryComplete': False, 'notes': COVERAGE}},
            FILES[1]: {'type': 'FeatureCollection', 'schemaVersion': 1, 'packVersion': 'fictional-baseline',
                       'features': [feature, dict(copy.deepcopy(feature), id='f-one')]},
            FILES[2]: {'type': 'FeatureCollection', 'schemaVersion': 1, 'packVersion': 'fictional-baseline', 'features': []},
        }
        self.bundle_documents = copy.deepcopy(self.documents)
        for value in self.bundle_documents.values(): value['packVersion'] = 'fictional-bundle'
        self.write_inputs()

    def write_inputs(self):
        for directory, documents in [(self.baseline, self.documents), (self.bundle, self.bundle_documents)]:
            for name, value in documents.items(): (directory / name).write_bytes(encoded(value))
        self.manifest = {'schemaVersion': 1, 'revision': 'fictional-r1', 'sequence': 91,
                         'packVersion': 'fictional-baseline', 'files': {
                             name: descriptor((self.baseline / name).read_bytes()) for name in FILES}}
        self.manifest_path = self.baseline / 'manifest.json'
        self.manifest_path.write_bytes(encoded(self.manifest))
        self.bundle_pins = {'fixtureFormat': FORMAT, 'packVersion': 'fictional-bundle', 'files': {
            name: descriptor((self.bundle / name).read_bytes()) for name in FILES}}
        self.pins_path = self.directory / 'bundle-pins.json'
        self.pins_path.write_bytes(encoded(self.bundle_pins))

    def prepare(self, *, output=None, profile=None, floor='91', valid=True, manifest_hash=None):
        existed = self.output.exists()
        command = [sys.executable, '-X', 'utf8', '-B', str(SCRIPT), 'prepare', '--baseline', str(self.baseline),
                   '--baseline-manifest-sha256', manifest_hash or descriptor(self.manifest_path.read_bytes())['sha256'],
                   '--bundle', str(self.bundle), '--bundle-descriptors', str(self.pins_path),
                   '--bundle-descriptors-sha256', descriptor(self.pins_path.read_bytes())['sha256'],
                   '--admission-profile', str(profile or PROFILE), '--minimum-root-sequence', str(floor),
                   '--output', str(output or self.output)]
        result = subprocess.run(command, capture_output=True, text=True)
        if valid:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.fixture_pin = json.loads(result.stdout).get('fixtureSHA256', '0' * 64)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Compatibility fixtures:', result.stderr)
            if not existed: self.assertFalse(self.output.exists())
        return result

    def verify(self, valid=True):
        result = subprocess.run([sys.executable, '-X', 'utf8', '-B', str(SCRIPT), 'verify',
            '--directory', str(self.output), '--admission-profile', str(PROFILE),
            '--fixture-sha256', self.fixture_pin], capture_output=True, text=True)
        if valid: self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Compatibility fixtures:', result.stderr)
        return result

    def test_exact_raw_copies_keep_original_order_inner_arrays_and_whole_objects(self):
        self.prepare()
        for directory, original in [('baseline', self.baseline), ('bundle', self.bundle)]:
            for name in FILES: self.assertEqual((self.output / directory / name).read_bytes(), (original / name).read_bytes())
        self.assertEqual(json.loads((self.output / 'baseline' / FILES[1]).read_bytes())['features'],
                         self.documents[FILES[1]]['features'])
        self.verify()

    def test_registry_keeps_finite_twins_url_aliases_and_only_actual_orphan(self):
        self.prepare()
        registry = json.loads((self.output / 'conservation-registry.json').read_bytes())
        self.assertEqual(registry['semanticDuplicateGroups'], [{
            'key': ['fictional', '100 fictional rd', 'a', '001', '', 'unitPosition', None],
            'memberIDs': ['f-two', 'f-one']}])
        self.assertEqual(registry['sourceURLAliases'], [{'url': 'https://example.invalid/map', 'sourceIDs': ['s-one', 's-two']}])
        self.assertEqual(registry['orphanSourceIDs'], ['s-orphan'])
        self.assertEqual(registry['counts'], {'communities': 1, 'sources': 3, 'points': 2, 'paths': 0,
                                            'associations': 0, 'floorReferences': 0})

    def test_bundle_anchor_has_no_fabricated_feed_identity_and_explicit_history_floor(self):
        self.prepare()
        anchor = json.loads((self.output / 'bootstrap-anchor.json').read_bytes())
        self.assertEqual(set(anchor), {'fixtureFormat', 'admissionProfile', 'packVersion', 'files', 'minimumRootSequence'})
        self.assertEqual(anchor['packVersion'], 'fictional-bundle')
        self.assertEqual(anchor['minimumRootSequence'], 91)
        self.assertEqual(anchor['files'], self.bundle_pins['files'])
        self.assertEqual(anchor['fixtureFormat'], FORMAT)

    def test_coupled_rehash_cannot_replace_the_externally_pinned_fixture(self):
        self.prepare()
        root = self.output / 'compatibility-fixture.json'
        self.assertTrue(root.is_file(), 'Offline fixture needs an externally pinned descriptor')
        value = json.loads(root.read_bytes())
        # Even a self-consistent rewrite under a caller's unchanged trusted pin
        # cannot quietly replace the reviewed anchor/registry identity.
        anchor_path = self.output / 'bootstrap-anchor.json'
        anchor = json.loads(anchor_path.read_bytes()); anchor['minimumRootSequence'] = 92
        anchor_path.write_bytes(encoded(anchor))
        value['files']['bootstrap-anchor.json'] = descriptor(anchor_path.read_bytes())
        root.write_bytes(encoded(value))
        self.verify(valid=False)

    def test_private_door_claim_is_rejected_with_fresh_public_file_hashes(self):
        self.documents[FILES[1]]['features'][0]['properties'].update(kind='door', verification='fieldVerified')
        self.write_inputs(); self.prepare(valid=False)

    def test_unchanged_catalog_reserve_accepts_exact_limit_and_rejects_one_more(self):
        path = self.baseline / FILES[0]
        raw = path.read_bytes()
        path.write_bytes(raw + b' ' * (3_000_000 - 512 - len(raw)))
        self.manifest['files'][FILES[0]] = descriptor(path.read_bytes())
        self.manifest_path.write_bytes(encoded(self.manifest))
        self.prepare(output=self.directory / 'exact-reserve')
        path.write_bytes(path.read_bytes() + b' ')
        self.manifest['files'][FILES[0]] = descriptor(path.read_bytes())
        self.manifest_path.write_bytes(encoded(self.manifest))
        self.prepare(valid=False)

    def test_raw_hash_mismatch_is_rejected_before_output(self):
        with (self.baseline / FILES[1]).open('ab') as stream: stream.write(b' ')
        self.prepare(valid=False)

    def test_wrong_reviewed_manifest_pin_is_rejected(self):
        self.prepare(manifest_hash='0' * 64, valid=False)

    def test_private_field_with_consistent_new_hash_is_rejected_by_raw_admission(self):
        self.documents[FILES[0]]['communities'][0]['gateCode'] = 'PRIVATE FICTIONAL'
        self.write_inputs(); self.prepare(valid=False)

    def test_unresolved_nested_locker_source_is_not_ignored(self):
        self.documents[FILES[0]]['communities'][0]['digitalLocker']['sourceIDs'] = ['missing']
        self.write_inputs(); self.prepare(valid=False)

    def test_unknown_source_file_is_rejected_without_reading_or_copying_it(self):
        (self.baseline / 'personal-backup.json').write_bytes(b'PRIVATE FICTIONAL')
        self.prepare(valid=False)

    def test_input_output_overlap_is_rejected_without_changing_input(self):
        before = {p.name: p.read_bytes() for p in self.baseline.iterdir()}
        self.prepare(output=self.baseline / 'output', valid=False)
        self.assertEqual({p.name: p.read_bytes() for p in self.baseline.iterdir()}, before)

    def test_parent_traversal_output_alias_cannot_write_inside_baseline(self):
        bridge = self.directory / 'bridge'; bridge.mkdir()
        before = {p.name: p.read_bytes() for p in self.baseline.iterdir()}
        output = bridge / '..' / 'baseline' / 'injected-output'
        self.prepare(output=output, valid=False)
        self.assertEqual({p.name: p.read_bytes() for p in self.baseline.iterdir()}, before)
        self.assertFalse(output.exists())

    def test_parent_traversal_input_alias_cannot_hide_nested_output(self):
        original = self.baseline
        bridge = self.directory / 'bridge'; bridge.mkdir()
        before = {p.name: p.read_bytes() for p in original.iterdir()}
        self.baseline = bridge / '..' / 'baseline'
        output = original / 'injected-output'
        self.prepare(output=output, valid=False)
        self.assertEqual({p.name: p.read_bytes() for p in original.iterdir()}, before)
        self.assertFalse(output.exists())

    def test_disjoint_similar_prefix_output_remains_allowed(self):
        output = self.directory / 'baseline-independent'
        self.prepare(output=output)
        self.assertTrue((output / 'compatibility-fixture.json').is_file())
        self.assertEqual(set(p.name for p in self.baseline.iterdir()), set(FILES) | {'manifest.json'})

    @unittest.skipUnless(os.name == 'nt', 'Windows case aliases are platform specific')
    def test_windows_case_alias_still_rejects_nested_output(self):
        before = {p.name: p.read_bytes() for p in self.baseline.iterdir()}
        self.prepare(output=Path(str(self.baseline).upper()) / 'injected-output', valid=False)
        self.assertEqual({p.name: p.read_bytes() for p in self.baseline.iterdir()}, before)

    @unittest.skipUnless(os.name == 'nt', 'Windows extended namespace is platform specific')
    def test_extended_namespace_output_alias_cannot_write_inside_baseline(self):
        before = {p.name: p.read_bytes() for p in self.baseline.iterdir()}
        bs = chr(92)
        output = Path(bs * 2 + '?' + bs + str(self.baseline / 'injected-output'))
        self.prepare(output=output, valid=False)
        self.assertEqual({p.name: p.read_bytes() for p in self.baseline.iterdir()}, before)
        self.assertFalse(output.exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows extended namespace is platform specific')
    def test_extended_namespace_input_alias_cannot_hide_nested_output(self):
        original = self.baseline
        before = {p.name: p.read_bytes() for p in original.iterdir()}
        bs = chr(92)
        self.baseline = Path(bs * 2 + '?' + bs + str(original))
        output = original / 'injected-output'
        self.prepare(output=output, valid=False)
        self.assertEqual({p.name: p.read_bytes() for p in original.iterdir()}, before)
        self.assertFalse(output.exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows namespace admission is platform specific')
    def test_all_windows_namespace_spellings_reject_before_any_filesystem_inspection(self):
        spec = importlib.util.spec_from_file_location('fixture_namespace_admission', SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        prepare = [str(SCRIPT), 'prepare', '--baseline', str(self.baseline),
                   '--baseline-manifest-sha256', descriptor(self.manifest_path.read_bytes())['sha256'],
                   '--bundle', str(self.bundle), '--bundle-descriptors', str(self.pins_path),
                   '--bundle-descriptors-sha256', descriptor(self.pins_path.read_bytes())['sha256'],
                   '--admission-profile', str(PROFILE), '--minimum-root-sequence', '91', '--output', str(self.output)]
        verify = [str(SCRIPT), 'verify', '--directory', str(self.output), '--admission-profile', str(PROFILE),
                  '--fixture-sha256', '0' * 64]
        bs = chr(92)
        spellings = [
            bs * 2 + '?' + bs + str(self.baseline), '//?/' + str(self.baseline).replace(bs, '/'),
            bs * 2 + '.' + bs + str(self.baseline), '//./' + str(self.baseline).replace(bs, '/'),
            bs + '??' + bs + str(self.baseline), bs * 2 + '??' + bs + str(self.baseline),
            bs * 2 + bs.join(('server.invalid', 'share', 'source')), '//server.invalid/share/source',
            bs * 2 + '?' + bs + bs.join(('UNC', 'server.invalid', 'share', 'source')),
            bs * 2 + '?' + bs + bs.join(('GLOBALROOT', 'Device', 'HarddiskVolume1', 'source')),
            'C:relative-source', bs + 'root-relative-source',
        ]
        before = {p.name: p.read_bytes() for p in self.baseline.iterdir()}
        for argv, options in [(prepare, ('--baseline', '--bundle', '--bundle-descriptors', '--admission-profile', '--output')),
                              (verify, ('--directory', '--admission-profile'))]:
            for option in options:
                for spelling in spellings:
                    command = list(argv); command[command.index(option) + 1] = spelling
                    with self.subTest(action=argv[1], option=option, spelling=spelling):
                        stderr = io.StringIO()
                        # No UNC or device operand can reach filesystem inspection.
                        # This trap prevents network-path access even if admission regresses.
                        with contextlib.ExitStack() as stack:
                            stack.enter_context(mock.patch.object(sys, 'argv', command))
                            stack.enter_context(contextlib.redirect_stderr(stderr))
                            stack.enter_context(mock.patch.object(module, 'ancestors', side_effect=AssertionError('filesystem inspection reached')))
                            self.assertEqual(module.main(), 1)
                        self.assertIn('Unsupported Windows path namespace', stderr.getvalue())
        self.assertEqual({p.name: p.read_bytes() for p in self.baseline.iterdir()}, before)
        self.assertFalse(self.output.exists())

    @unittest.skipUnless(os.name == 'nt', 'Windows canonical namespace is platform specific')
    def test_canonical_result_cannot_reintroduce_an_unsupported_namespace(self):
        spec = importlib.util.spec_from_file_location('fixture_canonical_namespace', SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        output = self.baseline / 'injected-output'
        bs = chr(92)
        extended = Path(bs * 2 + '?' + bs + str(output))
        real_resolve = Path.resolve

        def resolved_alias(path, *args, **kwargs):
            if path == output: return extended
            return real_resolve(path, *args, **kwargs)

        # The Windows resolver can retain an extended prefix on error paths.
        # The returned namespace must also fail closed before an overlap comparison.
        with mock.patch.object(Path, 'resolve', new=resolved_alias):
            with self.assertRaisesRegex(ValueError, 'Unsupported Windows path namespace'):
                module.no_overlap(output, (self.baseline, self.bundle))
        self.assertFalse(output.exists())
        self.assertEqual(set(p.name for p in self.baseline.iterdir()), set(FILES) | {'manifest.json'})

    def test_ordinary_relative_profile_path_remains_supported(self):
        self.prepare(profile=Path('Tests/fixtures/public-catalog-admission-214c'))
        self.verify()

    def test_git_index_and_checkout_preserve_exact_profile_bytes(self):
        binary = shutil.which('git')
        if binary is None: self.skipTest('Git is unavailable')
        expected = {
            'public-catalog-feed.py': 'af823dca006e71219d7b0f0b9745726497e845bf8477e531466d320b96b3aea6',
            'public-catalog.py': '214c362a9fd4636179ad895aa6e654466c7eb90aa5afd3938b1be8d1b280c583',
            'reviewed-directory-features-20261023.json': 'ef44cf26b94a929aa51d40a3613a67532f3df181bf14b219a7ef030be1d41b1b',
            'reviewed-local28-features-20261023.json': '829a8e0f1804ae6548a521cf1d667ae051ba3f7cbf6c1fc92b473207a3e1303f',
            'reviewed-manhattan12-features-20261023.json': 'b1699d79c3fecba0cae5d454201b903bd381e583572f1dc59a55a62c908a8d36',
            'reviewed-sourceareas30-features-20261023.json': 'ae4b2ee9aa0880f69488558863b50f06dacb7cd2b33ab45add3b3b8763a32ff1',
            'reviewed-trend-confidence-features-20261026.json': '34a52840c3b69cadd1b181430867963d0859e1eec10e390cc85d043f1363faf6',
        }
        repository = self.directory / 'git-profile'; repository.mkdir()
        template = self.directory / 'empty-template'; template.mkdir()
        attributes = self.directory / 'empty-global-attributes'; attributes.write_bytes(b'')
        environment = {k: v for k, v in os.environ.items() if k not in
                       ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR')}
        environment.update(GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0', GCM_INTERACTIVE='Never')

        def git(*args):
            result = subprocess.run([binary, '-c', 'core.autocrlf=true', '-c', 'core.safecrlf=false',
                '-c', 'core.attributesFile=' + str(attributes), *args], cwd=repository,
                env=environment, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
            return result.stdout

        git('init', '--quiet', '--template=' + str(template))
        (repository / '.gitattributes').write_bytes((ROOT / '.gitattributes').read_bytes())
        profile_path = Path('Tests/fixtures/public-catalog-admission-214c')
        target = repository / profile_path; target.mkdir(parents=True)
        fixture_attributes = ROOT / 'Tests/fixtures/.gitattributes'
        if fixture_attributes.exists():
            (target.parent / '.gitattributes').write_bytes(fixture_attributes.read_bytes())
        for name, sha in expected.items():
            raw = (PROFILE / name).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), sha)
            (target / name).write_bytes(raw)
        git('add', '--all')
        for name, sha in expected.items():
            staged = git('show', ':' + (profile_path / name).as_posix())
            self.assertEqual(hashlib.sha256(staged).hexdigest(), sha, 'Git normalized staged profile: ' + name)
        git('diff', '--cached', '--check')
        checkout = self.directory / 'checked-out'; checkout.mkdir()
        git('checkout-index', '--all', '--prefix=' + checkout.as_posix() + '/')
        for name, sha in expected.items():
            raw = (checkout / profile_path / name).read_bytes()
            self.assertEqual(hashlib.sha256(raw).hexdigest(), sha, 'Git changed checked-out profile: ' + name)
            self.assertEqual(raw, (PROFILE / name).read_bytes())

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir(); (self.output / 'keep').write_bytes(b'keep')
        self.prepare(valid=False)
        self.assertEqual((self.output / 'keep').read_bytes(), b'keep')

    def test_floor_below_reviewed_snapshot_sequence_is_rejected(self):
        self.prepare(floor='90', valid=False)

    def test_mutated_profile_is_rejected_before_import(self):
        changed = self.directory / 'profile'; changed.mkdir()
        for p in PROFILE.iterdir(): (changed / p.name).write_bytes(p.read_bytes())
        with (changed / 'public-catalog.py').open('ab') as stream: stream.write(b'\nraise RuntimeError("MUST NOT EXECUTE")\n')
        result = self.prepare(profile=changed, valid=False)
        self.assertNotIn('MUST NOT EXECUTE', result.stderr)

    def test_verifier_uses_the_hashed_snapshot_even_if_files_change_after_read(self):
        self.prepare()
        spec = importlib.util.spec_from_file_location('fixture_snapshot_race', SCRIPT)
        module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        original_read = module.read
        triggered = False

        def read_then_change(path, maximum):
            nonlocal triggered
            raw = original_read(path, maximum)
            if path == self.output / 'conservation-registry.json' and not triggered:
                triggered = True
                location = self.output / 'baseline' / FILES[1]
                value = json.loads(location.read_bytes()); value['features'].pop()
                location.write_bytes(encoded(value))
                manifest_path = self.output / 'baseline' / 'manifest.json'
                manifest = json.loads(manifest_path.read_bytes())
                manifest['files'][FILES[1]] = descriptor(location.read_bytes())
                manifest_path.write_bytes(encoded(manifest))
                registry_path = self.output / 'conservation-registry.json'
                registry = json.loads(registry_path.read_bytes())
                registry['counts']['points'] = 1
                registry['semanticDuplicateGroups'] = []
                registry['files'] = manifest['files']
                registry['baselineManifest'] = descriptor(manifest_path.read_bytes())
                registry_path.write_bytes(encoded(registry))
            return raw

        module.read = read_then_change
        result = module.verify(SimpleNamespace(directory=str(self.output), admission_profile=str(PROFILE),
                                               fixture_sha256=self.fixture_pin))
        self.assertTrue(triggered)
        self.assertEqual(result['counts']['points'], 2)
        self.assertEqual(len(json.loads((self.output / 'baseline' / FILES[1]).read_bytes())['features']), 1)

    def test_tampered_raw_output_is_rejected(self):
        self.prepare()
        with (self.output / 'baseline' / FILES[0]).open('ab') as stream: stream.write(b' ')
        self.verify(valid=False)

    def test_tampered_finite_group_membership_is_rejected(self):
        self.prepare()
        path = self.output / 'conservation-registry.json'; value = json.loads(path.read_bytes())
        value['semanticDuplicateGroups'][0]['memberIDs'].pop()
        path.write_bytes(encoded(value)); self.verify(valid=False)

    def test_tampered_anchor_extra_feed_sequence_is_rejected(self):
        self.prepare()
        path = self.output / 'bootstrap-anchor.json'; value = json.loads(path.read_bytes())
        value['sequence'] = 13; path.write_bytes(encoded(value)); self.verify(valid=False)

    def test_duplicate_raw_json_key_is_rejected_even_with_a_matching_hash(self):
        raw = self.manifest_path.read_bytes().replace(b'"sequence": 91', b'"sequence": 90, "sequence": 91')
        self.manifest_path.write_bytes(raw); self.prepare(valid=False)

    def test_linked_input_is_rejected(self):
        original = self.baseline / FILES[2]; target = self.directory / 'real-paths'; original.replace(target)
        try: original.symlink_to(target)
        except OSError: self.skipTest('platform does not allow creating symlinks')
        self.prepare(valid=False)


if __name__ == '__main__': unittest.main()
