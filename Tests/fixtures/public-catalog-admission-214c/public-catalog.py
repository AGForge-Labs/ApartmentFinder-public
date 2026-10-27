#!/usr/bin/env python3
"""Prepare and verify the explicitly reviewed public apartment bundle.

This is a field allowlist, not a provenance or privacy review substitute. Inputs
must be reviewed source-derived property data, never a phone/personal export.
"""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import sys
from urllib.parse import parse_qsl, urlsplit

SCHEMA = 1
# Clark County OpenData/zip_p polygons intersecting -115.50,35.85,-114.85,36.50 (2026-10-24).
ALLOWED_ZIPS = {'89002', '89004', '89005', '89011', '89012', '89014', '89015', '89019', '89030', '89031', '89032', '89040', '89044', '89052', '89054', '89074', '89081', '89084', '89085', '89086', '89101', '89102', '89103', '89104', '89106', '89107', '89108', '89109', '89110', '89113', '89115', '89117', '89118', '89119', '89120', '89121', '89122', '89123', '89124', '89128', '89129', '89130', '89131', '89134', '89135', '89138', '89139', '89141', '89142', '89143', '89144', '89145', '89146', '89147', '89148', '89149', '89156', '89158', '89161', '89166', '89169', '89178', '89179', '89183', '89191'}
SOURCE_FIELD_ORDER = ('retrievedAt', 'id', 'url', 'title')
SOURCE_FIELDS = set(SOURCE_FIELD_ORDER)
COMMUNITY_FIELDS = {'id', 'name', 'address', 'zip', 'countyZIPs', 'deliveryAddresses', 'aliases',
                    'sourceIDs', 'researchStatus', 'gapNotes', 'latitude', 'longitude', 'publicEvidence', 'digitalLocker'}
POINT_FIELDS = {'communityID', 'address', 'building', 'unit', 'floor', 'kind', 'verification',
                'sourceIDs', 'notes', 'identityUncertain', 'referenceKind', 'estimatedHorizontalUncertaintyM',
                'mapLabelOccurrenceID', 'sourceUnitID', 'referenceAddresses', 'entranceSideEstimate'}
ENTRANCE_SIDE_REQUIRED_FIELDS = {'frontage', 'workingAllowanceMeters', 'uncertaintyCalibrated',
    'doorCoordinatesVerified', 'entranceCoordinatesVerified', 'physicalSignageVerified',
    'dwellingFloorEvidence', 'entryLevelDescription', 'sharedUnits', 'evidenceNotes'}
ENTRANCE_SIDE_FIELDS = ENTRANCE_SIDE_REQUIRED_FIELDS | {'dwellingFloor', 'sourceUnitID', 'sourceDate'}
PATH_FIELDS = {'communityID', 'fromNode', 'toNode', 'mode', 'oneWay', 'blocked', 'stairs',
               'confirmed', 'sourceIDs', 'notes'}
CATALOG_FIELDS = {'schemaVersion', 'packVersion', 'generatedAt', 'scopeZIPs', 'deliveryAreaExceptions',
                  'sources', 'communities', 'coverage', 'unitBuildingAssociations', 'unitFloorReferences'}
ASSOCIATION_FIELDS = {'id', 'communityID', 'address', 'unit', 'building', 'identifierKind', 'sourceIDs', 'referencePlaceID', 'mapFloor', 'sourceUnitID', 'historicalLegalAlias', 'historicalFloor'}
FLOOR_REFERENCE_FIELDS = {'id', 'communityID', 'address', 'unit', 'floor', 'sourceIDs', 'sourceRevision'}
BUILDING_REFERENCE_NOTE = 'Assessor legal-building reference derived from official condominium polygons; the area may include courtyard or open space and need not lie on a physical roof. Legal IDs may differ from physical signs; absolute positional accuracy is unknown. This is not a unit position, entrance or exact door.'
OPERATOR_BUILDING_REFERENCE_NOTE = 'Approximate operator-map building area matched to public aerial imagery; working uncertainty {uncertainty:g} m is not guaranteed accuracy. Physical signs remain unverified. This is not a unit position, entrance or exact door.'
COLLECTION_FIELDS = {'type', 'schemaVersion', 'packVersion', 'features'}
GAP = 'Public property identity and available source positions are incomplete. No exact door, entrance or current access condition is established.'
REFERENCE_GAP = 'Community coordinate is a published property reference or source-map reference only; it is not a unit, entrance or delivery destination.'
SOURCE_NOTE = 'Published unit position; not an entrance or exact door. Verify the physical street, unit and building on arrival.'
ESTIMATE_NOTE = 'May be inaccurate. Estimated unit position; not an entrance or exact door. Confirm the physical street, unit and building on arrival.'
ENTRANCE_SIDE_NOTE = 'Estimated entrance-side search region; not a verified entrance or exact door. Representative point only; working allowance {allowance:g} m is uncalibrated, not guaranteed accuracy. Physical signage remains unverified.'
PATH_NOTE = 'OpenStreetMap contributors, ODbL 1.0. Published source path, not personally confirmed. Access conditions remain unverified.'
COVERAGE_NOTES = [
    'Public source-derived apartment and multifamily inventory. This is not a certified exhaustive inventory.',
    'Published unit positions retain their source confidence. Estimated positions may be inaccurate; no exact doors or entrances are established.',
    'New Silverado-area records may have only a verified property name and street address. Missing unit maps remain explicit research gaps.',
    'Public map geometry is unconfirmed. OpenStreetMap contributors attribution and ODbL requirements apply to retained OSM paths.',
]
# Mirrors the dedicated compiled-public-bundle reader, not private/import budgets.
RESOURCE_LIMITS = {'public-catalog.json': 3_000_000, 'public-locations.geojson': 64_000_000, 'public-paths.geojson': 16_000_000, 'known-addresses.json': 2_000_000}
RESOURCE_NAMES = ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson', 'known-addresses.json')


# Tool-owned, content-pinned exception for the independently reviewed directory
# cohort. This is not a payload flag or an arbitrary notes/import switch.
REVIEWED_POINT_REGISTRY_SHA256 = 'ef44cf26b94a929aa51d40a3613a67532f3df181bf14b219a7ef030be1d41b1b'
REVIEWED_POINT_NAMESPACES = ('directory-sector:trend:', 'directory-unit-sector:destinations-pebble:',
    'directory-unit-sector:parkside-villas:', 'estimated-unit-side:paramount:',
    'estimated-unit-side:manhattan:phase1:')
REVIEWED_POINT_PREFIX = 'Approximate unit-sector/side reference; not a verified door or entrance. '
_reviewed_point_registry = None
TREND_CONFIDENCE_NAMESPACE = 'directory-sector:trend:'
TREND_CONFIDENCE_REGISTRY_SHA256 = '34a52840c3b69cadd1b181430867963d0859e1eec10e390cc85d043f1363faf6'
_reviewed_trend_confidence_registry = None
MANHATTAN12_NAMESPACE = 'directory-unit-sector:manhattan:'
MANHATTAN12_REGISTRY_SHA256 = 'b1699d79c3fecba0cae5d454201b903bd381e583572f1dc59a55a62c908a8d36'
_reviewed_manhattan12_registry = None
AREA28_NAMESPACES = ('estimated-unit-area:octave-apartments:', 'estimated-unit-area:st-james-place:',
    'estimated-unit-area:southpark:')
