"""Preflight checks for the private TestFlight workflow. Never print secret values."""

import argparse
import base64
import binascii
import hashlib
import json
import os
import pathlib
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import uuid
import zipfile
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[1]
ONLINE_SETTINGS = ('GoogleNavigationAPIKey', 'GoogleAllowedBundleID',
                   'GoogleQuotasVerifiedUntil', 'GeocodingProxyURL')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def build_number(run, attempt):
    require(re.fullmatch(r'[1-9][0-9]{0,3}', run) is not None,
            'Run number must be 1 through 9999.')
    require(re.fullmatch(r'[1-9][0-9]?', attempt) is not None,
            'Run attempt must be 1 through 99.')
    return run + '.' + attempt


def utc(value):
    require(isinstance(value, datetime), 'Profile validity date is missing.')
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def profile_configs(config):
    profiles = [config]
    if config.get('share_extension'):
        profiles.append(dict(config, **config['share_extension']))
    return profiles


def validate_signed_entitlements(entitlements, config):
    require(entitlements.get('application-identifier') == config['team_id'] + '.' + config['bundle_id'],
            'Wrong signed application identifier.')
    require(entitlements.get('com.apple.developer.team-identifier') == config['team_id'],
            'Wrong signed entitlement team.')
    require(entitlements.get('get-task-allow') is False, 'Development signing is not allowed.')
    if config.get('app_group'):
        require(entitlements.get('com.apple.security.application-groups') == [config['app_group']],
                'The shared manifest App Group is missing or unexpected.')


def validate_profile(profile, raw, config, now):
    # The exact signed CMS bytes were independently verified against Apple's root
    # on the owner's PC. Pinning that digest prevents substitution on the runner.
    require(hashlib.sha256(raw).hexdigest() == config['profile_sha256'],
            'Provisioning profile differs from the locally verified file.')
    team = config['team_id']
    require(profile.get('Name') == config['profile_name'], 'Wrong profile name.')
    require(profile.get('UUID') == config['profile_uuid'], 'Wrong profile UUID.')
    require(profile.get('TeamIdentifier') == [team], 'Wrong profile team.')
    require(profile.get('ApplicationIdentifierPrefix') == [team], 'Wrong profile prefix.')
    require('iOS' in profile.get('Platform', []), 'Profile does not support iOS.')
    require('ProvisionedDevices' not in profile and not profile.get('ProvisionsAllDevices', False),
            'Device-limited or enterprise profiles cannot be used here.')
    require(utc(profile.get('CreationDate')) <= utc(now) < utc(profile.get('ExpirationDate')),
            'Provisioning profile is expired or not yet valid.')
    entitlements = profile.get('Entitlements', {})
    require(entitlements.get('application-identifier') == team + '.' + config['bundle_id'],
            'Wrong profile application identifier.')
    require(entitlements.get('com.apple.developer.team-identifier') == team, 'Wrong entitlement team.')
    require(entitlements.get('get-task-allow') is False, 'Development signing is not allowed.')
    require(entitlements.get('beta-reports-active') is True, 'Profile is not enabled for TestFlight.')
    validate_signed_entitlements(entitlements, config)
    certificates = profile.get('DeveloperCertificates', [])
    require(len(certificates) == 1 and hashlib.sha256(certificates[0]).hexdigest() == config['certificate_sha256'],
            'Distribution certificate does not match the verified identity.')
    return {
        'method': 'app-store-connect', 'destination': 'export',
        'signingStyle': 'manual', 'teamID': team,
        'signingCertificate': hashlib.sha1(certificates[0]).hexdigest().upper(),
        'provisioningProfiles': {config['bundle_id']: config['profile_uuid']},
        'manageAppVersionAndBuildNumber': False,
        'stripSwiftSymbols': True, 'uploadSymbols': True,
    }


def validate_app_info(info, config, expected_build):
    require(info.get('CFBundleIdentifier') == config['bundle_id'], 'Wrong exported app identifier.')
    require(info.get('CFBundleShortVersionString') == config['marketing_version'], 'Wrong exported app version.')
    require(info.get('CFBundleVersion') == expected_build, 'Wrong exported build number.')
    require(info.get('UIDeviceFamily') == [1], 'Exported app must target iPhone only.')
    require(all(info.get(name, '') == '' for name in ONLINE_SETTINGS),
            'Online services were enabled without the required cost-control setup.')


