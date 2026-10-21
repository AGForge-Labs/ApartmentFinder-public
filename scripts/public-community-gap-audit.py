#!/usr/bin/env python3
"""Deterministic public-only geographic coverage inventory; no personal data is read."""
import argparse
from collections import defaultdict
import json
import math
from pathlib import Path

PRIORITY_ZIPS = ('89123', '89183', '89052', '89014', '89044')


def valid_point(longitude, latitude):
    return (type(longitude) in (int, float) and type(latitude) in (int, float)
            and math.isfinite(longitude) and math.isfinite(latitude)
            and -180 <= longitude <= 180 and -90 <= latitude <= 90)


def build_audit(catalog, features):
    communities = {c['id']: c for c in catalog['communities']}
    points, associations = defaultdict(list), defaultdict(list)
    for feature in features:
        cid = feature['properties']['communityID']
        if cid not in communities:
            raise ValueError('Geographic feature has no catalog community')
        geometry = feature.get('geometry', {})
        coordinate = geometry.get('coordinates', [])
        if geometry.get('type') == 'Point' and len(coordinate) == 2 and valid_point(*coordinate):
            points[cid].append(feature['properties'])
    for association in catalog.get('unitBuildingAssociations', []):
        cid = association['communityID']
        if cid not in communities:
            raise ValueError('Association has no catalog community')
        associations[cid].append(association)
    rows = []
    for cid, community in sorted(communities.items()):
        local = points[cid]
        anchor = valid_point(community.get('longitude'), community.get('latitude'))
        building = [p for p in local if p['kind'] == 'building']
        unit = [p for p in local if p['kind'] == 'unitPosition']
        doors = [p for p in local if p['kind'] == 'door']
        verified = sum(p.get('verification') == 'fieldVerified' for p in doors)
        row = dict(communityID=cid, name=community['name'], address=community['address'], postalZIP=community['zip'],
            countyZIPs=community.get('countyZIPs', []),
            priorityArea=any(z in PRIORITY_ZIPS for z in [community['zip']] + community.get('countyZIPs', [])),
            communityArea=dict(mapped=anchor, coordinate=([community['longitude'], community['latitude']] if anchor else None),
                evidence=community.get('publicEvidence', {}).get('coordinate')),
            buildingAreaReferences=dict(total=len(building),
                qualifiedLegalPolygon=sum(p.get('referenceKind') == 'assessorLegalBuildingPolygon' for p in building)),
            unitPositions=dict(total=len(unit), sourceMapped=sum(p.get('verification') == 'sourceMapped' for p in unit),
                estimated=sum(p.get('verification') == 'estimated' for p in unit)),
            doors=dict(geographicPoints=len(doors), fieldVerified=verified),
            entrances=sum(p['kind'] == 'entrance' for p in local),
            unitBuildingAssociations=dict(total=len(associations[cid]),
                operatorMap=sum(a['identifierKind'] == 'operatorMap' for a in associations[cid]),
                municipalLegal=sum(a['identifierKind'] == 'municipalLegal' for a in associations[cid])),
            gaps=dict(communityAreaMissing=not anchor, buildingAreasMissing=not building,
                unitPositionsMissing=not unit, verifiedPublicDoorsMissing=verified == 0))
        rows.append(row)
    def summary(selected):
        return dict(communities=len(selected), mappedCommunityAreas=sum(r['communityArea']['mapped'] for r in selected),
            missingCommunityAreas=sum(r['gaps']['communityAreaMissing'] for r in selected),
            communitiesWithBuildingAreas=sum(r['buildingAreaReferences']['total'] > 0 for r in selected),
            buildingAreaReferences=sum(r['buildingAreaReferences']['total'] for r in selected),
            unitPositions=sum(r['unitPositions']['total'] for r in selected),
            fieldVerifiedPublicDoors=sum(r['doors']['fieldVerified'] for r in selected),
            unitBuildingAssociations=sum(r['unitBuildingAssociations']['total'] for r in selected))
    return dict(schemaVersion=1, catalogPackVersion=catalog['packVersion'], priorityZIPs=list(PRIORITY_ZIPS),
        scope='Bundled public catalog only; owner-recorded pins and imported private data are excluded.',
        interpretation=[
            'Community coordinates are area references, not building anchors or delivery doors.',
            'Approximate building references are counted separately from unit positions and verified doors.',
            'Unit/building associations supply labels only and do not count as geographic coverage.',
            'Missing public verified doors does not imply that an owner has no saved personal pins.',
            'This inventory does not establish complete apartment or ZIP coverage.'
        ], allCatalog=summary(rows), priorityArea=summary([r for r in rows if r['priorityArea']]), communities=rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('data'))
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = build_audit(json.loads((args.directory / 'public-catalog.json').read_bytes()),
        json.loads((args.directory / 'public-locations.geojson').read_bytes())['features'])
    encoded = json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + '\n'
    if args.output:
        args.output.write_text(encoded, encoding='utf-8', newline='\n')
    else:
        print(encoded, end='')


if __name__ == '__main__':
    main()
