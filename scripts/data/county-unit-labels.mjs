import {coordinateValid,inGeometry,inRing} from './geometry.mjs';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve, sep} from 'node:path';
import {pathToFileURL} from 'node:url';

// County annotation geometry is the printed label's footprint, not the unit boundary.
// Keep the original geometry and recompute its center instead of accepting edited pins.
export function deriveTuscanoUnitPositions(raw) {
  if (raw.communityID !== 'tuscano' || raw.annotations.exceededTransferLimit || raw.directory.exceededTransferLimit) {
    throw Error('Incomplete Tuscano county observations');
  }
  if (raw.annotations.spatialReference?.wkid !== 4326 || raw.directory.spatialReference?.wkid !== 4326) {
    throw Error('Tuscano observations must use WGS84');
  }
  const labels = new Map();
  for (const feature of raw.annotations.features) {
    if (feature.attributes.AnnotationClassID !== 21) continue;
    for (const unit of feature.attributes.TextString.trim().split(/\s+/)) {
      if (!/^\d{4}$/.test(unit)) continue;
      labels.set(unit, [...(labels.get(unit) ?? []), feature]);
    }
  }
  const seen = new Set();
  return raw.directory.features.map(({attributes: row, geometry: buildingGeometry}) => {
    const unit = row.strunit.trim();
    const legal = row.LEGAL_DESCR3.trim().match(/^UNIT (\d+) BLDG (\d+)$/);
    if (seen.has(unit) || !legal || legal[1] !== unit || row.subname.trim() !== 'TUSCANO CONDO' ||
        row.strno !== 7255 || row.strdir.trim() !== 'W' || row.strname.trim() !== 'SUNSET' || row.strtype.trim() !== 'RD' ||
        row.ADFILE.trim() !== '122' || row.ADPAGE.trim() !== '11') {
      throw Error('Ambiguous Tuscano unit/building identity ' + unit);
    }
    seen.add(unit);
    const matches = labels.get(unit) ?? [];
    if (matches.length !== 1) throw Error('Ambiguous or missing county annotation for unit ' + unit);
    const annotation = matches[0];
    const rings = annotation.geometry.rings;
    const ring = rings[0];
    if (rings.length !== 1 || ring.length !== 5 || JSON.stringify(ring[0]) !== JSON.stringify(ring[4]) ||
        ring.some(point => !coordinateValid(point)) || new Set(ring.slice(0, 4).map(p => JSON.stringify(p))).size !== 4) {
      throw Error('Invalid county label geometry for unit ' + unit);
    }
    const corners = ring.slice(0, 4);
    const coordinates = [0, 1].map(axis => corners.reduce((sum, p) => sum + p[axis], 0) / 4);
    if (!inGeometry(coordinates, {type: 'Polygon', coordinates: buildingGeometry.rings})) {
      throw Error('County unit label outside its assigned building ' + unit);
    }
    return {unit, building: legal[2], floor: '', coordinates,
      sourceUnitID: 'county-' + annotation.attributes.OBJECTID + '-' + unit,
      annotationObjectID: annotation.attributes.OBJECTID, parcel: row.APN};
  }).sort((a, b) => a.unit.localeCompare(b.unit));
}

const COUNTY_BASE = 'https://maps.clarkcountynv.gov/arcgis/rest/services/GISMO/';
const DIRECTORY_FIELDS = new Set(['Parcel','APN','strno','strdir','strname','strtype','strunit','subname','LEGAL_DESCR3','ADFILE','ADPAGE']);
const ANNOTATION_FIELDS = new Set(['OBJECTID','FeatureID','AnnotationClassID','TextString','Angle']);
const trim = value => String(value ?? '').trim();
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const assert = (condition, message) => {if (!condition) throw Error(message);};

function coverageRoot(rootURL) {
  if (rootURL instanceof URL) return rootURL;
  if (typeof rootURL === 'string' && rootURL.startsWith('file:')) return new URL(rootURL);
  if (typeof rootURL === 'string') return pathToFileURL(resolve(rootURL) + sep);
  throw Error('County coverage root must be a directory URL or path');
}

async function readChecked(root, filename, digest) {
  assert(/^[a-z0-9][a-z0-9.-]*\.json$/.test(filename), 'Invalid county snapshot filename');
  const bytes = await readFile(new URL(filename, root));
  assert(sha256(bytes) === digest, 'County source snapshot hash mismatch: ' + filename);
  return JSON.parse(bytes);
}