AREA28_REGISTRY_SHA256 = '829a8e0f1804ae6548a521cf1d667ae051ba3f7cbf6c1fc92b473207a3e1303f'
_reviewed_area28_registry = None
AREA30_NAMESPACES = ('southpark:unit-area:', 'directory-unit-sector:paragon-lofts:')
AREA30_REGISTRY_SHA256 = 'ae4b2ee9aa0880f69488558863b50f06dacb7cd2b33ab45add3b3b8763a32ff1'
_reviewed_area30_registry = None


def canonical_object_sha256(value):
    body = (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False) + '\n').encode()
    return hashlib.sha256(body).hexdigest()


def reviewed_point_registry():
    global _reviewed_point_registry
    if _reviewed_point_registry is None:
        path = Path(__file__).with_name('reviewed-directory-features-20261023.json')
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 1_000_000,
                'Missing or linked publisher-owned directory review seal')
        body = path.read_bytes()
        require(hashlib.sha256(body).hexdigest() == REVIEWED_POINT_REGISTRY_SHA256,
                'Publisher-owned directory review seal changed')
        value = json.loads(body)
        require(set(value) == {'schemaVersion', 'reservedNamespaces', 'featureSHA256', 'sourceSHA256'} and
                value['schemaVersion'] == 1 and tuple(value['reservedNamespaces']) == REVIEWED_POINT_NAMESPACES,
                'Unexpected publisher-owned directory review seal')
        _reviewed_point_registry = value
    return _reviewed_point_registry


def reviewed_trend_confidence_registry():
    """Tool-owned exact successor; never accepts a payload-provided waiver."""
    global _reviewed_trend_confidence_registry
    if _reviewed_trend_confidence_registry is None:
        path = Path(__file__).with_name('reviewed-trend-confidence-features-20261026.json')
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 256_000,
                'Missing or linked publisher-owned Trend confidence review seal')
        body = path.read_bytes()
        require(hashlib.sha256(body).hexdigest() == TREND_CONFIDENCE_REGISTRY_SHA256,
                'Publisher-owned Trend confidence review seal changed')
        value = json.loads(body)
        require(set(value) == {'schemaVersion', 'legacyRegistrySHA256', 'communityID', 'postalZIP',
                'communitySHA256', 'beforeFeatureSHA256', 'afterFeatureSHA256', 'nativeFeatureIDs',
                'estimatedFeatureIDs', 'afterLegacyCohortSourceSHA256', 'sourceCandidateSHA256',
                'sourceHandoffSHA256', 'independentSourceReviewSHA256', 'excludedSourceUnit'} and
                value['schemaVersion'] == 1 and value['communityID'] == 'trend' and value['postalZIP'] == '89183' and
                value['legacyRegistrySHA256'] == REVIEWED_POINT_REGISTRY_SHA256,
                'Unexpected publisher-owned Trend confidence review seal')
        native, estimated = set(value['nativeFeatureIDs']), set(value['estimatedFeatureIDs'])
        require(len(native) == 356 and len(estimated) == 5 and not native & estimated and
                native | estimated == set(value['beforeFeatureSHA256']) == set(value['afterFeatureSHA256']) and
                all(fid.startswith(TREND_CONFIDENCE_NAMESPACE) for fid in native),
                'Unexpected reviewed Trend replacement membership')
        _reviewed_trend_confidence_registry = value
    return _reviewed_trend_confidence_registry


def reviewed_trend_cohort_source_hashes(locations, communities, legacy_registry):
    """All 361 Trend objects are historical or reviewed successor, never mixed."""
    registry = reviewed_trend_confidence_registry()
    features = {f['id']: f for f in locations['features'] if f['properties']['communityID'] == 'trend'}
    hashes = {fid: canonical_object_sha256(feature) for fid, feature in features.items()}
    if hashes == registry['beforeFeatureSHA256']:
        return legacy_registry['sourceSHA256']
    require(hashes == registry['afterFeatureSHA256'],
            'Trend confidence replacement is partial, mixed or changed')
    community = communities.get('trend')
    require(community is not None and community['zip'] == registry['postalZIP'] and
            canonical_object_sha256(community) == registry['communitySHA256'],
            'Reviewed Trend replacement community identity changed')
    return registry['afterLegacyCohortSourceSHA256']


def is_reviewed_point_id(value):
    return isinstance(value, str) and value.startswith(REVIEWED_POINT_NAMESPACES + (MANHATTAN12_NAMESPACE,) + AREA28_NAMESPACES + AREA30_NAMESPACES)


def reviewed_area30_registry():
    global _reviewed_area30_registry
    if _reviewed_area30_registry is None:
        path = Path(__file__).with_name('reviewed-sourceareas30-features-20261023.json')
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 20_000,
                'Missing or linked publisher-owned recorded-unit-area review seal')
        body = path.read_bytes()
        require(hashlib.sha256(body).hexdigest() == AREA30_REGISTRY_SHA256,
                'Publisher-owned recorded-unit-area review seal changed')
        value = json.loads(body)
        require(set(value) == {'schemaVersion', 'reservedNamespaces', 'featureSHA256', 'sourceSHA256'} and
                value['schemaVersion'] == 1 and tuple(value['reservedNamespaces']) == AREA30_NAMESPACES,
                'Unexpected publisher-owned recorded-unit-area review seal')
        _reviewed_area30_registry = value
    return _reviewed_area30_registry


def reviewed_area28_registry():
    global _reviewed_area28_registry
    if _reviewed_area28_registry is None:
        path = Path(__file__).with_name('reviewed-local28-features-20261023.json')
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 20_000,
                'Missing or linked publisher-owned unit-area review seal')
        body = path.read_bytes()
        require(hashlib.sha256(body).hexdigest() == AREA28_REGISTRY_SHA256,
                'Publisher-owned unit-area review seal changed')
        value = json.loads(body)
        require(set(value) == {'schemaVersion', 'reservedNamespaces', 'featureSHA256', 'sourceSHA256'} and
                value['schemaVersion'] == 1 and tuple(value['reservedNamespaces']) == AREA28_NAMESPACES,
                'Unexpected publisher-owned unit-area review seal')
        _reviewed_area28_registry = value
    return _reviewed_area28_registry


def reviewed_manhattan12_registry():
    global _reviewed_manhattan12_registry
    if _reviewed_manhattan12_registry is None:
        path = Path(__file__).with_name('reviewed-manhattan12-features-20261023.json')
        require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 20_000,
                'Missing or linked publisher-owned Manhattan review seal')
        body = path.read_bytes()
        require(hashlib.sha256(body).hexdigest() == MANHATTAN12_REGISTRY_SHA256,
                'Publisher-owned Manhattan review seal changed')
        value = json.loads(body)
        require(set(value) == {'schemaVersion', 'reservedNamespaces', 'featureSHA256', 'sourceSHA256'} and
                value['schemaVersion'] == 1 and value['reservedNamespaces'] == [MANHATTAN12_NAMESPACE],
                'Unexpected publisher-owned Manhattan review seal')
        _reviewed_manhattan12_registry = value
    return _reviewed_manhattan12_registry


def require(condition, message):
    if not condition:
        raise ValueError(message)


def text(value, label, *, empty=False):
    require(isinstance(value, str) and len(value) <= 2048 and (empty or bool(value.strip()))
            and not any(ord(c) < 32 for c in value), 'Invalid ' + label)
    return value


def validate_version(value):
    text(value, 'pack version')
    require(len(value) <= 120 and re.fullmatch(r'[A-Za-z0-9._-]+', value), 'Invalid pack version scalar')


def timestamp(value):
    text(value, 'generation timestamp')
    require('T' in value and datetime.fromisoformat(value.replace('Z', '+00:00')).tzinfo is not None, 'Invalid generation timestamp')


