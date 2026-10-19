"""Portable integrity checks. These do not claim Swift or app acceptance."""
import importlib.util
import base64
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


class PublicPreflightTests(unittest.TestCase):
    def test_ontrac_ui_setup_uses_the_validated_fixture_without_bypassing_import(self):
        support = (ROOT / 'App/UITestSupport.swift').read_text()
        encoded = re.search(r'Data\(base64Encoded: "([A-Za-z0-9+/=]+)"\)', support).group(1)
        archive = ROOT / 'Tests/ApartmentCoreTests/Fixtures/ontrac-synthetic.zip'
        self.assertEqual(base64.b64decode(encoded, validate=True), archive.read_bytes())
        self.assertIn('static func fictionalManifestPayload() throws -> DataPackPayload', support)
        self.assertIn('guard enabled, storeURL() != nil else', support)
        self.assertIn('guard store.pack?.catalog.packVersion != "fictional-ontrac-v1" else', support)
        self.assertIn('try store.importPrivatePack(fictionalManifestPayload())', support)
        self.assertIn('imports.open(try UITestSupport.manifestURL(), addresses: store.knownApartmentAddresses)', support)
        native = (ROOT / 'NativeTests/OnTracImportSetupTests.swift').read_text()
        for boundary in ('UITestSupport.fictionalManifestPayload()', 'UITestSupport.manifestURL()',
                         'SharedManifestContainer.data(url)', 'ManifestReader.read(', 'coordinator.open('):
            self.assertIn(boundary, native)
        self.assertNotIn('coordinator.request =', native)

    def test_append_restore_fixture_keeps_the_known_door_identity(self):
        source = (ROOT / 'NativeTests/ApartmentRouteFollowupTests.swift').read_text()
        locations = json.loads(re.search(r'let locations = #"(.*?)"#', source).group(1))
        door = re.search(r'let door = Place\(id: "owner-4108",(.*?)\n        try store!\.importBackup',
                         source, re.S).group(1)
        identity = dict(re.findall(r'\b(communityID|building|unit|floor): "([^"]*)"', door))
        candidates = [feature['properties'] for feature in locations['features']
                      if feature['properties']['communityID'] == identity['communityID']
                      and feature['properties']['unit'] == identity['unit']]
        self.assertEqual(len(candidates), 1)
        for field in ('building', 'floor'):
            self.assertEqual(identity.get(field, ''), candidates[0][field],
                             'A known checked door must not contradict its fictional source identity')

    def test_fictional_native_pack_payloads_contain_schema_valid_locations(self):
        fixtures = 0
        for path in sorted((ROOT / 'NativeTests').glob('*.swift')):
            fields = dict(re.findall(r'let (catalog|locations|paths) = #"(.*?)"#', path.read_text()))
            if set(fields) != {'catalog', 'locations', 'paths'}:
                continue
            with self.subTest(source=path.name):
                fixtures += 1
                catalog, locations, paths = (json.loads(fields[key]) for key in ('catalog', 'locations', 'paths'))
                self.assertTrue(catalog['communities'], 'Complete private-pack fixtures need communities')
                self.assertTrue(locations['features'], 'DataPackPayload rejects a complete pack without mapped locations')
                communities = {item['id'] for item in catalog['communities']}
                sources = {item['id'] for item in catalog['sources']}
                self.assertEqual(set(catalog['scopeZIPs']), {'89113', '89148'})
                for collection in (locations, paths):
                    self.assertEqual(collection['type'], 'FeatureCollection')
                    self.assertEqual(collection['schemaVersion'], 1)
                    self.assertEqual(collection['packVersion'], catalog['packVersion'])
                for point in locations['features']:
                    self.assertEqual(point['geometry']['type'], 'Point')
                    lon, lat = point['geometry']['coordinates']
                    self.assertTrue(-180 <= lon <= 180 and -90 <= lat <= 90)
                    properties = point['properties']
                    self.assertTrue({'communityID', 'address', 'building', 'unit', 'floor', 'kind', 'verification', 'sourceIDs', 'notes'} <= set(properties))
                    self.assertIn(properties['communityID'], communities)
                    self.assertTrue(properties['sourceIDs'])
                    self.assertTrue(set(properties['sourceIDs']) <= sources)
        self.assertEqual(fixtures, 10, 'Review new or removed embedded fixtures explicitly')

    def test_reviewed_native_inventory_matches_current_source(self):
        artifact = module('public_preflight_artifact', ROOT / 'scripts/testflight-artifact.py')
        self.assertEqual(artifact.expected_test_count(ROOT), 115)
        profile = json.loads((ROOT / 'scripts/iteration-profile.json').read_text())
        self.assertEqual(profile['full_acceptance'], {'native': 75, 'ui': 40, 'original_pngs': 45})


    def test_public_selection_is_exact_and_excludes_private_acceptance(self):
        selection = json.loads((ROOT / 'scripts/public-synthetic-tests.json').read_text())
        iteration = module('public_preflight_iteration', ROOT / 'scripts/iterate.py')
        self.assertEqual(selection['schema_version'], 1)
        for key, folder, target, count in (
            ('core', 'Tests/ApartmentCoreTests', '', 88),
            ('native', 'NativeTests', 'ApartmentFinderTests/', 60),
            ('ui', 'UITests', 'ApartmentFinderUITests/', 2),
        ):
            values = selection[key]
            self.assertEqual(len(values), count)
            self.assertEqual(len(values), len(set(values)))
            self.assertTrue(set(values) <= {target + item for item in iteration.test_ids(ROOT, folder)})
        self.assertEqual(set(selection['ui']), {
            'ApartmentFinderUITests/OnTracFlowTests/testSourceUnitPinAppearsOnMapAfterOnTracImport',
            'ApartmentFinderUITests/OnTracFlowTests/testZIPPreviewCancellationEmptyDayAndApartmentNavigation',
        })
        for identity in selection['core']:
            cls = identity.split('/')[0]
            sources = [path.read_text() for path in (ROOT / 'Tests/ApartmentCoreTests').glob('*.swift')
                       if re.search(r'\bclass\s+' + cls + r'\s*:', path.read_text())]
            self.assertEqual(len(sources), 1)
            self.assertNotIn('PrivatePackFixture', sources[0])
        for identity in selection['native']:
            _, cls, name = identity.split('/')
            source = (ROOT / 'NativeTests' / (cls + '.swift')).read_text()
            start = source.index('func ' + name + '(')
            end = source.find('\n    func test', start + 1)
            body = source[start:end if end >= 0 else len(source)]
            self.assertNotIn('PrivatePackFixture', body)
            if cls == 'AppStoreTests':
                self.assertNotIn('storeURL()', body, 'Mixed helper defaults to the genuine private pack')

    def test_public_workflow_is_manual_and_data_isolated(self):
        path = ROOT / '.github/workflow-drafts/public-synthetic-check.yml'
        if not path.exists():
            path = ROOT / '.github/workflows/public-synthetic-check.yml'
        self.assertTrue(path.is_file())
        workflow = path.read_text()
        self.assertIn('workflow_dispatch:', workflow)
        self.assertIn('runs-on: macos-15-intel', workflow)
        self.assertIn('DEVELOPER_DIR: /Applications/Xcode_26.2.app/Contents/Developer', workflow)
        self.assertIn('com.apple.CoreSimulator.SimRuntime.iOS-26-2', workflow)
        self.assertIn('github.event.repository.private == false', workflow)
        self.assertIn('persist-credentials: false', workflow)
        self.assertIn('contents: read', workflow)
        for forbidden in ('pull_request_target:', 'schedule:', 'push:', 'secrets.', 'upload-artifact', 'actions/cache', 'validate-ios.sh', 'testflight-upload'):
            self.assertNotIn(forbidden, workflow)
        self.assertIn('public-synthetic-tests.json', workflow)
        self.assertIn('verify_native_ids', workflow)
        self.assertIn('verify_core_ids', workflow)
        self.assertIn('full_acceptance=False', workflow)


if __name__ == '__main__':
    unittest.main()