function normalizeLayer(layer, format) {
  if (format === 'paged' || format === 'filtered') return {...layer, queryURLs: [...layer.queryURLs]};
  if (format === 'priority') return {...layer.data, queryURLs: [layer.url], sourceResponseSHA256: layer.sha256, count: layer.data.features.length};
  if (format === 'split') return {...layer.result, queryURLs: [layer.sourceURL], sourceResponseSHA256: layer.sha256, count: layer.result.features.length};
  throw Error('Unsupported county snapshot format ' + format);
}

export async function loadCountyUnitCoverage(rootURL = new URL('../../research/geography/county-unit-coverage/', import.meta.url)) {
  const root = coverageRoot(rootURL);
  const manifest = JSON.parse(await readFile(new URL('manifest.json', root), 'utf8'));
  assert(manifest.version === 1 && Array.isArray(manifest.snapshots), 'Invalid county coverage manifest');
  const seen = new Set();
  const raw = [];
  for (const entry of manifest.snapshots) {
    assert(!seen.has(entry.communityID), 'Duplicate county coverage community ' + entry.communityID);
    seen.add(entry.communityID);
    let source, directory, annotations, retrievedAt, sourceFiles, corroboration = null;
    if (entry.format === 'split') {
      const [address, labels] = await Promise.all([
        readChecked(root, entry.directoryFile, entry.directorySHA256),
        readChecked(root, entry.annotationFile, entry.annotationSHA256),
      ]);
      source = {communityID: entry.communityID};
      directory = normalizeLayer(address, 'split');
      annotations = normalizeLayer(labels, 'split');
      retrievedAt = labels.retrievedAt;
      sourceFiles = [entry.directoryFile, entry.annotationFile];
      if (entry.corroborationFile) {
        const data = await readChecked(root, entry.corroborationFile, entry.corroborationSHA256);
        assert(data.rentcafeIDJoins === entry.expectedRentCafeIDJoins && data.units?.length === entry.expectedPositions,
          'County site-map corroboration count mismatch');
        corroboration = {rentcafeIDJoins: data.rentcafeIDJoins, sourceFile: entry.corroborationFile};
      }
    } else {
      source = await readChecked(root, entry.file, entry.snapshotSHA256);
      directory = normalizeLayer(source.directory, entry.format);
      annotations = normalizeLayer(source.annotations, entry.format);
      retrievedAt = source.retrievedAt;
      sourceFiles = [entry.file];
    }
    assert(source.communityID === entry.communityID, 'County snapshot community identity mismatch');
    assert(directory.queryURLs?.length && annotations.queryURLs?.length, 'County source query URLs missing');
    assert(directory.queryURLs.every(url => url.startsWith(COUNTY_BASE + 'Address/MapServer/2/query?')) &&
      annotations.queryURLs.every(url => url.startsWith(COUNTY_BASE + 'AssessorAnno/MapServer/0/query?')),
      'County source query URL mismatch');
    let exceptionEvidence = null;
    if (entry.reviewedException) {
      exceptionEvidence = await readChecked(root, entry.reviewedException.evidenceFile, entry.reviewedException.evidenceSHA256);
      sourceFiles.push(entry.reviewedException.evidenceFile);
    }
    let directoryExceptionEvidence = null;
    if (entry.reviewedDirectoryException) {
      directoryExceptionEvidence = await readChecked(root, entry.reviewedDirectoryException.evidenceFile,
        entry.reviewedDirectoryException.evidenceSHA256);
      sourceFiles.push(entry.reviewedDirectoryException.evidenceFile);
    }
    let parcelMembership = null;
    if (entry.reviewedParcelMembership) {
      parcelMembership = await readChecked(root, entry.reviewedParcelMembership.evidenceFile,
        entry.reviewedParcelMembership.evidenceSHA256);
      sourceFiles.push(entry.reviewedParcelMembership.evidenceFile);
    }
    raw.push({communityID: entry.communityID, mode: entry.mode, retrievedAt,
      annotationURL: annotations.queryURLs[0], unitDirectoryURL: directory.queryURLs[0],
      annotationQueryURLs: annotations.queryURLs, directoryQueryURLs: directory.queryURLs,
      sourceFiles, identity: structuredClone(entry.identity),
      expectedDirectoryRows: entry.expectedDirectoryRows, expectedAnnotationRows: entry.expectedAnnotationRows,
      expectedUnitRows: entry.expectedUnitRows, expectedPositions: entry.expectedPositions,
      allowedUTPrefixUnits: entry.allowedUTPrefixUnits ?? [], excludedAPNs: entry.excludedAPNs ?? [],
      excludedDirectoryRows: entry.excludedDirectoryRows ?? [], corroboration,
      exclusionRule: entry.exclusionRule ?? null, legalOnlyRows: entry.legalOnlyRows ?? [],
      unresolvedRows: entry.unresolvedRows ?? [], coverageStatus: entry.coverageStatus ?? 'complete',
      coverageNotes: entry.coverageNotes ?? [],
      reviewedException: entry.reviewedException ? {...entry.reviewedException, evidence: exceptionEvidence} : null,
      reviewedDirectoryException: entry.reviewedDirectoryException ?
        {...entry.reviewedDirectoryException, evidence: directoryExceptionEvidence} : null,
      parcelUnitDigits: entry.parcelUnitDigits ?? 4,
      reviewedParcelMembership: parcelMembership,
      supplementalSources: entry.supplementalSources ?? [],
      directory, annotations});
  }
  return raw;
}