def coordinate(value):
    require(isinstance(value, list) and len(value) == 2 and all(type(x) in (int, float) and math.isfinite(x) for x in value)
            and -180 <= value[0] <= 180 and -90 <= value[1] <= 90, 'Invalid public coordinate')


def digital_locker(value, sources):
    require(isinstance(value, dict) and set(value) <= {'status', 'brand', 'placementDescription', 'sourceIDs', 'checkedAt', 'point'}
        and {'status', 'sourceIDs', 'checkedAt'} <= set(value), 'Unexpected digital locker fields')
    status = value['status']
    require(status in ('present', 'absent', 'unknown'), 'Invalid digital locker status')
    def refs(ids, required):
        require(isinstance(ids, list) and all(isinstance(x, str) for x in ids) and (not required or ids)
            and len(ids) <= 16 and len(ids) == len(set(ids)) and set(ids) <= set(sources), 'Unresolved digital locker evidence')
    refs(value['sourceIDs'], status != 'unknown')
    reviewed = value['checkedAt']
    require(isinstance(reviewed, str) and bool(re.fullmatch(r'\d{4}-\d{2}-\d{2}', reviewed)), 'Invalid locker review date')
    require(datetime.strptime(reviewed, '%Y-%m-%d').strftime('%Y-%m-%d') == reviewed, 'Invalid locker review date')
    if 'brand' in value:
        name = value['brand']
        require(isinstance(name, str) and name.strip() and len(name) <= 80 and not re.search(
            r'usps|keyed|mailbox|cluster.?box|package room|mailroom', name, re.I), 'Unsupported electronic locker identity')
    if 'placementDescription' in value:
        text(value['placementDescription'], 'locker placement')
        require(len(value['placementDescription']) <= 240, 'Locker placement too long')
    if 'point' in value:
        point = value['point']
        require(status == 'present' and isinstance(point, dict) and set(point) == {'longitude', 'latitude', 'locationSourceIDs', 'precision'}, 'Invalid digital locker point')
        coordinate([point['longitude'], point['latitude']])
        require(-115.50 <= point['longitude'] <= -114.85 and 35.85 <= point['latitude'] <= 36.50, 'Locker point outside research area')
        refs(point['locationSourceIDs'], True)
        require(point['precision'] in ('sourceMapped', 'approximate'), 'Invalid locker location precision')


def source_url(value):
    text(value, 'source URL')
    url = urlsplit(value)
    require(url.scheme == 'https' and url.hostname and not url.username and not url.password, 'Invalid source URL')
    require(not any(re.search(r'(?:token|api.?key|password|secret|credential|signature|authorization)', k, re.I)
                    for k, _ in parse_qsl(url.query)), 'Credential-bearing source URL is prohibited')


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + '\n').encode()


def read_json(path, maximum=64_000_000):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= maximum, 'Missing, linked or oversized input')
    return json.loads(path.read_bytes())


def entrance_side_estimate_note(properties):
    estimate = properties['entranceSideEstimate']
    require(isinstance(estimate, dict) and ENTRANCE_SIDE_REQUIRED_FIELDS <= set(estimate) <= ENTRANCE_SIDE_FIELDS,
            'Unexpected or missing entrance-side estimate fields')
    require(properties.get('kind') == 'unitPosition' and properties.get('verification') == 'estimated' and
            properties.get('identityUncertain') is True, 'Entrance-side search regions must remain explicitly uncertain estimates')
    require(not any(key in properties for key in ('referenceKind', 'estimatedHorizontalUncertaintyM',
            'mapLabelOccurrenceID', 'sourceUnitID', 'referenceAddresses')),
            'Entrance-side estimate cannot borrow building-reference or published-unit metadata')
    unit = text(properties.get('unit'), 'entrance-side unit')
    floor = text(properties.get('floor'), 'entrance-side position floor', empty=True)
    allowance = estimate['workingAllowanceMeters']
    require(type(allowance) in (int, float) and math.isfinite(allowance) and 1 <= allowance <= 100,
            'Invalid entrance-side working allowance')
    for key in ('uncertaintyCalibrated', 'doorCoordinatesVerified', 'entranceCoordinatesVerified', 'physicalSignageVerified'):
        require(estimate[key] is False, 'Entrance-side verification and calibration flags must remain false')
    shared = estimate['sharedUnits']
    require(isinstance(shared, list) and len(shared) <= 4, 'Invalid entrance-side shared units')
    for shared_unit in shared:
        text(shared_unit, 'entrance-side shared unit')
    require(len(set(shared)) == len(shared) and (not shared or unit in shared),
            'Entrance-side shared units must be unique and include the literal unit')
    frontage = estimate['frontage']
    require(isinstance(frontage, list) and (2 <= len(frontage) <= 32 or len(frontage) == 0 and len(shared) >= 2),
            'Entrance-side frontage requires 2 to 32 points or explicit shared-unit evidence')
    for point in frontage:
        require(isinstance(point, dict) and set(point) == {'latitude', 'longitude'}, 'Unexpected entrance-side frontage fields')
        coordinate([point['longitude'], point['latitude']])
    status = estimate['dwellingFloorEvidence']
    require(status in ('unknown', 'inferred', 'historicalExplicit', 'currentExplicit'), 'Invalid dwelling-floor evidence')
    dwelling_floor = estimate.get('dwellingFloor')
    if status == 'unknown':
        require(dwelling_floor is None, 'Unknown dwelling floor cannot assert a value')
    else:
        text(dwelling_floor, 'dwelling floor')
    require(floor == '' or status == 'currentExplicit' and floor == dwelling_floor,
            'Position floor requires matching current explicit dwelling-floor evidence')
    text(estimate['entryLevelDescription'], 'entrance-side entry level')
    text(estimate['evidenceNotes'], 'entrance-side evidence notes')
    for key in ('sourceUnitID', 'sourceDate'):
        if estimate.get(key) is not None:
            text(estimate[key], 'entrance-side ' + key)
    return ENTRANCE_SIDE_NOTE.format(allowance=allowance) + ' ' + estimate['evidenceNotes']


