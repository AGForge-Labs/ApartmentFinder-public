"""Test-only exact .25.13 -> .24.3 projection; app data is never supplied here."""
import copy
import hashlib
import json
from pathlib import Path

import reviewed_bundle_history as previous

ROOT = Path(__file__).resolve().parents[2]
RESOURCE_NAMES = previous.RESOURCE_NAMES
SEAL_SHA256 = '9db4eed310a18e14d2aefc1ca7a89f6ae61c15d88fd56ae8fb26730e2bcd6add'
LIMITS = {'public-catalog.json': 3_000_000, 'public-locations.geojson': 64_000_000,
          'public-paths.geojson': 16_000_000, 'known-addresses.json': 2_000_000,
          'public-catalog-review.json': 16_384}


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def _seal():
    path = Path(__file__).with_name('reviewed-release-bundle-history-seal.json')
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 262_144,
            'release history declaration missing or oversized')
    body = path.read_bytes()
    require(hashlib.sha256(body).hexdigest() == SEAL_SHA256, 'release history declaration changed')
    seal = json.loads(body)
    require(seal['schemaVersion'] == 1 and set(seal['rawFiles']) == set(LIMITS)
            and set(seal['files']) == set(RESOURCE_NAMES), 'release history declaration unsupported')
    for name, expected in seal['unchangedLegacyInputs'].items():
        source = Path(__file__).with_name(name)
        require(source.is_file() and not source.is_symlink()
                and hashlib.sha256(source.read_bytes()).hexdigest() == expected,
                'legacy history layer or seal changed')
    return seal


def load_current_resources(directory=None):
    """Read exactly the five reviewed bytes, checking size/hash before JSON parsing."""
    directory = ROOT / 'data' if directory is None else Path(directory)
    require(directory.is_dir() and not directory.is_symlink(), 'release resource directory unsupported')
    seal = _seal()
    values = {}
    for name, maximum in LIMITS.items():
        path, expected = directory / name, seal['rawFiles'][name]
        require(path.is_file() and not path.is_symlink() and 0 < expected['bytes'] <= maximum
                and path.stat().st_size == expected['bytes'], 'release resource byte budget or size changed: ' + name)
        body = path.read_bytes()
        require(len(body) == expected['bytes'] and hashlib.sha256(body).hexdigest() == expected['sha256'],
                'release resource bytes changed: ' + name)
        values[name] = json.loads(body)
    return {name: values[name] for name in RESOURCE_NAMES}


def project_to_previous(current):
    """Validate the complete new snapshot before reversing declared public enrichment."""
    seal = _seal()
    require(isinstance(current, dict) and set(current) == set(RESOURCE_NAMES), 'current snapshot resource set changed')
    for name, spec in seal['files'].items():
        value = current[name]
        require(isinstance(value, dict) and set(value) == set(spec['keys'])
                and fingerprint(value) == spec['currentFileSHA256'], 'current snapshot changed: ' + name)
        for key, collection in spec['collections'].items():
            rows, count = value[key], collection['previousCount']
            require(isinstance(rows, list) and len(rows) == collection['currentCount']
                    and fingerprint(rows[:count]) == collection['currentPrefixSHA256']
                    and fingerprint(rows[count:]) == collection['completeAddedSuffixSHA256'],
                    'current snapshot collection changed: ' + name + '/' + key)
    # No copied/reversed old fact is produced before every whole current file passed.
    projected = {}
    for name, spec in seal['files'].items():
        value = current[name]
        projected[name] = {k: copy.deepcopy(v) for k, v in value.items() if k not in spec['collections']}
        for key, collection in spec['collections'].items():
            projected[name][key] = copy.deepcopy(value[key][:collection['previousCount']])
    communities = {c['id']: c for c in projected['public-catalog.json']['communities']}
    patches = seal['communityInversePatches']
    require(len(patches) == 17 and set(patches) <= set(communities), 'declared community patch set changed')
    for cid, patch in patches.items():
        require(set(patch) == {'restore', 'remove'} and set(patch['restore']) <= {'sourceIDs', 'digitalLocker'}
                and set(patch['remove']) <= {'digitalLocker'}, 'declared inverse fields changed')
        communities[cid].update(copy.deepcopy(patch['restore']))
        for key in patch['remove']:
            del communities[cid][key]
    for name, spec in seal['files'].items():
        require(set(spec['previousMetadata']) == set(projected[name]) - set(spec['collections']),
                'previous metadata field set changed')
        projected[name].update(copy.deepcopy(spec['previousMetadata']))
        for key, collection in spec['collections'].items():
            require(fingerprint(projected[name][key]) == collection['previousSHA256'],
                    'previous collection changed: ' + name + '/' + key)
        require(fingerprint(projected[name]) == spec['previousFileSHA256'], 'previous whole snapshot changed: ' + name)
    return projected


def load_reviewed_resources():
    """Old test callers receive the exact .24.3 snapshot only after .13 validation."""
    return project_to_previous(load_current_resources())


def historical_resources(current=None):
    """Retain the old API's .24.3 input semantics and every old mutation assertion."""
    return previous.historical_resources(load_reviewed_resources() if current is None else current)