def deliver_to_apple(ipa, config, run=subprocess.run):
    # Xcode 26.2 altool can return zero even when Apple rejects the package.
    # Require positive delivery output as well as a successful process exit.
    confirmations = {
        'validate': r'\b(?:VERIFY|VALIDATION) SUCCEEDED\b|\bNo errors validating\b',
        'upload': r'\bUPLOAD SUCCEEDED\b|\bNo errors uploading\b',
    }
    failures = r'\b(?:VERIFY|VALIDATION|UPLOAD) FAILED\b|\b(?:ERROR|FATAL):|\bFailed to (?:validate|upload) package\b'
    for operation, confirmation in confirmations.items():
        result = run(['xcrun', 'altool', '--' + operation + '-app', '--file', str(ipa),
                      '--type', 'ios', '--apiKey', config['api_key_id'],
                      '--apiIssuer', config['issuer_id']],
                     check=False, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                     text=True, timeout=600)
        output = result.stdout or ''
        print(output[-16000:], flush=True)
        require(result.returncode == 0 and not re.search(failures, output, re.IGNORECASE),
                'Apple ' + operation + ' failed; the build was not confirmed as uploaded.')
        require(re.search(confirmation, output, re.IGNORECASE) is not None,
                'Apple ' + operation + ' returned no positive confirmation.')


def write_assets(env, directory, config):
    require(env.get('APPLE_CERTIFICATE_PASSWORD', '') != '', 'Missing APPLE_CERTIFICATE_PASSWORD.')
    names = {
        'APPLE_CERTIFICATE_BASE64': directory / 'distribution.p12',
        'APPLE_PROVISIONING_PROFILE_BASE64': directory / 'profile.mobileprovision',
        'APP_STORE_CONNECT_KEY_BASE64': directory / 'private_keys' / ('AuthKey_' + config['api_key_id'] + '.p8'),
    }
    if config.get('share_extension'):
        names['APPLE_SHARE_PROVISIONING_PROFILE_BASE64'] = directory / 'share-profile.mobileprovision'
    decoded = {}
    for name, destination in names.items():
        try:
            value = base64.b64decode(env.get(name, ''), validate=True)
        except (ValueError, binascii.Error):
            raise ValueError('Invalid base64 in ' + name + '.') from None
        require(bool(value), 'Missing ' + name + '.')
        decoded[destination] = value
    for destination, value in decoded.items():
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with os.fdopen(os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'wb') as handle:
            handle.write(value)


def prepare_upload_key(directory, config, env=os.environ):
    require(re.fullmatch(r'[A-Z0-9]{10}', config['api_key_id']) is not None,
            'Invalid API key identifier.')
    try:
        raw = base64.b64decode(env.get('APP_STORE_CONNECT_KEY_BASE64', ''), validate=True)
    except (ValueError, binascii.Error):
        raise ValueError('Invalid App Store Connect key encoding.') from None
    require(bool(raw), 'Missing App Store Connect upload key.')
    public_key = subprocess.run(['openssl', 'pkey', '-pubout', '-outform', 'DER'],
                                input=raw, check=True, capture_output=True).stdout
    require(hashlib.sha256(public_key).hexdigest() == config['api_public_key_sha256'],
            'Upload key differs from the key verified with Apple.')
    directory.mkdir(mode=0o700)
    keys = directory / 'private_keys'
    keys.mkdir(mode=0o700)
    destination = keys / ('AuthKey_' + config['api_key_id'] + '.p8')
    with os.fdopen(os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), 'wb') as handle:
        handle.write(raw)


