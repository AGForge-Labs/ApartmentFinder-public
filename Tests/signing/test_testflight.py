import base64
import copy
import contextlib
import hashlib
import importlib.util
import io
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / 'scripts' / 'testflight.py'
spec = importlib.util.spec_from_file_location('testflight', SCRIPT)
testflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(testflight)


class TestFlightChecks(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 9, 21, tzinfo=timezone.utc)
        self.raw = b'signed-profile-fixture'
        self.cert = b'distribution-certificate-fixture'
        self.config = {
            'team_id': 'YU2A5J5978',
            'bundle_id': 'dev.galaxybigbird.ApartmentFinder',
            'marketing_version': '0.1.0',
            'profile_name': 'ApartmentFinder TestFlight',
            'profile_uuid': '26c255c3-a625-4505-810e-1052d193acab',
            'profile_sha256': hashlib.sha256(self.raw).hexdigest(),
            'certificate_sha256': hashlib.sha256(self.cert).hexdigest(),
            'api_key_id': '89788L8TG2',
        }
        self.profile = {
            'Name': self.config['profile_name'],
            'UUID': self.config['profile_uuid'],
            'TeamIdentifier': [self.config['team_id']],
            'ApplicationIdentifierPrefix': [self.config['team_id']],
            'Platform': ['iOS'],
            'CreationDate': (self.now - timedelta(days=1)).replace(tzinfo=None),
            'ExpirationDate': (self.now + timedelta(days=300)).replace(tzinfo=None),
            'DeveloperCertificates': [self.cert],
            'Entitlements': {
                'application-identifier': self.config['team_id'] + '.' + self.config['bundle_id'],
                'com.apple.developer.team-identifier': self.config['team_id'],
                'get-task-allow': False,
                'beta-reports-active': True,
            },
        }

    def validate(self, profile=None, raw=None):
        return testflight.validate_profile(
            self.profile if profile is None else profile,
            self.raw if raw is None else raw, self.config, self.now)

    def test_prepare_rejects_unconfigured_share_signing_before_writing_secrets(self):
        old_config = dict(self.config, issuer_id="fafeb7f1-ba53-4935-892e-80da735ed265")
        env = {
            "GITHUB_RUN_NUMBER": "1", "GITHUB_RUN_ATTEMPT": "1",
            "APPLE_CERTIFICATE_PASSWORD": "fixture-only",
            "APPLE_CERTIFICATE_BASE64": base64.b64encode(b"fixture-p12").decode(),
            "APPLE_PROVISIONING_PROFILE_BASE64": base64.b64encode(self.raw).decode(),
            "APP_STORE_CONNECT_KEY_BASE64": base64.b64encode(b"fixture-key").decode(),
        }
        for incomplete in (old_config, dict(old_config, app_group="group.dev.galaxybigbird.ApartmentFinder")):
            with self.subTest(configured_group="app_group" in incomplete), tempfile.TemporaryDirectory() as folder:
                directory = pathlib.Path(folder)
                with patch.object(testflight.sys, "platform", "darwin"), patch.dict(testflight.os.environ, env, clear=True):
                    with patch.object(testflight.subprocess, "run", side_effect=AssertionError("Signing must wait for share configuration")):
                        with self.assertRaisesRegex(ValueError, "Share extension signing is not configured"):
                            testflight.prepare(directory, incomplete)
                self.assertEqual(list(directory.iterdir()), [])

    def test_valid_profile_produces_manual_export_for_exact_app(self):
        options = self.validate()
        self.assertEqual(options['method'], 'app-store-connect')
        self.assertEqual(options['destination'], 'export')
        self.assertEqual(options['signingStyle'], 'manual')
        self.assertEqual(options['teamID'], self.config['team_id'])
        self.assertEqual(options['provisioningProfiles'], {
            self.config['bundle_id']: self.config['profile_uuid']})
        self.assertEqual(options['signingCertificate'], hashlib.sha1(self.cert).hexdigest().upper())
        self.assertFalse(options['manageAppVersionAndBuildNumber'])

    def test_modified_profile_bytes_are_rejected(self):
        with self.assertRaises(ValueError):
            self.validate(raw=self.raw + b'tampered')

    def test_wrong_identity_and_non_store_profiles_are_rejected(self):
        changes = [
            ('TeamIdentifier', ['OTHERTEAM1']),
            ('ApplicationIdentifierPrefix', ['OTHERTEAM1']),
            ('Name', 'Another Profile'),
            ('UUID', '11111111-1111-1111-1111-111111111111'),
            ('Platform', ['OSX']),
            ('DeveloperCertificates', [b'other certificate']),
            ('DeveloperCertificates', [self.cert, b'another certificate']),
            ('ProvisionedDevices', ['device-udid']),
            ('ProvisionsAllDevices', True),
            ('CreationDate', self.now + timedelta(seconds=1)),
            ('ExpirationDate', self.now),
        ]
        for name, value in changes:
            with self.subTest(field=name, value=value):
                profile = copy.deepcopy(self.profile)
                profile[name] = value
                with self.assertRaises(ValueError):
                    self.validate(profile)

    def test_distribution_entitlements_are_required(self):
        changes = [
            ('application-identifier', 'YU2A5J5978.other.app'),
            ('com.apple.developer.team-identifier', 'OTHERTEAM1'),
            ('get-task-allow', True),
            ('get-task-allow', 'false'),
            ('beta-reports-active', False),
        ]
        for name, value in changes:
            with self.subTest(field=name):
                profile = copy.deepcopy(self.profile)
                profile['Entitlements'][name] = value
                with self.assertRaises(ValueError):
                    self.validate(profile)

    def test_reruns_get_distinct_valid_build_numbers(self):
        self.assertEqual(testflight.build_number('3', '1'), '3.1')
        self.assertEqual(testflight.build_number('3', '2'), '3.2')
        for run, attempt in [('0', '1'), ('1; echo secret', '1'), ('10000', '1'), ('1', '100'), ('1', '0'), ('01', '1')]:
            with self.subTest(run=run, attempt=attempt):
                with self.assertRaises(ValueError):
                    testflight.build_number(run, attempt)

    def test_exported_app_must_match_and_keep_online_services_disabled(self):
        info = {'CFBundleIdentifier': self.config['bundle_id'],
                'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '3.1',
                'UIDeviceFamily': [1]}
        testflight.validate_app_info(info, self.config, '3.1')
        for field, value in [('CFBundleIdentifier', 'other.app'), ('CFBundleVersion', '3.0'),
                             ('CFBundleShortVersionString', '1.0'),
                             ('GoogleNavigationAPIKey', 'live-key'), ('GoogleAllowedBundleID', 'enabled'),
                             ('GoogleQuotasVerifiedUntil', '2027-01-01'), ('GeocodingProxyURL', 'https://example.com')]:
            with self.subTest(field=field):
                changed = dict(info, **{field: value})
                with self.assertRaises(ValueError):
                    testflight.validate_app_info(changed, self.config, '3.1')

    def test_exported_app_rejects_unintended_ipad_support(self):
        info = {'CFBundleIdentifier': self.config['bundle_id'],
                'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '3.1',
                'UIDeviceFamily': [1]}
        testflight.validate_app_info(info, self.config, '3.1')
        for family in ([1, 2], [2], [], None):
            with self.subTest(family=family), self.assertRaisesRegex(ValueError, 'iPhone'):
                testflight.validate_app_info(dict(info, UIDeviceFamily=family), self.config, '3.1')

    def test_failed_apple_validation_with_zero_exit_never_starts_upload(self):
        calls = []
        def rejected(command, **kwargs):
            calls.append(command)
            return subprocess.CompletedProcess(command, 0,
                'VERIFY FAILED with 1 error\nFailed to validate package.\n')
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, 'validate'):
            testflight.deliver_to_apple(pathlib.Path('app.ipa'),
                dict(self.config, issuer_id='issuer'), rejected)
        self.assertEqual(len(calls), 1)
        self.assertIn('--validate-app', calls[0])

    def test_apple_delivery_requires_positive_confirmation_for_both_operations(self):
        validate_ok = 'VERIFY SUCCEEDED with no errors\n'
        upload_ok = 'UPLOAD SUCCEEDED with no errors\n'
        cases = [
            ([(0, validate_ok), (0, upload_ok)], True),
            ([(0, 'No errors validating archive at app.ipa\n'),
              (0, 'No errors uploading archive at app.ipa\n')], True),
            ([(0, validate_ok), (0, 'UPLOAD FAILED with 1 error\n')], False),
            ([(0, validate_ok), (0, 'Running altool...\n')], False),
            ([(0, validate_ok), (1, upload_ok)], False),
            ([(0, validate_ok), (0, upload_ok + 'ERROR: delivery rejected\n')], False),
        ]
        for results, accepted in cases:
            with self.subTest(results=results), contextlib.redirect_stdout(io.StringIO()):
                calls = []
                def run(command, **kwargs):
                    code, output = results[len(calls)]
                    calls.append(command)
                    return subprocess.CompletedProcess(command, code, output)
                if accepted:
                    testflight.deliver_to_apple(pathlib.Path('app.ipa'),
                        dict(self.config, issuer_id='issuer'), run)
                else:
                    with self.assertRaises(ValueError):
                        testflight.deliver_to_apple(pathlib.Path('app.ipa'),
                            dict(self.config, issuer_id='issuer'), run)
                self.assertEqual(len(calls), 2)
                self.assertIn('--validate-app', calls[0])
                self.assertIn('--upload-app', calls[1])

    def test_missing_or_invalid_secrets_fail_without_echoing_values(self):
        good = {
            'APPLE_CERTIFICATE_BASE64': base64.b64encode(b'p12').decode(),
            'APPLE_PROVISIONING_PROFILE_BASE64': base64.b64encode(self.raw).decode(),
            'APP_STORE_CONNECT_KEY_BASE64': base64.b64encode(b'private-key').decode(),
            'APPLE_CERTIFICATE_PASSWORD': 'password-sentinel',
        }
        with tempfile.TemporaryDirectory() as temp:
            testflight.write_assets(good, pathlib.Path(temp), self.config)
            self.assertEqual((pathlib.Path(temp) / 'private_keys' / 'AuthKey_89788L8TG2.p8').read_bytes(), b'private-key')
        for name in good:
            for value in ['', 'not-base64-secret-sentinel' if name.endswith('BASE64') else '']:
                with self.subTest(name=name, value=value), tempfile.TemporaryDirectory() as temp:
                    changed = dict(good, **{name: value})
                    with self.assertRaises(ValueError) as error:
                        testflight.write_assets(changed, pathlib.Path(temp), self.config)
                    self.assertNotIn('secret-sentinel', str(error.exception))
                    self.assertEqual(list(pathlib.Path(temp).iterdir()), [])

    def test_upload_only_key_requires_verified_public_identity_and_no_signing_assets(self):
        raw = b'fixture-upload-private-key'
        public = b'fixture-upload-public-key'
        self.config['api_public_key_sha256'] = hashlib.sha256(public).hexdigest()
        env = {'APP_STORE_CONNECT_KEY_BASE64': base64.b64encode(raw).decode()}
        with tempfile.TemporaryDirectory() as temp:
            upload = pathlib.Path(temp) / 'upload'
            result = subprocess.CompletedProcess(['openssl'], 0, stdout=public)
            with patch.object(testflight.subprocess, 'run', return_value=result) as run:
                testflight.prepare_upload_key(upload, self.config, env)
            run.assert_called_once()
            self.assertEqual(run.call_args.kwargs['input'], raw)
            self.assertEqual((upload / 'private_keys' / 'AuthKey_89788L8TG2.p8').read_bytes(), raw)
            self.assertEqual([p.name for p in upload.iterdir()], ['private_keys'])
        for encoded, expected in [('', 'Missing'), ('invalid-key', 'Invalid')]:
            with self.subTest(encoded=encoded), tempfile.TemporaryDirectory() as temp:
                upload = pathlib.Path(temp) / 'upload'
                with self.assertRaisesRegex(ValueError, expected):
                    testflight.prepare_upload_key(upload, self.config,
                                                  {'APP_STORE_CONNECT_KEY_BASE64': encoded})
                self.assertFalse(upload.exists())
        with tempfile.TemporaryDirectory() as temp:
            upload = pathlib.Path(temp) / 'upload'
            result = subprocess.CompletedProcess(['openssl'], 0, stdout=b'wrong-public-key')
            with patch.object(testflight.subprocess, 'run', return_value=result):
                with self.assertRaisesRegex(ValueError, 'differs from the key verified'):
                    testflight.prepare_upload_key(upload, self.config, env)
            self.assertFalse(upload.exists())

    def test_exported_ipa_is_checked_as_an_archive(self):
        prefix = 'Payload/ApartmentFinder.app/'
        entries = {
            prefix + 'Info.plist': plistlib.dumps({
                'CFBundleIdentifier': self.config['bundle_id'],
                'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '3.1',
                'UIDeviceFamily': [1]}),
            prefix + 'embedded.mobileprovision': self.raw,
            prefix + 'catalog.json': b'catalog',
            prefix + 'locations.geojson': b'locations',
            prefix + 'paths.geojson': b'paths',
        }
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'app.ipa'
            def package(values):
                with zipfile.ZipFile(path, 'w') as archive:
                    for name, value in values.items():
                        archive.writestr(name, value)
            package(entries)
            result = testflight.inspect_ipa(path, self.config, '3.1')
            self.assertEqual(result['ipa_sha256'], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual(result['resources_sha256']['catalog.json'], hashlib.sha256(b'catalog').hexdigest())
            changed = dict(entries)
            changed[prefix + 'embedded.mobileprovision'] = b'wrong-profile'
            package(changed)
            with self.assertRaises(ValueError):
                testflight.inspect_ipa(path, self.config, '3.1')
            package(dict(entries, **{'Payload/Other.app/Info.plist': b'other'}))
            with self.assertRaises(ValueError):
                testflight.inspect_ipa(path, self.config, '3.1')
            changed = dict(entries)
            del changed[prefix + 'catalog.json']
            package(changed)
            with self.assertRaises(KeyError):
                testflight.inspect_ipa(path, self.config, '3.1')

    def test_cleanup_removes_files_even_when_keychain_restore_fails(self):
        with tempfile.TemporaryDirectory() as temp:
            runner_temp = pathlib.Path(temp)
            signing = runner_temp / 'apartmentfinder-signing'
            signing.mkdir()
            (signing / 'original-keychains.txt').write_text('"original.keychain-db"')
            (signing / 'signing.keychain-db').write_bytes(b'test-keychain')
            (signing / 'private-key').write_bytes(b'private-key-fixture')
            user_home = runner_temp / 'home'
            paths = [user_home / item / (self.config['profile_uuid'] + '.mobileprovision')
                     for item in ('Library/Developer/Xcode/UserData/Provisioning Profiles',
                                  'Library/MobileDevice/Provisioning Profiles')]
            for path in paths:
                path.parent.mkdir(parents=True)
                path.write_bytes(self.raw)
                (path.parent / 'unrelated.mobileprovision').write_bytes(b'unrelated')
            calls = []
            def failed_security(command, **kwargs):
                calls.append(command)
                return subprocess.CompletedProcess(command, 1)
            with self.assertRaisesRegex(ValueError, 'keychain'):
                testflight.cleanup_signing(signing, runner_temp, user_home,
                                           self.config['profile_uuid'], failed_security)
            self.assertFalse(signing.exists())
            self.assertTrue(all(not path.exists() for path in paths))
            self.assertTrue(all((path.parent / 'unrelated.mobileprovision').exists() for path in paths))
            self.assertEqual([call[1] for call in calls], ['list-keychains', 'delete-keychain'])

    def test_cleanup_refuses_paths_outside_the_runner_signing_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            unrelated = root / 'unrelated'
            unrelated.mkdir()
            (unrelated / 'keep').write_bytes(b'keep')
            with self.assertRaises(ValueError):
                testflight.cleanup_signing(unrelated, root, root / 'home', self.config['profile_uuid'])
            self.assertTrue((unrelated / 'keep').exists())

    def test_shared_profiles_require_the_exact_app_group(self):
        self.config['app_group'] = 'group.dev.galaxybigbird.ApartmentFinder'
        for groups in (None, [], ['group.wrong'], [self.config['app_group'], 'group.unexpected']):
            with self.subTest(groups=groups):
                profile = copy.deepcopy(self.profile)
                if groups is not None:
                    profile['Entitlements']['com.apple.security.application-groups'] = groups
                with self.assertRaises(ValueError):
                    self.validate(profile)
        self.profile['Entitlements']['com.apple.security.application-groups'] = [self.config['app_group']]
        self.validate()

    def test_share_extension_must_be_present_and_match_profile_version_and_group(self):
        share_raw = b'signed-share-profile-fixture'
        self.config['app_group'] = 'group.dev.galaxybigbird.ApartmentFinder'
        self.config['share_extension'] = {
            'bundle_id': self.config['bundle_id'] + '.Share',
            'profile_name': 'ApartmentFinder Share TestFlight',
            'profile_uuid': '11111111-1111-4111-8111-111111111111',
            'profile_sha256': hashlib.sha256(share_raw).hexdigest(),
        }
        main = 'Payload/ApartmentFinder.app/'
        share = main + 'PlugIns/ApartmentFinderShare.appex/'
        info = {'CFBundleIdentifier': self.config['bundle_id'],
                'CFBundleShortVersionString': '0.1.0', 'CFBundleVersion': '3.1',
                'UIDeviceFamily': [1]}
        extension_info = dict(info, CFBundleIdentifier=self.config['share_extension']['bundle_id'],
            NSExtension={'NSExtensionPointIdentifier': 'com.apple.share-services',
                         'NSExtensionAttributes': {'NSExtensionActivationRule':
                            {'NSExtensionActivationSupportsFileWithMaxCount': 1}}})
        entries = {main + 'Info.plist': plistlib.dumps(info), main + 'embedded.mobileprovision': self.raw,
                   main + 'catalog.json': b'catalog', main + 'locations.geojson': b'locations', main + 'paths.geojson': b'paths'}
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / 'app.ipa'
            def package(values):
                with zipfile.ZipFile(path, 'w') as archive:
                    for name, data in values.items():
                        archive.writestr(name, data)
            package(entries)
            with self.assertRaises(ValueError):
                testflight.inspect_ipa(path, self.config, '3.1')
            entries.update({share + 'Info.plist': plistlib.dumps(extension_info),
                            share + 'embedded.mobileprovision': share_raw, share + 'catalog.json': b'catalog'})
            package(entries)
            testflight.inspect_ipa(path, self.config, '3.1')
            for filename, data in [(share + 'embedded.mobileprovision', b'wrong'),
                                   (share + 'catalog.json', b'wrong'),
                                   (share + 'Info.plist', plistlib.dumps(dict(extension_info, CFBundleVersion='2.1')))]:
                with self.subTest(filename=filename):
                    package(dict(entries, **{filename:data}))
                    with self.assertRaises(ValueError):
                        testflight.inspect_ipa(path, self.config, '3.1')
            package(dict(entries, **{main + 'PlugIns/Other.appex/Info.plist': b'other'}))
            with self.assertRaises(ValueError):
                testflight.inspect_ipa(path, self.config, '3.1')

    def test_both_profiles_are_required_before_any_signing_assets_are_written(self):
        self.config['share_extension'] = {'bundle_id': self.config['bundle_id'] + '.Share'}
        env = {'APPLE_CERTIFICATE_BASE64': base64.b64encode(b'p12').decode(),
               'APPLE_PROVISIONING_PROFILE_BASE64': base64.b64encode(self.raw).decode(),
               'APP_STORE_CONNECT_KEY_BASE64': base64.b64encode(b'key').decode(),
               'APPLE_CERTIFICATE_PASSWORD': 'fixture'}
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp)
            with self.assertRaises(ValueError):
                testflight.write_assets(env, path, self.config)
            self.assertEqual(list(path.iterdir()), [])
            env['APPLE_SHARE_PROVISIONING_PROFILE_BASE64'] = base64.b64encode(b'share-profile').decode()
            testflight.write_assets(env, path, self.config)
            self.assertEqual((path / 'share-profile.mobileprovision').read_bytes(), b'share-profile')

    def test_actual_signed_entitlements_require_group_and_application_identity(self):
        self.config['app_group'] = 'group.dev.galaxybigbird.ApartmentFinder'
        entitlements = dict(self.profile['Entitlements'])
        entitlements['com.apple.security.application-groups'] = [self.config['app_group']]
        testflight.validate_signed_entitlements(entitlements, self.config)
        for key, value in [('com.apple.security.application-groups', []),
                           ('application-identifier', 'YU2A5J5978.other.app'),
                           ('get-task-allow', True)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                testflight.validate_signed_entitlements(dict(entitlements, **{key:value}), self.config)

    def test_cleanup_removes_both_installed_profiles_and_preserves_others(self):
        ids = [self.config['profile_uuid'], '11111111-1111-4111-8111-111111111111']
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            signing = root / 'apartmentfinder-signing'
            signing.mkdir()
            home = root / 'home'
            paths = []
            for folder in ('Library/Developer/Xcode/UserData/Provisioning Profiles',
                           'Library/MobileDevice/Provisioning Profiles'):
                directory = home / folder
                directory.mkdir(parents=True)
                for identifier in ids:
                    path = directory / (identifier + '.mobileprovision')
                    path.write_bytes(b'fixture')
                    paths.append(path)
                (directory / 'keep.mobileprovision').write_bytes(b'keep')
            testflight.cleanup_signing(signing, root, home, ids)
            self.assertTrue(all(not path.exists() for path in paths))
            self.assertEqual(len(list(home.rglob('keep.mobileprovision'))), 2)


if __name__ == '__main__':
    unittest.main()