function labelCenter(geometry) {
  const rings = geometry?.rings;
  assert(Array.isArray(rings) && rings.length === 1, 'Malformed county annotation geometry');
  const ring = rings[0];
  assert(ring?.length === 5 && JSON.stringify(ring[0]) === JSON.stringify(ring[4]) &&
    ring.every(coordinateValid) && new Set(ring.slice(0, 4).map(p => JSON.stringify(p))).size === 4,
    'Malformed county annotation geometry');
  const corners = ring.slice(0, 4);
  const area = corners.reduce((sum, p, i) => sum + p[0] * corners[(i+1)%4][1] - corners[(i+1)%4][0] * p[1], 0);
  assert(Math.abs(area) > 1e-12, 'Degenerate county annotation geometry');
  return [0, 1].map(axis => corners.reduce((sum, p) => sum + p[axis], 0) / 4);
}

function validateDirectoryPolygon(geometry) {
  assert(Array.isArray(geometry?.rings) && geometry.rings.length > 0 &&
    geometry.rings.every(ring => ring.length >= 4 && JSON.stringify(ring[0]) === JSON.stringify(ring.at(-1)) && ring.every(coordinateValid)),
    'Malformed county directory geometry');
}

// ArcGIS may encode one property's disjoint building footprints as multiple
// exterior rings (Spanish Ridge has 23), with holes represented by nesting.
function inCountyRings(point, geometry) {
  return geometry.rings.reduce((inside, ring) => inside !== inRing(point, ring), false);
}

function physicalAddress(row, raw) {
  const legalOnly = raw.legalOnlyRows.find(item => item.APN === trim(row.APN));
  const direction = trim(row.strdir) || (legalOnly?.missingDirection ? raw.identity.street.direction : '');
  return [row.strno, direction, row.strname, row.strtype].map(trim).filter(Boolean).join(' ');
}

