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
ALLOWED_ZIPS = {'89113', '89148', '89123', '89183', '89052', '89014', '89044'}
SOURCE_FIELD_ORDER = ('retrievedAt', 'id', 'url', 'title')
SOURCE_FIELDS = set(SOURCE_FIELD_ORDER)
COMMUNITY_FIELDS = {'id', 'name', 'address', 'zip', 'countyZIPs', 'deliveryAddresses', 'aliases',
                    'sourceIDs', 'researchStatus', 'gapNotes', 'latitude', 'longitude', 'publicEvidence'}
POINT_FIELDS = {'communityID', 'address', 'building', 'unit', 'floor', 'kind', 'verification',
                'sourceIDs', 'notes', 'identityUncertain', 'referenceKind'}
PATH_FIELDS = {'communityID', 'fromNode', 'toNode', 'mode', 'oneWay', 'blocked', 'stairs',
               'confirmed', 'sourceIDs', 'notes'}
CATALOG_FIELDS = {'schemaVersion', 'packVersion', 'generatedAt', 'scopeZIPs', 'deliveryAreaExceptions',
                  'sources', 'communities', 'coverage', 'unitBuildingAssociations'}
ASSOCIATION_FIELDS = {'id', 'communityID', 'address', 'unit', 'building', 'identifierKind', 'sourceIDs', 'referencePlaceID', 'mapFloor'}
BUILDING_REFERENCE_NOTE = 'Assessor legal-building reference derived from official condominium polygons; the area may include courtyard or open space and need not lie on a physical roof. Legal IDs may differ from physical signs; absolute positional accuracy is unknown. This is not a unit position, entrance or exact door.'
COLLECTION_FIELDS = {'type', 'schemaVersion', 'packVersion', 'features'}
GAP = 'Public property identity and available source positions are incomplete. No exact door, entrance or current access condition is established.'
REFERENCE_GAP = 'Community coordinate is a published property reference or source-map reference only; it is not a unit, entrance or delivery destination.'
SOURCE_NOTE = 'Published unit position; not an entrance or exact door. Verify the physical street, unit and building on arrival.'
ESTIMATE_NOTE = 'May be inaccurate. Estimated unit position; not an entrance or exact door. Confirm the physical street, unit and building on arrival.'
PATH_NOTE = 'OpenStreetMap contributors, ODbL 1.0. Published source path, not personally confirmed. Access conditions remain unverified.'
COVERAGE_NOTES = [
    'Public source-derived apartment and multifamily inventory. This is not a certified exhaustive inventory.',
    'Published unit positions retain their source confidence. Estimated positions may be inaccurate; no exact doors or entrances are established.',
    'New Silverado-area records may have only a verified property name and street address. Missing unit maps remain explicit research gaps.',
    'Public map geometry is unconfirmed. OpenStreetMap contributors attribution and ODbL requirements apply to retained OSM paths.',
]
# Mirrors the dedicated compiled-public-bundle reader, not private/import budgets.
RESOURCE_LIMITS = {'public-catalog.json': 2_100_000, 'public-locations.geojson': 64_000_000, 'public-paths.geojson': 16_000_000, 'known-addresses.json': 2_000_000}
RESOURCE_NAMES = ('public-catalog.json', 'public-locations.geojson', 'public-paths.geojson', 'known-addresses.json')


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


def position_note(feature):
    """Construct fixed public text; reserve the reviewed dispute for its exact identity."""
    p = feature['properties']
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
    if 'referenceKind' in p:
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
                    ('operatorPublishedPropertyPoint', 'municipalBoundaryCentroid', 'municipalBoundaryInteriorReference'), 'Unsupported coordinate evidence')
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
                    require(p['referenceKind'] == 'assessorLegalBuildingPolygon' and p['kind'] == 'building' and
                            p['verification'] == 'sourceMapped' and p['unit'] == '' and p['floor'] == '' and
                            bool(p['building'].strip()), 'Unsupported building reference precision')
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
    associations = catalog.get('unitBuildingAssociations', [])
    require(isinstance(associations, list) and len(associations) <= 50_000, 'Invalid building association collection')
    association_ids, association_keys = set(), set()
    points_by_id = {f['id']: f for f in locations['features']}
    def address_key(value):
        # Only spelling/punctuation aliases; no street numbers or unit suffixes are discarded.
        aliases = {'west':'w', 'east':'e', 'north':'n', 'south':'s', 'road':'rd', 'street':'st',
                   'avenue':'ave', 'drive':'dr', 'lane':'ln', 'boulevard':'blvd', 'court':'ct', 'way':'wy', 'parkway':'pkwy'}
        return ' '.join(aliases.get(x, x) for x in re.findall(r'[a-z0-9]+', value.lower()))
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
            require(a['identifierKind'] == 'municipalLegal' and p.get('referenceKind') == 'assessorLegalBuildingPolygon' and
                    p.get('communityID') == a['communityID'] and address_key(p.get('address', '')) == address_key(a['address']) and
                    p.get('building') == a['building'], 'Building association reference mismatch')
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
    for filename in additions:
        extra = read_json(filename, 2_000_000)
        catalog['sources'].extend({k: s[k] for k in SOURCE_FIELD_ORDER} for s in extra['sources'])
        catalog['communities'].extend({k: copy.deepcopy(v) for k, v in c.items() if k in COMMUNITY_FIELDS} for c in extra['communities'])
        for patch in extra.get('communityEnrichments', []):
            require(set(patch) <= {'id', 'deliveryAddresses', 'aliasesToAdd', 'latitude', 'longitude',
                'sourceIDsToAdd', 'coordinateMethod', 'coordinateScope'}, 'Unexpected enrichment fields')
            targets = [c for c in catalog['communities'] if c['id'] == patch['id']]
            require(len(targets) == 1, 'Unknown or duplicate enrichment target')
            target = targets[0]
            for source_key, destination_key in (('deliveryAddresses', 'deliveryAddresses'),
                    ('aliasesToAdd', 'aliases'), ('sourceIDsToAdd', 'sourceIDs')):
                if source_key in patch:
                    require(isinstance(patch[source_key], list) and all(isinstance(v, str) for v in patch[source_key]), 'Invalid enrichment identity list')
                    target[destination_key] = list(dict.fromkeys(target.get(destination_key, []) + patch[source_key]))
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
    refs.update(i for a in catalog.get('unitBuildingAssociations', []) for i in a['sourceIDs'])
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