def prepare(directory, config):
    require(sys.platform == 'darwin', 'Signing preparation must run on the macOS runner.')
    require(config.get('app_group') and config.get('share_extension'),
            'Share extension signing is not configured; pin both verified App Group profiles before upload.')
    require(re.fullmatch(r'[A-Z0-9]{10}', config['api_key_id']) is not None, 'Invalid API key identifier.')
    require(str(uuid.UUID(config['issuer_id'])) == config['issuer_id'], 'Invalid Issuer ID.')
    require(str(uuid.UUID(config['profile_uuid'])) == config['profile_uuid'], 'Invalid profile UUID.')
    version = build_number(os.environ.get('GITHUB_RUN_NUMBER', ''), os.environ.get('GITHUB_RUN_ATTEMPT', ''))
    write_assets(os.environ, directory, config)
    options = None
    for item, filename in zip(profile_configs(config), ('profile.mobileprovision', 'share-profile.mobileprovision')):
        require(str(uuid.UUID(item['profile_uuid'])) == item['profile_uuid'], 'Invalid profile UUID.')
        raw = (directory / filename).read_bytes()
        require(hashlib.sha256(raw).hexdigest() == item['profile_sha256'], 'Provisioning profile hash mismatch.')
        decoded = subprocess.run(['security', 'cms', '-D', '-i', str(directory / filename)],
                                 check=True, capture_output=True).stdout
        validated = validate_profile(plistlib.loads(decoded), raw, item, datetime.now(timezone.utc))
        if options is None:
            options = validated
        else:
            require(validated['signingCertificate'] == options['signingCertificate'], 'Profiles use different signing identities.')
            options['provisioningProfiles'].update(validated['provisioningProfiles'])
    key_path = directory / 'private_keys' / ('AuthKey_' + config['api_key_id'] + '.p8')
    public_key = subprocess.run(['openssl', 'pkey', '-in', str(key_path), '-pubout', '-outform', 'DER'],
                                check=True, capture_output=True).stdout
    require(hashlib.sha256(public_key).hexdigest() == config['api_public_key_sha256'],
            'Upload key differs from the key verified with Apple.')
    (directory / 'ExportOptions.plist').write_bytes(plistlib.dumps(options))
    values = {
        'AF_PROFILE_UUID': config['profile_uuid'],
        'AF_PROFILE_NAME': config['profile_name'],
        'AF_SHARE_PROFILE_UUID': config.get('share_extension', {}).get('profile_uuid', ''),
        'AF_CERTIFICATE_SHA1': options['signingCertificate'],
        'AF_API_KEY_ID': config['api_key_id'],
        'AF_ISSUER_ID': config['issuer_id'],
        'AF_BUILD_NUMBER': version,
    }
    (directory / 'settings.sh').write_text(''.join(name + '=' + shlex.quote(value) + '\n'
                                                  for name, value in values.items()), encoding='utf-8')
    print('Verified signing inputs and prepared build ' + version + '.')