function validateIdentity(raw, selectedRows) {
  const expected = raw.identity;
  assert(expected?.street?.numbers?.length && expected.subdivisionPlats?.length && expected.apnPrefixes?.length,
    'Missing independent county identity constraints');
  const streetCounts = new Map(expected.street.numbers.map(([number, count]) => [number, count]));
  const platCounts = new Map(expected.subdivisionPlats.map(([name, file, page, count]) =>
    [JSON.stringify([name, file, page]), count]));
  const observedStreet = new Map();
  const observedPlat = new Map();
  for (const feature of raw.directory.features) {
    const row = feature.attributes;
    assert(Object.keys(row).every(field => DIRECTORY_FIELDS.has(field)), 'County directory contains unsupported fields');
    validateDirectoryPolygon(feature.geometry);
    const legalOnly = raw.legalOnlyRows.find(item => item.APN === trim(row.APN));
    const directionMatches = trim(row.strdir) === expected.street.direction ||
      (legalOnly?.missingDirection && !trim(row.strdir));
    assert(directionMatches && trim(row.strname) === expected.street.name &&
      trim(row.strtype) === expected.street.type && streetCounts.has(row.strno),
    'County street identity mismatch');
    const plat = JSON.stringify([trim(row.subname), trim(row.ADFILE), trim(row.ADPAGE)]);
    assert(platCounts.has(plat), 'County subdivision/plat identity mismatch');
    observedPlat.set(plat, (observedPlat.get(plat) ?? 0) + 1);
    assert(expected.apnPrefixes.some(prefix => trim(row.APN).startsWith(prefix)) && trim(row.Parcel) === trim(row.APN),
      'County parcel identity mismatch');
  }
  for (const feature of raw.mode === 'parcelLabels' ? raw.directory.features : selectedRows) {
    const number = feature.attributes.strno;
    observedStreet.set(number, (observedStreet.get(number) ?? 0) + 1);
  }
  for (const [number, count] of streetCounts) assert(observedStreet.get(number) === count, 'County street identity count mismatch ' + number);
  for (const [plat, count] of platCounts) assert(observedPlat.get(plat) === count, 'County subdivision/plat identity count mismatch ' + plat);
  if (expected.exactAPN) {
    assert(raw.directory.features.length === 1 && trim(raw.directory.features[0].attributes.APN) === expected.exactAPN &&
      trim(raw.directory.features[0].attributes.LEGAL_DESCR3) === expected.legalDescription,
      'County parcel legal identity mismatch');
  }
  const apns = raw.directory.features.map(f => trim(f.attributes.APN));
  assert(new Set(apns).size === apns.length, 'Duplicate county parcel identity');
}

function labelIndex(raw) {
  const byUnit = new Map();
  const ids = new Set();
  for (const feature of raw.annotations.features) {
    const row = feature.attributes;
    assert(Object.keys(row).every(field => ANNOTATION_FIELDS.has(field)), 'County annotation contains unsupported fields');
    assert(Number.isInteger(row.OBJECTID) && !ids.has(row.OBJECTID), 'Duplicate or invalid county annotation OBJECTID');
    ids.add(row.OBJECTID);
    if (row.AnnotationClassID !== 21) continue;
    const tokens = trim(row.TextString).split(/\s+/);
    if (!tokens.some(token => /^\d+$/.test(token))) continue;
    const coordinates = labelCenter(feature.geometry);
    for (const token of tokens) {
      if (/^\d+$/.test(token)) byUnit.set(token, [...(byUnit.get(token) ?? []), {feature, coordinates}]);
    }
  }
  return byUnit;
}

function makePoint(raw, feature, unit, building, annotation, coordinates, normalization = null) {
  const row = feature.attributes;
  return {unit, building, floor: '', coordinates,
    sourceUnitID: 'county-' + annotation.attributes.OBJECTID + '-' + unit,
    annotationObjectID: annotation.attributes.OBJECTID, parcel: trim(row.APN),
    address: physicalAddress(row, raw), rawStrunit: trim(row.strunit),
    subdivision: trim(row.subname), buildingKey: [trim(row.subname), physicalAddress(row, raw), building].join('|'),
    ...(normalization ? {normalization} : {})};
}

