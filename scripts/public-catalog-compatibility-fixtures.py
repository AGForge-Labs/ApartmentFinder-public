#!/usr/bin/env python3
"""Prepare provisional, credential-free public compatibility fixtures offline.

This is neither a set publisher nor a Swift reader contract. It copies raw
public resources, records finite baseline research membership and keeps the
bundle identity separate from an actual schema-1 feed identity.
"""
import argparse
from collections import defaultdict
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

FORMAT = 'ApartmentFinder-offline-public-compatibility-v0'
FILES = ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson')
LIMITS = dict(zip(FILES, (3_000_000, 64_000_000, 16_000_000)))
PROFILE = {
    'public-catalog.py': '214c362a9fd4636179ad895aa6e654466c7eb90aa5afd3938b1be8d1b280c583',
    'public-catalog-feed.py': 'af823dca006e71219d7b0f0b9745726497e845bf8477e531466d320b96b3aea6',
    'reviewed-directory-features-20261023.json': 'ef44cf26b94a929aa51d40a3613a67532f3df181bf14b219a7ef030be1d41b1b',
    'reviewed-local28-features-20261023.json': '829a8e0f1804ae6548a521cf1d667ae051ba3f7cbf6c1fc92b473207a3e1303f',
    'reviewed-manhattan12-features-20261023.json': 'b1699d79c3fecba0cae5d454201b903bd381e583572f1dc59a55a62c908a8d36',
    'reviewed-sourceareas30-features-20261023.json': 'ae4b2ee9aa0880f69488558863b50f06dacb7cd2b33ab45add3b3b8763a32ff1',
    'reviewed-trend-confidence-features-20261026.json': '34a52840c3b69cadd1b181430867963d0859e1eec10e390cc85d043f1363faf6',
}
METADATA_LIMIT = 2_000_000
LOCALITY = r'(?i)(?:[,\.\r\n]+\s*(?:las\s+vegas|henderson)(?:[,\s.]+(?:nv|nevada))?(?:[,\s.]+\d{5}(?:-\d{4})?)?|[,\s.]+(?:las\s+vegas|henderson)[,\s.]+(?:(?:nv|nevada)(?:[,\s.]+\d{5}(?:-\d{4})?)?|\d{5}(?:-\d{4})?)|[,\s.]+(?:nv|nevada)(?:[,\s.]+\d{5}(?:-\d{4})?)?)[,\s.]*$'
ALIASES = dict(west='w', east='e', north='n', south='s', road='rd', street='st', avenue='ave',
               drive='dr', lane='ln', boulevard='blvd', court='ct', way='wy', parkway='pkwy')


def require(condition, message):
    if not condition: raise ValueError(message)


def digest(body):
    return hashlib.sha256(body).hexdigest()


def descriptor(body):
    return {'bytes': len(body), 'sha256': digest(body)}


def ordinary_local_path(path):
    if os.name == 'nt':
        def ordinary(value):
            return (not value.drive and not value.root) or (re.fullmatch('[A-Za-z]:', value.drive) is not None and value.root == os.sep)
        # Reject namespaces before metadata inspection: UNC/device prefixes,
        # extended paths, drive-relative and root-relative spellings cannot
        # enter one canonical overlap identity. Never strip device prefixes.
        require(ordinary(path) and ordinary(path.absolute()),
                'Unsupported Windows path namespace; use an ordinary local drive or relative path')
    return path


def plain(path, directory=False):
    path = ordinary_local_path(path)
    value = path.lstat()
    require(not stat.S_ISLNK(value.st_mode) and not getattr(value, 'st_file_attributes', 0) &
            getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0), 'Linked or reparse-point path prohibited')
    require(stat.S_ISDIR(value.st_mode) if directory else stat.S_ISREG(value.st_mode), 'Expected plain input')
    return value


def ancestors(path):
    path = ordinary_local_path(path)
    for p in (path, *path.parents):
        if os.path.lexists(p): plain(p, directory=True)