def inspect_ipa(path, config, expected_build):
    prefix = 'Payload/ApartmentFinder.app/'
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        require(len(names) == len(set(names)), 'IPA contains duplicate entries.')
        apps = {name.split('/')[1] for name in names
                if name.startswith('Payload/') and len(name.split('/')) > 2 and name.split('/')[1].endswith('.app')}
        require(apps == {'ApartmentFinder.app'}, 'IPA contains an unexpected application.')
        info = plistlib.loads(archive.read(prefix + 'Info.plist'))
        validate_app_info(info, config, expected_build)
        require(hashlib.sha256(archive.read(prefix + 'embedded.mobileprovision')).hexdigest() == config['profile_sha256'],
                'Exported app contains a different provisioning profile.')
        extensions = {name[len(prefix + 'PlugIns/'):].split('/')[0] for name in names
                      if name.startswith(prefix + 'PlugIns/') and '.appex/' in name}
        expected_extensions = {'ApartmentFinderShare.appex'} if config.get('share_extension') else set()
        require(extensions == expected_extensions, 'IPA is missing the share extension or contains an unexpected extension.')
        legacy_resources = ('catalog.json', 'locations.geojson', 'paths.geojson')
        public_resources = ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson')
        has_legacy = any(prefix + name in names for name in legacy_resources)
        has_public = any(prefix + name in names for name in public_resources)
        require(not (has_legacy and has_public), 'IPA mixes public and legacy resource families.')
        resource_names = public_resources if has_public else legacy_resources
        if has_public or prefix + 'known-addresses.json' in names:
            resource_names += ('known-addresses.json',)
        if config.get('share_extension'):
            extension = dict(config, **config['share_extension'])
            share = prefix + 'PlugIns/ApartmentFinderShare.appex/'
            share_info = plistlib.loads(archive.read(share + 'Info.plist'))
            validate_app_info(share_info, extension, expected_build)
            definition = share_info.get('NSExtension', {})
            require(definition.get('NSExtensionPointIdentifier') == 'com.apple.share-services',
                    'Exported extension is not an iOS Share extension.')
            rule = definition.get('NSExtensionAttributes', {}).get('NSExtensionActivationRule', {})
            require(isinstance(rule, dict) and rule.get('NSExtensionActivationSupportsFileWithMaxCount') == 1,
                    'Share extension does not accept a manifest file.')
            require(hashlib.sha256(archive.read(share + 'embedded.mobileprovision')).hexdigest() == extension['profile_sha256'],
                    'Exported extension contains a different provisioning profile.')
            forbidden_resources = legacy_resources + public_resources if has_public else public_resources
            require(not any(share + name in names for name in forbidden_resources),
                    'Share extension contains unexpected catalog or GeoJSON resources.')
            shared_resource = 'known-addresses.json' if has_public else 'catalog.json'
            require(archive.read(share + shared_resource) == archive.read(prefix + shared_resource),
                    'Share extension known-address index differs from the app.' if has_public
                    else 'Share extension community catalog differs from the app.')
        resources = {name: hashlib.sha256(archive.read(prefix + name)).hexdigest()
                     for name in resource_names}
    return {'bundle_id': config['bundle_id'], 'team_id': config['team_id'],
            'version': config['marketing_version'], 'build_number': expected_build,
            'ipa_sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'resources_sha256': resources}


def cleanup_signing(directory, runner_temp, user_home, profile_uuid, run=subprocess.run):
    expected = runner_temp.resolve() / 'apartmentfinder-signing'
    require(not directory.is_symlink() and directory.resolve() == expected,
            'Refusing cleanup outside the runner signing directory.')
    if not directory.exists():
        return
    failures = []
    original = directory / 'original-keychains.txt'
    if original.exists():
        try:
            keychains = shlex.split(original.read_text())
            result = run(['security', 'list-keychains', '-d', 'user', '-s', *keychains],
                         check=False, capture_output=True)
            if result.returncode:
                failures.append('restore keychain search list')
        except (OSError, ValueError):
            failures.append('read or restore keychain search list')
    keychain = directory / 'signing.keychain-db'
    if keychain.exists():
        try:
            result = run(['security', 'delete-keychain', str(keychain)], check=False, capture_output=True)
            if result.returncode:
                failures.append('delete signing keychain')
        except OSError:
            failures.append('delete signing keychain')
    profile_ids = [profile_uuid] if isinstance(profile_uuid, str) else profile_uuid
    for identifier in profile_ids:
        try:
            require(str(uuid.UUID(identifier)) == identifier, 'Invalid profile UUID.')
        except (ValueError, TypeError, AttributeError):
            failures.append('identify installed provisioning profile')
            continue
        for folder in ('Library/Developer/Xcode/UserData/Provisioning Profiles',
                       'Library/MobileDevice/Provisioning Profiles'):
            try:
                (user_home / folder / (identifier + '.mobileprovision')).unlink(missing_ok=True)
            except OSError:
                failures.append('remove installed provisioning profile')
    try:
        shutil.rmtree(directory)
    except OSError:
        failures.append('remove temporary signing directory')
    require(not failures, 'Signing cleanup failed to ' + ', '.join(failures) + '.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare')
    prep.add_argument('directory', type=pathlib.Path)
    upload_key = commands.add_parser('prepare-upload-key')
    upload_key.add_argument('directory', type=pathlib.Path)
    check = commands.add_parser('check-ipa')
    check.add_argument('ipa', type=pathlib.Path)
    check.add_argument('build_number')
    entitlements = commands.add_parser('check-entitlements')
    entitlements.add_argument('plist', type=pathlib.Path)
    entitlements.add_argument('bundle_id')
    deliver = commands.add_parser('deliver')
    deliver.add_argument('ipa', type=pathlib.Path)
    cleanup = commands.add_parser('cleanup')
    cleanup.add_argument('directory', type=pathlib.Path)
    args = parser.parse_args()
    config = json.loads((ROOT / 'Config' / 'TestFlight.json').read_text(encoding='utf-8'))
    try:
        if args.command == 'prepare':
            prepare(args.directory, config)
        elif args.command == 'prepare-upload-key':
            require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true',
                    'Upload key preparation requires the macOS runner.')
            prepare_upload_key(args.directory, config)
            print('Verified private App Store Connect upload key.')
        elif args.command == 'check-entitlements':
            matches = [item for item in profile_configs(config) if item['bundle_id'] == args.bundle_id]
            require(len(matches) == 1, 'Unexpected signed bundle.')
            validate_signed_entitlements(plistlib.loads(args.plist.read_bytes()), matches[0])
            print('Verified signed manifest-sharing entitlements.')
        elif args.command == 'deliver':
            require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true',
                    'Apple delivery requires the macOS runner.')
            deliver_to_apple(args.ipa, config)
        elif args.command == 'cleanup':
            require(sys.platform == 'darwin' and os.environ.get('GITHUB_ACTIONS') == 'true'
                    and bool(os.environ.get('RUNNER_TEMP')), 'Cleanup requires the macOS runner.')
            cleanup_signing(args.directory, pathlib.Path(os.environ['RUNNER_TEMP']),
                            pathlib.Path.home(), [item['profile_uuid'] for item in profile_configs(config)])
        else:
            result = inspect_ipa(args.ipa, config, args.build_number)
            result['commit'] = os.environ.get('GITHUB_SHA', '')
            print(json.dumps(result, indent=2))
    except subprocess.CalledProcessError as error:
        sys.exit('Signing preflight command failed: ' + str(error.cmd[0]))
    except subprocess.TimeoutExpired:
        sys.exit('Apple delivery timed out; check App Store Connect before retrying.')
    except (ValueError, KeyError, OSError, zipfile.BadZipFile) as error:
        sys.exit('TestFlight preflight failed: ' + str(error))


if __name__ == '__main__':
    main()