function strictDirectoryPoints(raw, labels, selectedRows) {
  const points = [];
  const buildingPolygons = new Map();
  const buildingRows = new Map();
  const composite = new Set();
  const unresolved = new Map(raw.unresolvedRows.map(item => [item.APN, item]));
  const observedUnresolved = new Set();
  const directoryException = raw.reviewedDirectoryException;
  let observedDirectoryException = false;
  if (directoryException) {
    const evidence = directoryException.evidence;
    assert(evidence?.communityID === raw.communityID && evidence.unit === directoryException.unit &&
      evidence.rawStrunit === directoryException.unit && evidence.building === directoryException.building &&
      evidence.parcel === directoryException.parcel && evidence.rawLegalDescription === directoryException.rawLegalDescription &&
      evidence.sourceAnnotationObjectID === directoryException.annotationObjectID &&
      evidence.sourceAnnotationText === directoryException.unit && evidence.legalCorrection === false &&
      evidence.sourceSitePlanURL === directoryException.sitePlanURL && directoryException.reviewedAt &&
      raw.supplementalSources.some(source => source.url === directoryException.sitePlanURL &&
        source.sha256 === evidence.sourceSitePlanSHA256), 'Reviewed county directory exception evidence mismatch');
  }
  for (const feature of selectedRows) {
    const row = feature.attributes;
    const rawUnit = trim(row.strunit);
    const legal = trim(row.LEGAL_DESCR3).match(/^UNIT (\d+) BLDG ([A-Z0-9]+)$/);
    assert(legal, 'County legal unit/building identity missing: ' + rawUnit);
    let unit = legal[1];
    const building = legal[2];
    let normalization = null;
    const isReviewedConflict = directoryException?.parcel === trim(row.APN);
    if (isReviewedConflict) {
      assert(!observedDirectoryException && rawUnit !== unit && rawUnit === directoryException.unit &&
        building === directoryException.building && trim(row.LEGAL_DESCR3) === directoryException.rawLegalDescription,
        'Reviewed county directory exception no longer matches its physical/legal conflict');
      const buildingLabels = raw.annotations.features.filter(item => item.attributes.AnnotationClassID === 17 &&
        trim(item.attributes.TextString) === building && inCountyRings(labelCenter(item.geometry), feature.geometry));
      assert(buildingLabels.length === 1, 'Reviewed county directory exception building label ambiguous');
      unit = rawUnit;
      normalization = 'reviewedPhysicalUnitConflict';
      observedDirectoryException = true;
    } else if (rawUnit !== unit) {
      const legalOnly = raw.legalOnlyRows.find(item => item.APN === trim(row.APN));
      if (!rawUnit && legalOnly?.unit === unit && legalOnly.building === building) {
        const buildingLabels = raw.annotations.features.filter(item => item.attributes.AnnotationClassID === 17 &&
          trim(item.attributes.TextString) === building && inCountyRings(labelCenter(item.geometry), feature.geometry));
        assert(buildingLabels.length === 1, 'County legal-only building label ambiguous ' + unit);
        normalization = 'legalOnlyBlankStrunit';
      } else {
        assert(rawUnit === 'UT ' + unit && raw.allowedUTPrefixUnits.includes(unit),
          'County legal unit conflicts with strunit: ' + rawUnit);
        normalization = 'literalUTPrefix';
      }
    }
    const address = physicalAddress(row, raw);
    const key = [trim(row.subname), address, building].join('|');
    const shape = JSON.stringify(feature.geometry);
    if (buildingPolygons.has(key)) assert(buildingPolygons.get(key) === shape, 'County building geometry conflict ' + key);
    else buildingPolygons.set(key, shape);
    buildingRows.set(key, [...(buildingRows.get(key) ?? []), feature]);
    const compositeKey = key + '|' + unit;
    assert(!composite.has(compositeKey), 'Duplicate county building/unit identity ' + compositeKey);
    composite.add(compositeKey);
    const matches = (labels.get(unit) ?? []).filter(({coordinates}) => inCountyRings(coordinates, feature.geometry));
    const unresolvedRow = unresolved.get(trim(row.APN));
    if (unresolvedRow) {
      assert(unresolvedRow.unit === unit && matches.length === unresolvedRow.containedLabels,
        'County documented unresolved annotation changed ' + unit);
      observedUnresolved.add(trim(row.APN));
      continue;
    }
    assert(matches.length === 1, 'Ambiguous or missing contained county annotation for ' + compositeKey);
    const point = makePoint(raw, feature, unit, building, matches[0].feature, matches[0].coordinates, normalization);
    if (isReviewedConflict) {
      assert(matches[0].feature.attributes.OBJECTID === directoryException.annotationObjectID &&
        trim(matches[0].feature.attributes.TextString) === unit,
        'Reviewed county directory exception annotation mismatch');
      Object.assign(point, {rawLegalDescription: trim(row.LEGAL_DESCR3),
        evidenceType: 'reviewedCountyPhysicalUnitConflict', supplementalSourceURLs: [directoryException.sitePlanURL]});
    }
    points.push(point);
  }
  assert(observedUnresolved.size === unresolved.size, 'County documented unresolved row missing');
  assert(!directoryException || observedDirectoryException, 'Reviewed county directory exception row missing');
  return {points, buildingPolygons, buildingRows};
}