def position_note(feature):
    """Construct fixed public text; reserve the reviewed dispute for its exact identity."""
    # Exact separately reviewed Octave MODEL unit areas; no payload waiver.
    octave_model_notes = {'octave-apartments:source-unit-area:112716': ('4317a38640840fb321464ac5896ea35e401223388461f4e34d18929a11b01b3f', 'Directory unit area - MODEL.'), 'octave-apartments:source-unit-area:112823': ('da60151ca5f95d2b3e944c7a277be3277050936dc7b3cc44449ff8139cd97271', 'Directory unit area - MODEL.')}
    octave_model = octave_model_notes.get(feature['id'])
    if octave_model is not None:
        require(canonical_object_sha256(feature) == octave_model[0],
                'Unreviewed Octave MODEL identity, geometry, provenance or annotation')
        return octave_model[1]
    # Exact separately reviewed Sunset printed-only area estimates; no payload waiver.
    sunset_printed_area_notes = {'sunset-hills:estimated-printed-unit-area:682960': ('8d5ce0f027f97f217c116fe221e74d7a2943ec541b3ffdd93253d818b16b0d66', 'Estimated directory area; provider label 607 conflicts with printed 604.'), 'sunset-hills:estimated-printed-unit-area:682962': ('912956fba11276153db69726b4424c1c4f1ae71ba394c524883423dd851eba4f', 'Estimated directory area; provider label 603 conflicts with printed 602.'), 'sunset-hills:estimated-printed-unit-area:682964': ('7b859d22d7a2795d1f41661da794d58ed25b7e9378077a31c2e399515a1fd52b', 'Estimated directory area; provider label 604 conflicts with printed 603.')}
    sunset_printed = sunset_printed_area_notes.get(feature['id'])
    if sunset_printed is not None:
        require(canonical_object_sha256(feature) == sunset_printed[0],
                'Unreviewed Sunset printed-area identity, geometry, provenance or conflict note')
        return sunset_printed[1]
    p = feature['properties']
    # Exact independently source-reviewed Evolve MODEL identities only.
    evolve_models = {'evolve:source-unit-area:10575281': {'unit': '1153', 'sourceUnitID': '10575281', 'coordinates': [-115.12765, 36.00228]}, 'evolve:source-unit-area:10575290': {'unit': '1156', 'sourceUnitID': '10575290', 'coordinates': [-115.1276505, 36.0021655]}, 'evolve:source-unit-area:10575454': {'unit': '1322', 'sourceUnitID': '10575454', 'coordinates': [-115.125684, 36.000859000000005]}}
    model = evolve_models.get(feature['id'])
    if model is not None:
        expected = dict(communityID='evolve', address='3140 St Rose Pkwy', unit=model['unit'], building='', floor='', kind='unitPosition', verification='sourceMapped', sourceUnitID=model['sourceUnitID'], sourceIDs=['evolve-map-data-20261026', 'evolve-native-directory-20261026', 'evolve-published-unit-geometry-20261026'])
        require(set(p) == set(expected) | {'notes'} and all(p.get(k) == v for k, v in expected.items()) and feature.get('geometry') == dict(type='Point', coordinates=model['coordinates']), 'Unreviewed Evolve MODEL identity or geometry')
        return 'Directory unit area - MODEL.'
    if (isinstance(feature['id'], str) and feature['id'].startswith(TREND_CONFIDENCE_NAMESPACE) and
            p.get('verification') == 'sourceMapped'):
        registry = reviewed_trend_confidence_registry()
        require(feature['id'] in registry['nativeFeatureIDs'] and
                canonical_object_sha256(feature) == registry['afterFeatureSHA256'].get(feature['id']),
                'Unreviewed Trend directory confidence replacement')
        return SOURCE_NOTE
    if is_reviewed_point_id(feature['id']):
        if feature['id'].startswith(AREA30_NAMESPACES):
            registry = reviewed_area30_registry()
        elif feature['id'].startswith(AREA28_NAMESPACES):
            registry = reviewed_area28_registry()
        elif feature['id'].startswith(MANHATTAN12_NAMESPACE):
            registry = reviewed_manhattan12_registry()
        else:
            registry = reviewed_point_registry()
        require(set(p) == {'communityID', 'address', 'building', 'unit', 'floor', 'kind',
                    'verification', 'sourceIDs', 'notes', 'identityUncertain'} and
                p['kind'] == 'unitPosition' and p['verification'] == 'estimated' and
                p['identityUncertain'] is True and p['floor'] == '',
                'Reviewed directory point changed precision or public fields')
        require(canonical_object_sha256(feature) == registry['featureSHA256'].get(feature['id']),
                'Unreviewed directory point identity, coordinate, provenance or notes')
        note = text(p['notes'], 'reviewed directory notes')
        require(note.startswith(REVIEWED_POINT_PREFIX), 'Missing directory uncertainty qualification')
        return note
    estimate_note = entrance_side_estimate_note(p) if 'entranceSideEstimate' in p else None
    if feature['id'] == 'spanish-ridge-7380-unit-county-2179616-201':
        expected = dict(communityID='spanish-ridge-7380', address='7380 W RUSSELL RD',
            building='', unit='201', floor='', kind='unitPosition', verification='sourceMapped')
        sources = ['spanish-ridge-7380-county-unit-labels', 'spanish-ridge-7380-county-unit-buildings']
        require('referenceKind' not in p and all(p.get(key) == value for key, value in expected.items()) and
                p.get('sourceIDs') in (sources, list(reversed(sources))), 'Unreviewed disputed unit source shape')
        return SOURCE_NOTE + ' Building A for 201 is not asserted. Building and floor remain unknown.'
    riley_sources = ('riley-county-6350', 'riley-county-6355')
    sources = p.get('sourceIDs', [])
    if (p.get('communityID') in ('alcove', 'alcove-6350') or
            isinstance(feature['id'], str) and feature['id'].startswith(('alcove-unit-', 'alcove-6350-unit-')) or
            isinstance(sources, list) and any(source in sources for source in riley_sources)):
        moved = p.get('communityID') == 'alcove-6350'
        street = '6350' if moved else '6355'
        prefix = 'alcove-6350-unit-' if moved else 'alcove-unit-'
        require('referenceKind' not in p and p.get('communityID') == ('alcove-6350' if moved else 'alcove') and
                isinstance(feature['id'], str) and re.fullmatch(re.escape(prefix) + r'[0-9]{8}', feature['id']) and
                p.get('address') == street + ' S Riley St' and p.get('kind') == 'unitPosition' and
                p.get('verification') == 'sourceMapped' and isinstance(sources, list) and len(sources) == 4 and
                set(sources) == {'alcove-geo-0', 'alcove-map-api-0', 'alcove-building-groups-0', 'riley-county-' + street} and
                (p.get('building') in ('6', '7') if moved else p.get('building') not in ('6', '7')),
                'Unreviewed Riley position source shape')
        uncertain_identities = {'alcove-6350-unit-10839846': ('6', '327', '3'),
            'alcove-6350-unit-10839920': ('7', '303', '3')}
        identity = tuple(p.get(key) for key in ('building', 'unit', 'floor'))
        expected_identity = uncertain_identities.get(feature['id'])
        require((identity == expected_identity and p.get('identityUncertain') is True) if expected_identity else
                (p.get('identityUncertain') is not True and identity not in uncertain_identities.values()),
                'Unreviewed Riley position source shape')
        if moved:
            note = SOURCE_NOTE + ' Street address is supported by the 6350 county parcel containing this published position. County ZIP is 89113; the retained directory postal ZIP 89148 is not independently verified for 6350.'
            if p.get('identityUncertain') is True:
                note += ' The same unit label is not confirmed by the county parcel records; check the unit/building on arrival.'
            return note
        return SOURCE_NOTE + ' This 6355 position falls in the retained 89148 county polygon, consistent with the official postal address.'
    if estimate_note is not None:
        return estimate_note
    if 'referenceKind' in p:
        if p['referenceKind'] == 'operatorMapBuildingArea':
            return OPERATOR_BUILDING_REFERENCE_NOTE.format(uncertainty=p.get('estimatedHorizontalUncertaintyM', 0))
        return BUILDING_REFERENCE_NOTE
    return ESTIMATE_NOTE if p['verification'] == 'estimated' else SOURCE_NOTE