def read(path, maximum):
    ancestors(path.parent)
    before = plain(path)
    require(0 < before.st_size <= maximum, 'Input exceeds byte bound or is empty')
    with path.open('rb') as stream:
        opened = os.fstat(stream.fileno())
        require((opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino), 'Input changed during open')
        body = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
    require(len(body) == before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns,
            'Input changed while reading')
    require(len(body) <= maximum, 'Input exceeds byte bound')
    return body


def unique(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, 'Duplicate raw JSON key')
        value[key] = item
    return value


def reject_constant(_):
    raise ValueError('Non-finite JSON number')


def decode(body):
    return json.loads(body.decode('utf-8'), object_pairs_hook=unique, parse_constant=reject_constant)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode()


def exact_directory(path, names):
    ancestors(path)
    require({p.name for p in path.iterdir()} == set(names), 'Unexpected input files')


@contextmanager
def admission_profile(path):
    exact_directory(path, PROFILE)
    bodies = {name: read(path / name, 2_000_000) for name in PROFILE}
    require(all(digest(bodies[n]) == expected for n, expected in PROFILE.items()), 'Admission profile hash mismatch')
    # Load the validated bytes from a private snapshot, never execute a mutable
    # caller path after checking a different byte string.
    with tempfile.TemporaryDirectory(prefix='public-compatibility-profile-') as temporary:
        root = Path(temporary)
        for name, body in bodies.items(): (root / name).write_bytes(body)
        spec = importlib.util.spec_from_file_location('offline_compatibility_feed', root / 'public-catalog-feed.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        yield module


def admitted(bodies, feed):
    objects = {n: decode(bodies[n]) for n in FILES}
    feed.ADMISSION.validate_payload(*(objects[n] for n in FILES))
    version = objects[FILES[0]]['packVersion']
    require(all(objects[n]['packVersion'] == version for n in FILES), 'Public payload versions disagree')
    # The trusted legacy helper also enforces public field allowlists, source
    # joins, property qualification, all exact notes and its finite exceptions.
    return objects


def read_payload(path):
    return {n: read(path / n, LIMITS[n]) for n in FILES}


def validate_descriptors(value, bodies):
    require(type(value) is dict and set(value) == set(FILES), 'Exactly three public payload descriptors required')
    for n in FILES:
        d = value[n]
        require(type(d) is dict and set(d) == {'bytes', 'sha256'} and type(d['bytes']) is int and
                0 < d['bytes'] <= LIMITS[n] and type(d['sha256']) is str and
                re.fullmatch('[0-9a-f]{64}', d['sha256']) is not None, 'Invalid payload descriptor')
        require(d == descriptor(bodies[n]), 'Raw descriptor hash or length mismatch')


def source_edges(value):
    result = set()
    if isinstance(value, dict):
        for key, item in value.items():
            if key == 'sourceIDs' or key.endswith('SourceIDs'):
                require(type(item) is list and all(type(s) is str for s in item), 'Malformed source edge')
                result.update(item)
            elif key.endswith('SourceID'):
                require(type(item) is str, 'Malformed singular source edge')
                result.add(item)
            else: result.update(source_edges(item))
    elif isinstance(value, list):
        for item in value: result.update(source_edges(item))
    return result


def normalized(value):
    require(type(value) is str and value.isascii(), 'Draft identity port accepts ASCII inputs only')
    return value.strip().lower()


def address_key(value):
    text = re.sub(LOCALITY, '', normalized(value)).split(',')[0]
    text = re.sub(r'\s+\d{5}(-\d{4})?$', '', text)
    return ' '.join(ALIASES.get(token, token) for token in re.findall('[A-Za-z0-9]+', text))


def conservation(objects, manifest_body):
    catalog, locations, paths = (objects[n] for n in FILES)
    collections = {'communities': catalog['communities'], 'sources': catalog['sources'],
                   'points': locations['features'], 'paths': paths['features'],
                   'associations': catalog.get('unitBuildingAssociations', []),
                   'floorReferences': catalog.get('unitFloorReferences', [])}
    # This is a finite research fixture. It neither admits a new union nor
    # claims native parity for this source-derived ASCII identity calculation.
    groups = defaultdict(list)
    for feature in collections['points']:
        p = feature['properties']
        occurrence = (p.get('mapLabelOccurrenceID') or feature['id']) if p.get('referenceKind') == 'operatorMapBuildingArea' else None
        key = (p['communityID'], address_key(p['address']), normalized(p['building']), normalized(p['unit']),
               normalized(p['floor']), p['kind'], occurrence)
        groups[key].append(feature['id'])
    urls = defaultdict(list)
    for source in catalog['sources']: urls[source['url']].append(source['id'])
    edges = source_edges(objects)
    all_sources = {s['id'] for s in catalog['sources']}
    require(edges <= all_sources, 'Unresolved nested source edge')
    special = {}
    for cid in ('alcove', 'alcove-6350', 'spanish-wells'):
        community = next((c for c in catalog['communities'] if c['id'] == cid), None)
        if community is not None:
            special[cid] = {'community': community,
                            'featureIDs': [f['id'] for f in locations['features'] if f['properties']['communityID'] == cid]}
    if 'alcove' in special or 'alcove-6350' in special:
        require('alcove' in special and 'alcove-6350' in special and len(special['alcove']['featureIDs']) == 302 and
                len(special['alcove-6350']['featureIDs']) == 154, 'Incomplete frozen Riley pair')
        require({'alcove-6350-unit-10839846', 'alcove-6350-unit-10839920'} <= set(special['alcove-6350']['featureIDs']),
                'Missing frozen uncertain Riley labels')
    exceptions = catalog.get('deliveryAreaExceptions', [])
    return {'fixtureFormat': FORMAT, 'identityAlgorithm': 'draft-ascii-LocalSearch-port-dd77-not-native-parity',
            'baselineManifest': descriptor(manifest_body), 'packVersion': catalog['packVersion'],
            'counts': {n: len(v) for n, v in collections.items()},
            'semanticDuplicateGroups': [{'key': list(key), 'memberIDs': ids} for key, ids in groups.items() if len(ids) > 1],
            'sourceURLAliases': [{'url': url, 'sourceIDs': ids} for url, ids in urls.items() if len(ids) > 1],
            'orphanSourceIDs': [s['id'] for s in catalog['sources'] if s['id'] not in edges],
            'specialProperties': special, 'deliveryAreaExceptions': exceptions}


def anchor(bundle_pins, floor):
    return {'fixtureFormat': FORMAT, 'admissionProfile': dict(PROFILE), 'packVersion': bundle_pins['packVersion'],
            'files': bundle_pins['files'], 'minimumRootSequence': floor}


def validate_bundle_pins(pins, bodies, objects):
    require(type(pins) is dict and set(pins) == {'fixtureFormat', 'packVersion', 'files'} and pins['fixtureFormat'] == FORMAT,
            'Unexpected provisional bundle descriptor fields')
    validate_descriptors(pins['files'], bodies)
    require(pins['packVersion'] == objects[FILES[0]]['packVersion'], 'Bundle descriptor version mismatch')


def no_overlap(output, inputs):
    inputs = tuple(inputs)
    for path in (output, *inputs): ordinary_local_path(path)

    def checked_physical(path):
        # Check the original spelling before resolve() can hide an existing
        # symlink/junction component. Then compare physical, component-based
        # identities, including parent traversal and native Windows case rules.
        path = path.absolute()
        ancestors(path.parent)
        if os.path.lexists(path):
            plain(path, directory=stat.S_ISDIR(path.lstat().st_mode))
        return ordinary_local_path(path.resolve(strict=False))

    output = checked_physical(output)
    require(not os.path.lexists(output), 'Output already exists')
    for path in inputs:
        path = checked_physical(path)
        require(output != path and path not in output.parents and output not in path.parents, 'Input/output overlap prohibited')


def prepare(args):
    baseline, bundle, output = map(Path, (args.baseline, args.bundle, args.output))
    profile, pin_path = Path(args.admission_profile), Path(args.bundle_descriptors)
    no_overlap(output, (baseline, bundle, profile, pin_path))
    exact_directory(baseline, (*FILES, 'manifest.json'))
    exact_directory(bundle, FILES)
    manifest_body = read(baseline / 'manifest.json', 16_384)
    pin_body = read(pin_path, 16_384)
    require(digest(manifest_body) == args.baseline_manifest_sha256, 'Reviewed baseline manifest pin mismatch')
    require(digest(pin_body) == args.bundle_descriptors_sha256, 'Reviewed bundle descriptor pin mismatch')
    bodies, bundle_bodies = read_payload(baseline), read_payload(bundle)
    with admission_profile(profile) as feed:
        manifest = decode(manifest_body)
        feed.validate_manifest(manifest)
        validate_descriptors(manifest['files'], bodies)
        objects, bundle_objects = admitted(bodies, feed), admitted(bundle_bodies, feed)
        require(manifest['packVersion'] == objects[FILES[0]]['packVersion'], 'Manifest/payload version mismatch')
        require(1 <= args.minimum_root_sequence <= 2 ** 63 - 1 and args.minimum_root_sequence >= manifest['sequence'],
                'Explicit floor must cover the reviewed snapshot sequence')
        require(len(bodies[FILES[0]]) + 512 <= LIMITS[FILES[0]], 'Catalog lacks unchanged 512-byte preparation reserve')
        pins = decode(pin_body)
        validate_bundle_pins(pins, bundle_bodies, bundle_objects)
        registry = conservation(objects, manifest_body)
        registry['files'] = manifest['files']
        anchor_value = anchor(pins, args.minimum_root_sequence)
        metadata = {'bootstrap-anchor.json': encode(anchor_value), 'conservation-registry.json': encode(registry)}
        require(all(len(body) <= METADATA_LIMIT for body in metadata.values()), 'Provisional fixture metadata exceeds bound')
    # Validation finishes before the first output path is created. Exclusive
    # writes never overwrite an existing artifact; failures leave owned evidence.
    output.mkdir(parents=False, exist_ok=False)
    for group, original in [('baseline', bodies), ('bundle', bundle_bodies)]:
        directory = output / group; directory.mkdir()
        for name, body in original.items():
            with (directory / name).open('xb') as stream: stream.write(body)
    with (output / 'baseline' / 'manifest.json').open('xb') as stream: stream.write(manifest_body)
    for name, body in metadata.items():
        with (output / name).open('xb') as stream: stream.write(body)
    output_files = {**{'baseline/' + n: body for n, body in bodies.items()},
                    'baseline/manifest.json': manifest_body,
                    **{'bundle/' + n: body for n, body in bundle_bodies.items()}, **metadata}
    fixture = {'fixtureFormat': FORMAT,
               'reviewedInputPins': {'baselineManifestSHA256': args.baseline_manifest_sha256,
                                     'bundleDescriptorsSHA256': args.bundle_descriptors_sha256},
               'files': {name: descriptor(body) for name, body in output_files.items()}}
    fixture_body = encode(fixture)
    with (output / 'compatibility-fixture.json').open('xb') as stream: stream.write(fixture_body)
    return {'fixtureFormat': FORMAT, 'fixtureSHA256': digest(fixture_body),
            'counts': registry['counts'], 'minimumRootSequence': args.minimum_root_sequence,
            'nativeAcceptance': False, 'publicAdmission': False, 'publicWrites': 0}


def verify(args):
    directory = Path(args.directory)
    exact_directory(directory, ('baseline', 'bundle', 'bootstrap-anchor.json', 'conservation-registry.json', 'compatibility-fixture.json'))
    fixture_body = read(directory / 'compatibility-fixture.json', 16_384)
    require(digest(fixture_body) == args.fixture_sha256, 'Reviewed fixture identity mismatch')
    fixture = decode(fixture_body)
    require(type(fixture) is dict and set(fixture) == {'fixtureFormat', 'reviewedInputPins', 'files'} and
            fixture['fixtureFormat'] == FORMAT, 'Unexpected provisional fixture descriptor')
    limits = {**{'baseline/' + n: limit for n, limit in LIMITS.items()},
              **{'bundle/' + n: limit for n, limit in LIMITS.items()},
              'baseline/manifest.json': 16_384, 'bootstrap-anchor.json': METADATA_LIMIT,
              'conservation-registry.json': METADATA_LIMIT}
    require(type(fixture['files']) is dict and set(fixture['files']) == set(limits), 'Unexpected fixture members')
    captured = {}
    for name, maximum in limits.items():
        captured[name] = read(directory / name, maximum)
        require(fixture['files'][name] == descriptor(captured[name]), 'Fixture member descriptor mismatch')
    pins = fixture['reviewedInputPins']
    require(type(pins) is dict and set(pins) == {'baselineManifestSHA256', 'bundleDescriptorsSHA256'} and
            all(type(v) is str and re.fullmatch('[0-9a-f]{64}', v) for v in pins.values()) and
            pins['baselineManifestSHA256'] == fixture['files']['baseline/manifest.json']['sha256'], 'Invalid original review pins')
    exact_directory(directory / 'baseline', (*FILES, 'manifest.json'))
    exact_directory(directory / 'bundle', FILES)
    # All decoding/admission uses the exact bounded bytes whose root-bound
    # descriptors were checked above. No mutable source is reread.
    anchor_value = decode(captured['bootstrap-anchor.json'])
    registry = decode(captured['conservation-registry.json'])
    bodies = {n: captured['baseline/' + n] for n in FILES}
    bundle_bodies = {n: captured['bundle/' + n] for n in FILES}
    manifest_body = captured['baseline/manifest.json']
    require(type(anchor_value) is dict and set(anchor_value) == {'fixtureFormat', 'admissionProfile', 'packVersion', 'files',
            'minimumRootSequence'} and anchor_value['fixtureFormat'] == FORMAT and anchor_value['admissionProfile'] == PROFILE,
            'Unexpected provisional anchor fields or profile')
    floor = anchor_value['minimumRootSequence']
    require(type(floor) is int and 1 <= floor <= 2 ** 63 - 1, 'Invalid explicit floor')
    with admission_profile(Path(args.admission_profile)) as feed:
        manifest = decode(manifest_body); feed.validate_manifest(manifest)
        validate_descriptors(manifest['files'], bodies)
        objects, bundle_objects = admitted(bodies, feed), admitted(bundle_bodies, feed)
        require(manifest['packVersion'] == objects[FILES[0]]['packVersion'] and floor >= manifest['sequence'], 'Baseline/floor mismatch')
        require(len(bodies[FILES[0]]) + 512 <= LIMITS[FILES[0]], 'Catalog lacks preparation reserve')
        pins = {key: anchor_value[key] for key in ('fixtureFormat', 'packVersion', 'files')}
        validate_bundle_pins(pins, bundle_bodies, bundle_objects)
        expected = conservation(objects, manifest_body); expected['files'] = manifest['files']
        require(registry == expected, 'Finite conservation fixture differs from exact baseline')
    return {'fixtureFormat': FORMAT, 'counts': registry['counts'], 'nativeAcceptance': False, 'publicWrites': 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    prepare_parser = sub.add_parser('prepare')
    for name in ('baseline', 'baseline-manifest-sha256', 'bundle', 'bundle-descriptors', 'bundle-descriptors-sha256',
                 'admission-profile', 'output'):
        prepare_parser.add_argument('--' + name, required=True)
    prepare_parser.add_argument('--minimum-root-sequence', required=True, type=int)
    verify_parser = sub.add_parser('verify')
    verify_parser.add_argument('--directory', required=True)
    verify_parser.add_argument('--admission-profile', required=True)
    verify_parser.add_argument('--fixture-sha256', required=True)
    args = parser.parse_args()
    try:
        # Validate every CLI path spelling before any filesystem inspection,
        # including prepare inputs and both verify operands.
        for name in ('baseline', 'bundle', 'bundle_descriptors', 'admission_profile', 'output', 'directory'):
            if hasattr(args, name): ordinary_local_path(Path(getattr(args, name)))
        result = prepare(args) if args.action == 'prepare' else verify(args)
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, TypeError, KeyError, RecursionError) as error:
        print('Compatibility fixtures: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__': raise SystemExit(main())