function appendReviewedException(raw, labels, strict) {
  const exception = raw.reviewedException;
  if (!exception) return;
  const evidence = exception.evidence;
  assert(evidence?.communityID === raw.communityID && evidence.unit === exception.unit &&
    evidence.building === exception.building && evidence.sourceAnnotationObjectID === exception.annotationObjectID &&
    evidence.sourceSitePlanURL === exception.sitePlanURL && exception.reviewedAt &&
    raw.supplementalSources.some(source => source.url === exception.sitePlanURL && source.sha256 === evidence.sourceSitePlanSHA256),
    'Reviewed county exception evidence mismatch');
  assert(!strict.points.some(point => point.unit === exception.unit), 'Reviewed county exception already has directory unit');
  const candidates = (labels.get(exception.unit) ?? []).filter(({feature}) => feature.attributes.OBJECTID === exception.annotationObjectID);
  assert(candidates.length === 1 && trim(candidates[0].feature.attributes.TextString) === exception.unit,
    'Reviewed county exception annotation mismatch');
  const matchingBuildings = [...strict.buildingRows].filter(([key, rows]) =>
    rows[0].attributes.LEGAL_DESCR3?.trim().endsWith('BLDG ' + exception.building) &&
    inCountyRings(candidates[0].coordinates, rows[0].geometry));
  assert(matchingBuildings.length === 1 && matchingBuildings[0][1].length === exception.expectedBuildingDirectoryRows,
    'Reviewed county exception building containment ambiguous');
  const [key, rows] = matchingBuildings[0];
  const row = rows[0].attributes;
  const address = physicalAddress(row, raw);
  strict.points.push({unit: exception.unit, building: exception.building, floor: '',
    coordinates: candidates[0].coordinates, sourceUnitID: 'county-' + exception.annotationObjectID + '-' + exception.unit,
    annotationObjectID: exception.annotationObjectID, parcel: null, address,
    rawStrunit: null, subdivision: trim(row.subname), buildingKey: key,
    evidenceType: 'reviewedCountyLabelException', supplementalSourceURLs: [exception.sitePlanURL]});
}

function parcelLabelPoints(raw, labels) {
  const feature = raw.directory.features[0];
  const digits = raw.parcelUnitDigits ?? 4;
  assert([3, 4].includes(digits), 'Unsupported county parcel unit digits');
  const unitPattern = new RegExp('^\\d{' + digits + '}$');
  const points = [];
  for (const [unit, candidates] of labels) {
    if (!unitPattern.test(unit)) continue;
    const contained = candidates.filter(({coordinates}) => inCountyRings(coordinates, feature.geometry));
    assert(contained.length === 1, 'Ambiguous or missing county parcel annotation for ' + unit);
    points.push(makePoint(raw, feature, unit, '', contained[0].feature, contained[0].coordinates));
  }
  const membership = raw.reviewedParcelMembership;
  if (membership) {
    assert(membership.communityID === raw.communityID && membership.reviewedAt &&
      raw.supplementalSources.some(source => source.url === membership.sourceSitePlanURL &&
        source.sha256 === membership.sourceSitePlanSHA256), 'Reviewed parcel membership source mismatch');
    const available = new Set(points.map(point => point.unit)), assigned = new Map(), seenBuildings = new Set();
    for (const group of membership.buildings) {
      const buildingLabels = raw.annotations.features.filter(item => item.attributes.AnnotationClassID === 17 &&
        trim(item.attributes.TextString) === group.building);
      assert(!seenBuildings.has(group.building) && buildingLabels.length === 1 &&
        Array.isArray(group.units) && group.units.length > 0, 'Ambiguous reviewed parcel building membership');
      seenBuildings.add(group.building);
      for (const unit of group.units) {
        assert(available.has(unit) && !assigned.has(unit), 'Duplicate or unsupported reviewed parcel unit membership');
        assigned.set(unit, group.building);
      }
    }
    const unresolved = new Set();
    for (const item of membership.unresolved ?? []) {
      assert(available.has(item.unit) && !assigned.has(item.unit) && !unresolved.has(item.unit) && item.reason,
        'Invalid unresolved parcel membership');
      unresolved.add(item.unit);
    }
    assert(assigned.size + unresolved.size === points.length, 'Incomplete reviewed parcel membership');
    for (const point of points) {
      if (!assigned.has(point.unit)) {
        point.membershipUncertainty = membership.unresolved.find(item => item.unit === point.unit).reason;
        continue;
      }
      point.building = assigned.get(point.unit);
      point.buildingKey = [point.subdivision, point.address, point.building].join('|');
      point.supplementalSourceURLs = [membership.sourceSitePlanURL];
    }
  }
  return points;
}