def validate_payload(catalog, locations, paths):
    require(set(catalog) <= CATALOG_FIELDS and catalog['schemaVersion'] == SCHEMA, 'Unexpected catalog schema or fields')
    require(catalog['coverage'] == {'inventoryComplete': False, 'notes': COVERAGE_NOTES}, 'Unexpected public coverage text')
    validate_version(catalog['packVersion'])
    timestamp(catalog['generatedAt'])
    zips = catalog['scopeZIPs']
    require(isinstance(zips, list) and zips and len(zips) == len(set(zips)) and set(zips) <= ALLOWED_ZIPS, 'Unsupported public ZIP scope')
    sources = {}
    for source in catalog['sources']:
        require(set(source) == SOURCE_FIELDS and source['id'] not in sources, 'Duplicate source or unexpected source fields')
        for key in SOURCE_FIELDS:
            text(source[key], 'source ' + key)
        source_url(source['url'])
        sources[source['id']] = source
    def refs(value):
        require(isinstance(value, list) and value and len(value) == len(set(value)) and set(value) <= set(sources), 'Unresolved source reference')
    exceptions = catalog.get('deliveryAreaExceptions') or []
    require(isinstance(exceptions, list) and len(exceptions) <= 1, 'Unsupported public delivery-area exception')
    exception_fields = {'communityID', 'address', 'postalZIP', 'propertyAPN', 'currentCountyAPN',
        'identitySourceID', 'countySourceID', 'boundarySourceID', 'cadastralSourceID'}
    for exception in exceptions:
        require(set(exception) == exception_fields and exception['communityID'] == 'spanish-wells' and
            exception['address'] == '5355 S Rainbow Blvd' and exception['postalZIP'] == '89118' and
            exception['propertyAPN'] == '16327710000' and exception['currentCountyAPN'] == '16327710181',
            'Unsupported public delivery-area exception fields')
        refs([exception[k] for k in ('identitySourceID', 'countySourceID', 'boundarySourceID', 'cadastralSourceID')])
    communities = {}
    for community in catalog['communities']:
        require(set(community) <= COMMUNITY_FIELDS and community['id'] not in communities, 'Duplicate community or unexpected community fields')
        for key in ('id', 'name', 'address', 'zip', 'researchStatus'):
            text(community[key], 'community ' + key)
        require(community['zip'] in zips or any(x['communityID'] == community['id'] and x['postalZIP'] == community['zip']
            for x in catalog.get('deliveryAreaExceptions', [])), 'Community outside public ZIP scope')
        require(set(community.get('countyZIPs', [])) <= set(zips), 'Unsupported county ZIP filter')
        require(community['gapNotes'] == gap_notes(community), 'Unexpected public gap text')
        for key in ('aliases', 'deliveryAddresses'):
            require(isinstance(community.get(key, []), list), 'Invalid public identity list')
            for value in community.get(key, []):
                text(value, 'public identity')
        require(('latitude' in community) == ('longitude' in community), 'Incomplete property reference')
        if 'latitude' in community:
            coordinate([community['longitude'], community['latitude']])
        refs(community['sourceIDs'])
        if 'digitalLocker' in community:
            digital_locker(community['digitalLocker'], sources)
        if 'publicEvidence' in community:
            evidence = community['publicEvidence']
            require(set(evidence) <= {'communityType', 'areaScope', 'addressSourceIDs', 'coordinate', 'addressCityDisagreement', 'singleResidentialBuilding'} and
                    evidence['communityType'] in ('apartment', 'condominium', 'seniorLiving') and
                    evidence['areaScope'] in ('core', 'edge', 'nearbyOutsideFocus'), 'Unexpected public field evidence')
            require('addressCityDisagreement' not in evidence or type(evidence['addressCityDisagreement']) is bool, 'Invalid city disagreement flag')
            refs(evidence['addressSourceIDs'])
            if 'singleResidentialBuilding' in evidence:
                config = evidence['singleResidentialBuilding']
                require(isinstance(config, dict) and set(config) == {'publishedStories', 'publishedApartments', 'sourceIDs'} and
                        type(config['publishedStories']) is int and 1 <= config['publishedStories'] <= 100 and
                        type(config['publishedApartments']) is int and 1 <= config['publishedApartments'] <= 10_000,
                        'Invalid published building configuration')
                refs(config['sourceIDs'])
            if 'coordinate' in evidence:
                proof = evidence['coordinate']
                require('latitude' in community and set(proof) == {'kind', 'sourceIDs'} and proof['kind'] in
                    ('operatorPublishedPropertyPoint', 'municipalBoundaryCentroid', 'municipalBoundaryInteriorReference',
                     'municipalBusinessLicensePropertyReference', 'hudApproximatePropertyReference',
                     'countyPublishedAddressPropertyReference', 'countyTestAddressPropertyReference'), 'Unsupported coordinate evidence')
                refs(proof['sourceIDs'])
            elif 'latitude' in community:
                raise ValueError('Public field evidence omits coordinate provenance')
        communities[community['id']] = community
    require(communities, 'Public catalog has no communities')
    ids = set()
    for collection, point in ((locations, True), (paths, False)):
        require(set(collection) == COLLECTION_FIELDS and collection['type'] == 'FeatureCollection'
                and collection['schemaVersion'] == SCHEMA and collection['packVersion'] == catalog['packVersion'], 'Mismatched collection version or fields')
        for feature in collection['features']:
            require(set(feature) == {'type', 'id', 'geometry', 'properties'} and feature['type'] == 'Feature'
                    and feature['id'] not in ids, 'Duplicate feature or unexpected feature fields')
            ids.add(text(feature['id'], 'feature ID'))
            p = feature['properties']
            require(set(p) <= (POINT_FIELDS if point else PATH_FIELDS), 'Unexpected public position/path fields')
            require(p['communityID'] in communities, 'Unknown feature community')
            refs(p['sourceIDs'])
            require(set(feature['geometry']) == {'type', 'coordinates'}, 'Unexpected geometry fields')
            if point:
                require(feature['geometry']['type'] == 'Point', 'Invalid public point geometry')
                coordinate(feature['geometry']['coordinates'])
                require(p['kind'] in ('building', 'unitPosition') and p['verification'] in ('sourceMapped', 'estimated'), 'Unsupported public precision or field verification')
                if 'referenceKind' in p:
                    require(p['referenceKind'] in ('assessorLegalBuildingPolygon', 'operatorMapBuildingArea') and p['kind'] == 'building' and
                            p['verification'] == 'sourceMapped' and p['unit'] == '' and p['floor'] == '' and
                            bool(p['building'].strip()), 'Unsupported building reference precision')
                if p.get('referenceKind') == 'operatorMapBuildingArea':
                    allowance = p.get('estimatedHorizontalUncertaintyM')
                    require(type(allowance) in (int, float) and math.isfinite(allowance) and 1 <= allowance <= 100,
                            'Unsupported operator building working uncertainty')
                    text(p.get('mapLabelOccurrenceID'), 'operator map occurrence')
                else:
                    require('estimatedHorizontalUncertaintyM' not in p and 'mapLabelOccurrenceID' not in p,
                            'Building-area metadata on an unrelated location')
                if 'sourceUnitID' in p:
                    text(p['sourceUnitID'], 'source unit ID')
                    require(p['kind'] == 'unitPosition' and p['verification'] == 'sourceMapped', 'Source unit ID on a non-unit position')
                require(p['notes'] == position_note(feature), 'Unexpected public position text')
                for key in ('address', 'building', 'unit', 'floor'):
                    text(p[key], 'position ' + key, empty=True)
                require('identityUncertain' not in p or type(p['identityUncertain']) is bool, 'Invalid uncertainty flag')
            else:
                require(feature['geometry']['type'] == 'LineString' and len(feature['geometry']['coordinates']) >= 2, 'Invalid public path geometry')
                for value in feature['geometry']['coordinates']:
                    coordinate(value)
                require(p['confirmed'] is False and p['mode'] in ('drive', 'walk', 'both') and p['notes'] == PATH_NOTE, 'Private/confirmed or unsupported path')
                for key in ('oneWay', 'blocked', 'stairs'):
                    require(type(p[key]) is bool, 'Invalid path flags')
                text(p['fromNode'], 'path node'); text(p['toNode'], 'path node')
    # Each immutable cohort is absent in its earlier historical revisions and
    # complete when present. A new cohort must not invalidate older feed files.
    for namespaces, registry_provider in ((REVIEWED_POINT_NAMESPACES, reviewed_point_registry),
            ((MANHATTAN12_NAMESPACE,), reviewed_manhattan12_registry),
            (AREA28_NAMESPACES, reviewed_area28_registry),
            (AREA30_NAMESPACES, reviewed_area30_registry)):
        cohort = {f['id'] for f in locations['features'] if isinstance(f['id'], str) and f['id'].startswith(namespaces)}
        if cohort:
            registry = registry_provider()
            require(cohort == set(registry['featureSHA256']),
                    'Reviewed directory cohort is incomplete, including possible alternate sides')
            expected_sources = (reviewed_trend_cohort_source_hashes(locations, communities, registry)
                if namespaces == REVIEWED_POINT_NAMESPACES else registry['sourceSHA256'])
            cohort_sources = {s for f in locations['features'] if f['id'] in cohort for s in f['properties']['sourceIDs']}
            require(cohort_sources == set(expected_sources) and
                    all(canonical_object_sha256(sources[s]) == expected_sources[s] for s in cohort_sources),
                    'Reviewed directory evidence source changed')
    associations = catalog.get('unitBuildingAssociations', [])
    require(isinstance(associations, list) and len(associations) <= 50_000, 'Invalid building association collection')
    association_ids, association_keys = set(), set()
    points_by_id = {f['id']: f for f in locations['features']}
    def address_key(value):
        # Only spelling/punctuation aliases; no street numbers or unit suffixes are discarded.
        aliases = {'west':'w', 'east':'e', 'north':'n', 'south':'s', 'road':'rd', 'street':'st',
                   'avenue':'ave', 'drive':'dr', 'lane':'ln', 'boulevard':'blvd', 'court':'ct', 'way':'wy', 'parkway':'pkwy'}
        return ' '.join(aliases.get(x, x) for x in re.findall(r'[a-z0-9]+', value.lower()))
    for f in locations['features']:
        p = f['properties']
        if 'referenceAddresses' in p:
            c = communities[p['communityID']]; values = p['referenceAddresses']
            require(p.get('referenceKind') in ('assessorLegalBuildingPolygon', 'operatorMapBuildingArea') and
                    isinstance(values, list) and 1 <= len(values) <= 8, 'Invalid building-reference street aliases')
            for value in values: text(value, 'building-reference street alias')
            keys = [address_key(value) for value in values]
            require(len(set(keys)) == len(keys) and set(keys) <= {address_key(x) for x in [c['address']] + c.get('deliveryAddresses', [])}, 'Unsupported building-reference street alias')
    for a in associations:
        require(isinstance(a, dict) and set(a) <= ASSOCIATION_FIELDS, 'Unexpected building association fields')
        for key in ('id', 'communityID', 'address', 'unit', 'building', 'identifierKind'):
            text(a[key], 'building association ' + key)
        require(a['id'] not in association_ids and a['communityID'] in communities and
                a['identifierKind'] in ('municipalLegal', 'operatorMap'), 'Unknown or duplicate building association identity')
        association_ids.add(a['id']); refs(a['sourceIDs'])
        c = communities[a['communityID']]
        require(address_key(a['address']) in {address_key(x) for x in [c['address']] + c.get('deliveryAddresses', [])},
                'Building association outside community streets')
        key = (a['communityID'], address_key(a['address']), a['unit'].casefold(), a['identifierKind'])
        require(key not in association_keys, 'Duplicate or conflicting unit-building association'); association_keys.add(key)
        if 'mapFloor' in a:
            text(a['mapFloor'], 'operator map floor')
            require(a['identifierKind'] == 'operatorMap', 'Unsupported legal building floor inference')
        if 'referencePlaceID' in a:
            text(a['referencePlaceID'], 'building reference ID')
            f = points_by_id.get(a['referencePlaceID']); p = f['properties'] if f else {}
            require((a['identifierKind'], p.get('referenceKind')) in
                    (('municipalLegal', 'assessorLegalBuildingPolygon'), ('operatorMap', 'operatorMapBuildingArea')) and
                    p.get('communityID') == a['communityID'] and address_key(a['address']) in
                    {address_key(x) for x in [p.get('address', '')] + p.get('referenceAddresses', [])} and
                    p.get('building') == a['building'], 'Building association reference mismatch')
        if 'sourceUnitID' in a:
            text(a['sourceUnitID'], 'source unit ID')
            require(a['identifierKind'] == 'operatorMap', 'Operator source unit ID on another namespace')
        if 'historicalLegalAlias' in a or 'historicalFloor' in a:
            require(a.get('historicalLegalAlias') is True and a['identifierKind'] == 'municipalLegal', 'Unsupported historical alias namespace')
            require('historicalFloor' not in a or a['historicalFloor'] in ('ground', 'second'), 'Unsupported historical floor interpretation')
    floors = catalog.get('unitFloorReferences', [])
    require(isinstance(floors, list) and len(floors) <= 50_000, 'Invalid floor-only reference collection')
    floor_ids, floor_keys = set(), set()
    for row in floors:
        require(isinstance(row, dict) and set(row) <= FLOOR_REFERENCE_FIELDS, 'Unexpected floor-only fields')
        for key in ('id', 'communityID', 'address', 'unit', 'floor'):
            text(row[key], 'floor-only ' + key)
        require(row['communityID'] in communities and row['id'] not in floor_ids, 'Unknown or duplicate floor-only identity')
        floor_ids.add(row['id']); refs(row['sourceIDs'])
        c = communities[row['communityID']]
        require(address_key(row['address']) in {address_key(x) for x in [c['address']] + c.get('deliveryAddresses', [])}, 'Floor-only street mismatch')
        key = (row['communityID'], address_key(row['address']), row['unit'].lower())
        require(key not in floor_keys, 'Ambiguous floor-only identity'); floor_keys.add(key)
        if 'sourceRevision' in row:
            require(isinstance(row['sourceRevision'], str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}', row['sourceRevision']), 'Invalid floor source revision')
    return dict(communities=len(communities), positions=len(locations['features']), paths=len(paths['features']), sources=len(sources))


def split_reviewed_riley(catalog, locations, source_version):
    """Mirror the existing bounded source correction before public indexing."""
    base = next((c for c in catalog['communities'] if c['id'] == 'alcove' and c['address'] == '6355 S Riley St'), None)
    if source_version != '2026.10.14.1' or base is None:
        return
    original = [f for f in locations['features'] if f['properties']['communityID'] == 'alcove']
    selected = [f for f in original if f['properties']['building'] in ('6', '7')]
    require(len(original) == 456 and len(selected) == 154 and
            not any(c['id'] == 'alcove-6350' for c in catalog['communities']), 'Unreviewed Riley source shape')
    stream = bytearray()
    def append(value):
        data = value.encode(); stream.extend(struct.pack('>Q', len(data))); stream.extend(data)
    append('ApartmentFinder.RileyPropertySeparation.v1')
    for feature in sorted(selected, key=lambda f: f['id']):
        p = feature['properties']
        require(p['address'] == '6355 S Riley St' and p['kind'] == 'unitPosition' and p['verification'] == 'sourceMapped', 'Unreviewed Riley source precision')
        for value in (feature['id'], p['unit'], p['building'], p['floor']):
            append(value)
        lon, lat = feature['geometry']['coordinates']
        stream.extend(struct.pack('>d', lat)); stream.extend(struct.pack('>d', lon))
    require(hashlib.sha256(stream).hexdigest() == 'da514c901a6e7d6657f1304a4765b43fe9f239771783319bc7370d92c3c1d594', 'Riley source fingerprint changed')
    new_sources = []
    for street in ('6350', '6355'):
        new_sources.append(dict(id='riley-county-' + street, title='Clark County' + street + ' Riley street-specific parcels',
            url='https://maps.clarkcountynv.gov/arcgis/rest/services/GISMO/Address/MapServer/2/query?f=json&where=strno%3D' + street + '+AND+strname%3D%27RILEY%27&outFields=strno%2Cstrdir%2Cstrname%2Cstrtype%2Cstrunit%2Csubname%2CADFILE%2CADPAGE&returnGeometry=true&outSR=4326&resultRecordCount=2000',
            retrievedAt='2026-10-18T00:07:00Z'))
    require(not ({s['id'] for s in new_sources} & {s['id'] for s in catalog['sources']}), 'Riley source ID collision')
    catalog['sources'].extend(new_sources)
    separate = copy.deepcopy(base)
    separate.update(id='alcove-6350', name='6350 S Riley St', address='6350 S Riley St', deliveryAddresses=['6350 S Riley St'], aliases=[], countyZIPs=['89113'])
    separate.pop('latitude', None); separate.pop('longitude', None)
    separate['sourceIDs'].extend(s['id'] for s in new_sources)
    base['sourceIDs'].extend(s['id'] for s in new_sources)
    base['countyZIPs'] = ['89148']
    selected_ids = {f['id'] for f in selected}
    occupied = {f['id'] for f in locations['features']}
    for feature in original:
        p = feature['properties']
        if feature['id'] in selected_ids:
            new_id = feature['id'].replace('alcove-unit-', 'alcove-6350-unit-')
            require(new_id not in occupied, 'Riley position ID collision')
            feature['id'] = new_id
            p.update(communityID='alcove-6350', address='6350 S Riley St')
            p['sourceIDs'].append('riley-county-6350')
            if (p['building'], p['unit'], p['floor']) in (('6','327','3'), ('7','303','3')):
                p['identityUncertain'] = True
        else:
            p['sourceIDs'].append('riley-county-6355')
    retained = [f['geometry']['coordinates'] for f in original if f['properties']['communityID'] == 'alcove']
    base['longitude'] = (min(p[0] for p in retained) + max(p[0] for p in retained)) / 2
    base['latitude'] = (min(p[1] for p in retained) + max(p[1] for p in retained)) / 2
    catalog['communities'].append(separate)


def gap_notes(community):
    notes = [GAP] + ([REFERENCE_GAP] if 'latitude' in community else [])
    if community['id'] == 'alcove-6350':
        notes.append('6350 and 6355 S Riley St are separate properties. Retained directory postal ZIP 89148 is not independently verified for 6350; county ZIP 89113 is searchable. Two unmatched county unit labels require confirmation on arrival.')
    elif community['id'] == 'alcove':
        notes.append('6355 S Riley St remains separate from 6350 S Riley St. Its 302 retained source positions fall in county ZIP 89148.')
    elif community['id'] == 'spanish-ridge-7380':
        notes.append('7380 and 7340 W Russell Rd remain separate physical streets. Disputed building identity is marked uncertain; repeated unit labels do not establish the same building.')
    evidence = community.get('publicEvidence', {})
    if evidence.get('communityType') == 'condominium':
        notes.append('Community type: condominium. Verified base street addresses may cover several buildings; no new unit map is supplied.')
    if evidence.get('communityType') == 'seniorLiving':
        notes.append('Publicly listed operating senior community; residency and care arrangements vary. No building or unit navigation is established by the address record.')
    if config := evidence.get('singleResidentialBuilding'):
        notes.append(f"Published sources describe one residential building with {config['publishedApartments']} apartments on {config['publishedStories']} stories. Building numbers, unit/corridor layout, entrances and doors remain unverified.")
    if evidence.get('areaScope') == 'nearbyOutsideFocus':
        notes.append('This community is nearby but outside the focused Silverado Ranch study area.')
    elif evidence.get('areaScope') == 'edge':
        notes.append('This community lies at an edge of the focused Silverado Ranch study area.')
    if evidence.get('addressCityDisagreement') is True:
        notes.append('Published property sources disagree on the city label. The base street and stated postal ZIP are retained; the city label remains unverified.')
    kind = evidence.get('coordinate', {}).get('kind')
    if kind == 'operatorPublishedPropertyPoint':
        notes.append('The operator publishes this property reference point. Surveyed accuracy, entrances, buildings and units are not established by it.')
    elif kind == 'municipalBoundaryCentroid':
        notes.append('Reference coordinate is an area-weighted centroid derived from published municipal whole-community polygons. It is not an entrance, building or unit.')
    elif kind == 'municipalBoundaryInteriorReference':
        notes.append('Reference coordinate is a derived interior point of published municipal whole-community polygons, not their true centroid or an entrance, building or unit.')
    elif kind == 'municipalBusinessLicensePropertyReference':
        notes.append('County business-license property reference rematched by exact property name and address; record IDs may change. This is not a unit, building, entrance or door.')
    elif kind == 'hudApproximatePropertyReference':
        notes.append('HUD publishes this approximate property reference; physical accuracy is unmeasured. This is not a unit, building, entrance or door.')
    elif kind == 'countyPublishedAddressPropertyReference':
        notes.append('County published common-address property reference, independently matched to its property polygon. This is not a unit, building, entrance or door.')
    elif kind == 'countyTestAddressPropertyReference':
        notes.append('County Test service common-address reference, independently inside the matching property polygon; lower confidence service lineage is retained. This is not a unit, building, entrance or door.')
    return notes


def prepare(source, output, version, additions, evidence_file=None):
    raw = {name: read_json(source / name) for name in ('catalog.json', 'locations.geojson', 'paths.geojson')}
    original = raw['catalog.json']
    for payload in raw.values():
        version_value = payload['packVersion']
        validate_version(version_value)
    validate_version(version)
    require(all(x['packVersion'] == original['packVersion'] for x in raw.values()), 'Source versions must match')
    catalog = {k: copy.deepcopy(v) for k, v in original.items() if k in CATALOG_FIELDS}
    catalog.update(packVersion=version, generatedAt=datetime.now(timezone.utc).isoformat(), coverage={'inventoryComplete': False, 'notes': COVERAGE_NOTES})
    catalog['sources'] = [{k: s[k] for k in SOURCE_FIELD_ORDER} for s in original['sources']]
    catalog['communities'] = [{k: copy.deepcopy(v) for k, v in c.items() if k in COMMUNITY_FIELDS} for c in original['communities']]
    if 'unitBuildingAssociations' in catalog:
        catalog['unitBuildingAssociations'] = [{k: copy.deepcopy(v) for k, v in a.items() if k in ASSOCIATION_FIELDS}
                                               for a in catalog['unitBuildingAssociations']]
    if 'unitFloorReferences' in catalog:
        catalog['unitFloorReferences'] = [{k: copy.deepcopy(v) for k, v in row.items() if k in FLOOR_REFERENCE_FIELDS}
                                          for row in catalog['unitFloorReferences']]
    for filename in additions:
        extra = read_json(filename, 2_000_000)
        catalog['sources'].extend({k: s[k] for k in SOURCE_FIELD_ORDER} for s in extra['sources'])
        catalog['communities'].extend({k: copy.deepcopy(v) for k, v in c.items() if k in COMMUNITY_FIELDS} for c in extra['communities'])
        for patch in extra.get('communityEnrichments', []):
            require(set(patch) <= {'id', 'deliveryAddresses', 'aliasesToAdd', 'latitude', 'longitude',
                'sourceIDsToAdd', 'coordinateMethod', 'coordinateScope', 'digitalLocker'}, 'Unexpected enrichment fields')
            targets = [c for c in catalog['communities'] if c['id'] == patch['id']]
            require(len(targets) == 1, 'Unknown or duplicate enrichment target')
            target = targets[0]
            for source_key, destination_key in (('deliveryAddresses', 'deliveryAddresses'),
                    ('aliasesToAdd', 'aliases'), ('sourceIDsToAdd', 'sourceIDs')):
                if source_key in patch:
                    require(isinstance(patch[source_key], list) and all(isinstance(v, str) for v in patch[source_key]), 'Invalid enrichment identity list')
                    target[destination_key] = list(dict.fromkeys(target.get(destination_key, []) + patch[source_key]))
            if 'digitalLocker' in patch:
                target['digitalLocker'] = copy.deepcopy(patch['digitalLocker'])
            require(('latitude' in patch) == ('longitude' in patch), 'Partial enrichment coordinate')
            if 'latitude' in patch:
                coordinate([patch['longitude'], patch['latitude']])
                target.update(latitude=patch['latitude'], longitude=patch['longitude'])
    if evidence_file is not None:
        evidence = read_json(evidence_file, 200_000)
        require(isinstance(evidence, list) and len({e['communityID'] for e in evidence}) == len(evidence), 'Duplicate public field evidence')
        communities = {c['id']: c for c in catalog['communities']}
        for entry in evidence:
            require(set(entry) <= {'communityID', 'communityType', 'areaScope', 'addressSourceIDs', 'coordinate', 'addressCityDisagreement', 'singleResidentialBuilding'} and entry['communityID'] in communities, 'Unexpected public evidence target/fields')
            communities[entry['communityID']]['publicEvidence'] = {k: copy.deepcopy(v) for k, v in entry.items() if k != 'communityID'}
    catalog['scopeZIPs'] = sorted(set(catalog['scopeZIPs']) | {c['zip'] for c in catalog['communities'] if c['zip'] in ALLOWED_ZIPS})
    collections = []
    for name, fields, point in [('locations.geojson', POINT_FIELDS, True), ('paths.geojson', PATH_FIELDS, False)]:
        collection = {k: copy.deepcopy(v) for k, v in raw[name].items() if k in COLLECTION_FIELDS}
        collection['packVersion'] = version
        collection['features'] = [{k: copy.deepcopy(v) for k, v in f.items() if k in {'type', 'id', 'geometry', 'properties'}} for f in collection['features']]
        for feature in collection['features']:
            p = feature['properties'] = {k: v for k, v in feature['properties'].items() if k in fields}
            if not point:
                p['notes'] = PATH_NOTE
        collections.append(collection)
    locations, paths = collections
    split_reviewed_riley(catalog, locations, original['packVersion'])
    for feature in locations['features']:
        feature['properties']['notes'] = position_note(feature)
    for community in catalog['communities']:
        community['researchStatus'] = 'publicSourceInventory'
        community['gapNotes'] = gap_notes(community)
    refs = {i for c in catalog['communities'] for i in c['sourceIDs']}
    refs.update(i for c in catalog['communities'] for i in c.get('digitalLocker', {}).get('sourceIDs', []))
    refs.update(i for c in catalog['communities'] for i in c.get('digitalLocker', {}).get('point', {}).get('locationSourceIDs', []))
    refs.update(i for a in catalog.get('unitBuildingAssociations', []) for i in a['sourceIDs'])
    refs.update(i for a in catalog.get('unitFloorReferences', []) for i in a['sourceIDs'])
    refs.update(i for collection in collections for f in collection['features'] for i in f['properties']['sourceIDs'])
    catalog['sources'] = [s for s in catalog['sources'] if s['id'] in refs]
    counts = validate_payload(catalog, locations, paths)
    index = dict(schemaVersion=1, packVersion=version, entries=[dict(address=c['address'], deliveryAddresses=c.get('deliveryAddresses', [])) for c in catalog['communities']])
    encoded = {name: json_bytes(value) for name, value in zip(RESOURCE_NAMES, (catalog, locations, paths, index))}
    if len(encoded['public-catalog.json']) > RESOURCE_LIMITS['public-catalog.json']:
        encoded['public-catalog.json'] = (json.dumps(catalog, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode()
    for name, body in encoded.items():
        require(len(body) <= RESOURCE_LIMITS[name], 'Public resource exceeds native loader limit: ' + name)
    output.mkdir(parents=True, exist_ok=False)
    for name, body in encoded.items():
        (output / name).write_bytes(body)
    manifest = dict(schemaVersion=1, publicFieldsOnly=True, version=version, counts=counts,
        sourcePackVersion=original['packVersion'], sourceSHA256={name: digest(source / name) for name in raw},
        resourcesSHA256={name: digest(output / name) for name in RESOURCE_NAMES})
    (output / 'public-catalog-review.json').write_bytes(json_bytes(manifest))
    return counts


def validate(directory):
    catalog, locations, paths, index = [read_json(directory / name, RESOURCE_LIMITS[name]) for name in RESOURCE_NAMES]
    counts = validate_payload(catalog, locations, paths)
    manifest = read_json(directory / 'public-catalog-review.json', 100_000)
    require(set(manifest) == {'schemaVersion', 'publicFieldsOnly', 'version', 'counts', 'sourcePackVersion', 'sourceSHA256', 'resourcesSHA256'}, 'Unexpected public review manifest fields')
    validate_version(manifest['sourcePackVersion'])
    require(set(manifest['sourceSHA256']) == {'catalog.json', 'locations.geojson', 'paths.geojson'} and
            all(isinstance(v, str) and re.fullmatch(r'[0-9a-f]{64}', v) for v in manifest['sourceSHA256'].values()), 'Invalid source digest review')
    require(type(manifest['counts']) is dict and set(manifest['counts']) == set(counts) and
            all(type(v) is int and v >= 0 for v in manifest['counts'].values()), 'Invalid public counts')
    require(manifest['schemaVersion'] == 1 and manifest['publicFieldsOnly'] is True and manifest['counts'] == counts
            and manifest['version'] == catalog['packVersion'], 'Public review manifest mismatch')
    require(manifest['resourcesSHA256'] == {name: digest(directory / name) for name in RESOURCE_NAMES}, 'Public resource digest mismatch')
    expected = dict(schemaVersion=1, packVersion=catalog['packVersion'], entries=[dict(address=c['address'], deliveryAddresses=c.get('deliveryAddresses', [])) for c in catalog['communities']])
    require(index == expected, 'Public address index differs from catalog')
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    build = sub.add_parser('prepare')
    build.add_argument('--source', type=Path, required=True)
    build.add_argument('--output', type=Path, required=True)
    build.add_argument('--version', required=True)
    build.add_argument('--additions', type=Path, action='append', default=[])
    build.add_argument('--evidence', type=Path)
    check = sub.add_parser('validate'); check.add_argument('--directory', type=Path, required=True)
    args = parser.parse_args()
    try:
        counts = prepare(args.source, args.output, args.version, args.additions, args.evidence) if args.action == 'prepare' else validate(args.directory)
        print(json.dumps(dict(public_catalog=counts)))
    except (ValueError, KeyError, TypeError, OSError) as error:
        sys.exit('Public catalog: ' + str(error))


if __name__ == '__main__':
    main()
