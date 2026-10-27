#!/usr/bin/env python3
"""Prepare a local JSON-only public catalog feed; never publish or access credentials."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


SPEC = importlib.util.spec_from_file_location('public_feed_admission', Path(__file__).with_name('public-catalog.py'))
ADMISSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADMISSION)
FILES = ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson')
LIMITS = {'public-catalog.json': 3_000_000, 'public-locations.geojson': 64_000_000,
          'public-paths.geojson': 16_000_000}
INPUT_LIMITS = dict(LIMITS, **{'known-addresses.json': 2_000_000, 'public-catalog-review.json': 100_000})
MANIFEST_LIMIT = 16_384
INT64_MAX = 2 ** 63 - 1
MANIFEST_FIELDS = {'schemaVersion', 'revision', 'sequence', 'packVersion', 'files'}
REVISION_PATTERN = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def present(path):
    return os.path.lexists(path)


def plain(path, *, directory=False):
    value = path.lstat()
    require(not stat.S_ISLNK(value.st_mode) and
            not getattr(value, 'st_file_attributes', 0) & getattr(stat, 'FILE_ATTRIBUTE_REPARSE_POINT', 0),
            'Linked or reparse-point paths are prohibited')
    require(stat.S_ISDIR(value.st_mode) if directory else stat.S_ISREG(value.st_mode),
            'Expected a plain directory' if directory else 'Expected a plain JSON file')
    return value


def unlinked_ancestors(path):
    for ancestor in (path, *path.parents):
        if present(ancestor):
            plain(ancestor, directory=True)


def read_bytes(path, maximum):
    before = plain(path)
    require(before.st_size <= maximum, 'JSON file exceeds its byte limit')
    with path.open('rb') as stream:
        opened = os.fstat(stream.fileno())
        require(stat.S_ISREG(opened.st_mode) and (opened.st_dev, opened.st_ino) == (before.st_dev, before.st_ino),
                'JSON input changed while opening')
        body = stream.read(maximum + 1)
        after = os.fstat(stream.fileno())
    require(len(body) <= maximum and len(body) == before.st_size == after.st_size and
            before.st_mtime_ns == after.st_mtime_ns, 'JSON file is oversized or changed during reading')
    return body


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON object key')
        result[key] = value
    return result


def reject_constant(_value):
    raise ValueError('Non-finite JSON numbers are prohibited')


def decode(body):
    value = json.loads(body, object_pairs_hook=unique_object, parse_constant=reject_constant)
    require(isinstance(value, dict), 'JSON payload must be an object')
    return value


def compact(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8')


def revision_segment(value):
    require(isinstance(value, str) and REVISION_PATTERN.fullmatch(value) is not None, 'Unsafe revision segment')
    # The data branch must also be materializable on the Windows publishing host.
    stem = value.split('.', 1)[0].upper()
    require(not value.endswith('.') and stem not in {'CON', 'PRN', 'AUX', 'NUL',
            *('COM' + str(i) for i in range(1, 10)), *('LPT' + str(i) for i in range(1, 10))},
            'Revision segment is not a portable directory name')


def positive_int64(value):
    require(type(value) is int and 1 <= value <= INT64_MAX, 'Sequence must be a positive Int64')


def validate_manifest(value):
    require(set(value) == MANIFEST_FIELDS and type(value['schemaVersion']) is int and value['schemaVersion'] == 1,
            'Unexpected feed manifest schema or fields')
    revision_segment(value['revision'])
    positive_int64(value['sequence'])
    ADMISSION.validate_version(value['packVersion'])
    require(isinstance(value['files'], dict) and set(value['files']) == set(FILES), 'Unexpected feed payload files')
    for name in FILES:
        descriptor = value['files'][name]
        require(isinstance(descriptor, dict) and set(descriptor) == {'bytes', 'sha256'}, 'Unexpected file descriptor fields')
        require(type(descriptor['bytes']) is int and 1 <= descriptor['bytes'] <= LIMITS[name], 'Invalid payload byte length')
        require(isinstance(descriptor['sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', descriptor['sha256']) is not None,
                'Invalid lowercase SHA-256')


def read_manifest(path):
    body = read_bytes(path, MANIFEST_LIMIT)
    value = decode(body)
    validate_manifest(value)
    return value, body


def public_objects(bodies):
    objects = {name: decode(body) for name, body in bodies.items()}
    for value in objects.values():
        require(type(value.get('schemaVersion')) is int and value['schemaVersion'] == 1, 'Unsupported public JSON schema')
    return objects


def admitted_source(directory):
    unlinked_ancestors(directory)
    require({entry.name for entry in directory.iterdir()} == set(INPUT_LIMITS),
            'Input must contain exactly the five reviewed public bundle files; backups and unknown files are prohibited')
    bodies = {name: read_bytes(directory / name, maximum) for name, maximum in INPUT_LIMITS.items()}
    objects = public_objects(bodies)
    # Admit an immutable local snapshot, so the reviewed hashes and parsed data
    # refer to the exact same bytes even if the caller edits the source directory.
    with tempfile.TemporaryDirectory(prefix='public-feed-admission-') as temporary:
        snapshot = Path(temporary)
        for name, body in bodies.items():
            (snapshot / name).write_bytes(body)
        ADMISSION.validate(snapshot)
    return {name: objects[name] for name in FILES}


def verify_revision(directory):
    plain(directory, directory=True)
    require({entry.name for entry in directory.iterdir()} == set(FILES) | {'manifest.json'},
            'Revision directories must contain only their manifest and three public JSON payloads')
    manifest, manifest_bytes = read_manifest(directory / 'manifest.json')
    require(manifest['revision'] == directory.name, 'Revision directory and manifest disagree')
    bodies = {name: read_bytes(directory / name, LIMITS[name]) for name in FILES}
    for name, body in bodies.items():
        require(manifest['files'][name] == dict(bytes=len(body), sha256=hashlib.sha256(body).hexdigest()),
                'Stored revision length or hash mismatch')
    objects = public_objects(bodies)
    ADMISSION.validate_payload(*(objects[name] for name in FILES))
    require(objects['public-catalog.json']['packVersion'] == manifest['packVersion'], 'Manifest and catalog packVersion disagree')
    return manifest, manifest_bytes


def existing_feed(output):
    if not present(output):
        unlinked_ancestors(output.parent)
        return []
    unlinked_ancestors(output)
    require({entry.name for entry in output.iterdir()} <= {'latest.json', 'latest-v2.json', 'revisions'}, 'Staging feed must remain JSON-only')
    history = []
    revisions = output / 'revisions'
    if present(revisions):
        plain(revisions, directory=True)
        for directory in sorted(revisions.iterdir()):
            revision_segment(directory.name)
            history.append(verify_revision(directory))
    require(len({item['revision'].casefold() for item, _ in history}) == len(history), 'Case-colliding revision directories')
    require(len({item['sequence'] for item, _ in history}) == len(history), 'Duplicate revision sequences')
    pointers = [output / name for name in ('latest.json', 'latest-v2.json') if present(output / name)]
    for latest in pointers:
        current, body = read_manifest(latest)
        require(any(item == current and stored == body for item, stored in history), 'Latest manifest has no identical verified revision')
    require(pointers or not history, 'Existing revisions have no selected manifest; inspect the incomplete staging feed')
    return [item for item, _ in history]


def write_new(path, body):
    with path.open('xb') as stream:
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())


def prepare(directory, output, revision, sequence, previous_manifest=None, latest_name="latest.json"):
    directory = Path(os.path.abspath(directory))
    output = Path(os.path.abspath(output))
    revision_segment(revision)
    positive_int64(sequence)
    require(latest_name in ("latest.json", "latest-v2.json"), "Unsupported manifest pointer")
    source_path, output_path = directory.resolve(), output.resolve()
    require(not source_path.is_relative_to(output_path) and not output_path.is_relative_to(source_path),
            'Feed output and public input directories must not overlap')
    history = existing_feed(output)
    if previous_manifest is not None:
        previous = Path(os.path.abspath(previous_manifest))
        unlinked_ancestors(previous.parent)
        history.append(read_manifest(previous)[0])
    require(all(item['revision'].casefold() != revision.casefold() for item in history), 'Revision already exists and cannot be reused')
    require(all(sequence > item['sequence'] for item in history), 'Sequence must increase beyond every retained or supplied revision')
    objects = admitted_source(directory)
    catalog = objects['public-catalog.json']
    legacy_zips = {'89113', '89148', '89123', '89183', '89052', '89014', '89044'}
    if latest_name == 'latest.json':
        require(not any('digitalLocker' in c for c in catalog['communities']) and set(catalog['scopeZIPs']) <= legacy_zips,
                'Expanded valley and locker payloads require latest-v2.json; preserve the legacy app feed')
    bodies = {name: compact(objects[name]) for name in FILES}
    for name, body in bodies.items():
        require(len(body) <= LIMITS[name] and decode(body) == objects[name], 'Canonical payload exceeds its limit or changed JSON values')
    manifest = dict(schemaVersion=1, revision=revision, sequence=sequence,
        packVersion=objects['public-catalog.json']['packVersion'],
        files={name: dict(bytes=len(body), sha256=hashlib.sha256(body).hexdigest()) for name, body in bodies.items()})
    validate_manifest(manifest)
    manifest_bytes = compact(manifest)
    require(len(manifest_bytes) <= MANIFEST_LIMIT, 'Feed manifest exceeds its byte limit')
    output.mkdir(exist_ok=True)
    plain(output, directory=True)
    revisions = output / 'revisions'
    revisions.mkdir(exist_ok=True)
    plain(revisions, directory=True)
    destination = revisions / revision
    destination.mkdir(exist_ok=False)
    for name, body in bodies.items():
        write_new(destination / name, body)
    write_new(destination / 'manifest.json', manifest_bytes)
    verified, verified_bytes = verify_revision(destination)
    require(verified == manifest and verified_bytes == manifest_bytes, 'Written revision failed verification')
    pending = None
    try:
        with tempfile.NamedTemporaryFile(prefix='.latest-', suffix='.json', dir=output, delete=False) as stream:
            pending = Path(stream.name)
            stream.write(manifest_bytes)
            stream.flush()
            os.fsync(stream.fileno())
        require(read_manifest(pending) == (manifest, manifest_bytes), 'Staged latest manifest failed verification')
        os.replace(pending, output / latest_name)
    finally:
        if pending is not None and present(pending):
            pending.unlink()
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    command = sub.add_parser('prepare')
    command.add_argument('--directory', type=Path, required=True)
    command.add_argument('--output', type=Path, required=True)
    command.add_argument('--revision', required=True)
    command.add_argument('--sequence', type=int, required=True)
    command.add_argument('--previous-manifest', type=Path)
    command.add_argument('--latest-name', choices=['latest.json', 'latest-v2.json'], default='latest.json')
    args = parser.parse_args()
    try:
        manifest = prepare(args.directory, args.output, args.revision, args.sequence, args.previous_manifest, args.latest_name)
        print(compact(manifest).decode('utf-8'), end='')
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit('Public catalog feed: ' + str(error))


if __name__ == '__main__':
    main()