function ruledExclusions(raw) {
  const rule = raw.exclusionRule;
  if (!rule) return new Set();
  const excluded = [];
  for (const feature of raw.directory.features) {
    const row = feature.attributes;
    const legal = trim(row.LEGAL_DESCR3);
    const unit = trim(row.strunit);
    let match;
    if (rule.type === 'storageST') {
      match = legal.match(/^UNIT ST-([A-Z]) BLDG (\d+)$/);
      if (match) assert(unit === match[2] + match[1], 'County storage exclusion identity mismatch');
    } else if (rule.type === 'garageG') {
      match = legal.match(/^UNIT (G\d+) BLDG (\d+)$/);
      if (match) assert(unit === match[1], 'County garage exclusion identity mismatch');
    } else if (rule.type === 'unresolvedLetterUnits') {
      match = legal.match(/^UNIT (\d+)-([A-Z])$/);
      if (match) assert(unit === match[1] + match[2], 'County letter-unit exclusion identity mismatch');
    } else throw Error('Unsupported county exclusion rule');
    if (match) excluded.push(row);
  }
  const fingerprint = excluded.map(row => [trim(row.APN), trim(row.strunit), trim(row.LEGAL_DESCR3)].join('|')).sort().join('\n');
  assert(excluded.length === rule.count && sha256(fingerprint) === rule.rowsSHA256,
    'County exclusion count or identity fingerprint mismatch');
  return new Set(excluded.map(row => trim(row.APN)));
}

export function deriveCountyUnitPositions(raw) {
  assert(raw && raw.communityID && raw.identity && ['unitDirectory','parcelLabels'].includes(raw.mode),
    'Invalid county coverage observation');
  for (const [name, expected] of [['directory', raw.expectedDirectoryRows], ['annotations', raw.expectedAnnotationRows]]) {
    const layer = raw[name];
    assert(layer?.spatialReference?.wkid === 4326 && !layer.exceededTransferLimit &&
      Array.isArray(layer.features) && layer.features.length === expected && layer.count === expected,
      'Incomplete or non-WGS84 county ' + name + ' count');
  }
  const ruled = ruledExclusions(raw);
  const excluded = new Set([...raw.excludedAPNs, ...ruled]);
  const excludedLegal = new Map(raw.excludedDirectoryRows);
  assert(excludedLegal.size === raw.excludedAPNs.length && raw.excludedAPNs.every(apn => excludedLegal.has(apn)) &&
    [...ruled].every(apn => !excludedLegal.has(apn)),
    'County excluded-row identity constraints missing');
  const selectedRows = raw.directory.features.filter(feature => !excluded.has(trim(feature.attributes.APN)));
  assert(raw.directory.features.length - selectedRows.length === excluded.size &&
    (raw.mode === 'parcelLabels' ? raw.expectedUnitRows === 0 && selectedRows.length === 1 :
      selectedRows.length === raw.expectedUnitRows), 'County unit directory count gap');
  for (const feature of raw.directory.features) {
    const isExcluded = excluded.has(trim(feature.attributes.APN));
    if (isExcluded && excludedLegal.has(trim(feature.attributes.APN))) assert(!trim(feature.attributes.strunit) &&
      trim(feature.attributes.LEGAL_DESCR3) === excludedLegal.get(trim(feature.attributes.APN)),
      'Excluded county row identity mismatch');
    else if (isExcluded) assert(ruled.has(trim(feature.attributes.APN)), 'County ruled exclusion missing');
    else if (raw.mode === 'unitDirectory') assert(trim(feature.attributes.strunit) ||
      raw.legalOnlyRows.some(item => item.APN === trim(feature.attributes.APN)), 'County unit row missing strunit');
    else assert(!trim(feature.attributes.strunit), 'County parcel-label mode has a unit directory');
  }
  validateIdentity(raw, selectedRows);
  const labels = labelIndex(raw);
  let points;
  if (raw.mode === 'parcelLabels') points = parcelLabelPoints(raw, labels);
  else {
    const strict = strictDirectoryPoints(raw, labels, selectedRows);
    appendReviewedException(raw, labels, strict);
    points = strict.points;
  }
  assert(points.length === raw.expectedPositions, 'County derived position count gap ' + raw.communityID);
  assert(new Set(points.map(point => point.sourceUnitID)).size === points.length,
    'Reused county annotation/unit identity');
  return points.sort((a, b) => a.address.localeCompare(b.address) || a.unit.localeCompare(b.unit));
}
