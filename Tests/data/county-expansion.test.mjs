import test from 'node:test';
import assert from 'node:assert/strict';
import {loadCountyUnitCoverage, deriveCountyUnitPositions} from '../../scripts/data/county-unit-labels.mjs';

const sourceRoot = new URL('../../research/geography/county-unit-coverage/', import.meta.url);
const snapshots = await loadCountyUnitCoverage(sourceRoot);
const byID = new Map(snapshots.map(raw => [raw.communityID, raw]));
const clone = id => structuredClone(byID.get(id));

test('loader retains exact source queries and all approved county observations', () => {
  assert.equal(snapshots.length, 21);
  assert.equal(byID.size, 21);
  for (const raw of snapshots) {
    assert.ok(raw.annotationURL.startsWith('https://maps.clarkcountynv.gov/arcgis/rest/services/GISMO/AssessorAnno/'));
    assert.ok(raw.unitDirectoryURL.startsWith('https://maps.clarkcountynv.gov/arcgis/rest/services/GISMO/Address/'));
    assert.ok(raw.retrievedAt);
    assert.ok(raw.identity);
    assert.ok(raw.directory.features.length);
    assert.ok(raw.annotations.features.length);
  }
});

test('county directories derive 5,135 approximate source-mapped positions with explicit partial gaps', () => {
  const expected = {
    'morgyn-ridge': 157, 'cimarron-hills': 84, vistana: 732,
    'apache-hills': 88, 'amber-hills': 176, 'coronado-palms': 384,
    'falls-rhodes-ranch': 360, 'southern-vista': 272,
    'ashton-place': 88, 'la-paloma': 156,
    'san-tropez': 336, 'tango-bay': 136, 'spanish-ridge': 180, 'spanish-ridge-7380': 68,
    'michael-b': 252,
    acerno: 188, esplanade: 382, 'portola-russell': 280, 'sunset-cliffs': 366,
    'southwest-ranch': 272, everett: 178,
  };
  const counts = Object.fromEntries(snapshots.map(raw => [raw.communityID, deriveCountyUnitPositions(raw).length]));
  assert.deepEqual(counts, expected);
  assert.equal(Object.values(counts).reduce((a, b) => a + b), 5135);
  for (const raw of snapshots) {
    const points = deriveCountyUnitPositions(raw);
    assert.ok(points.every(p => p.floor === '' && p.address && p.sourceUnitID && p.coordinates.length === 2));
    assert.equal(new Set(points.map(p => p.sourceUnitID)).size, points.length);
  }
});

test('Vistana repeated numbers resolve only through their own address and building polygon', () => {
  const points = deriveCountyUnitPositions(byID.get('vistana'));
  const examples = points.filter(p => p.unit === '102');
  assert.ok(examples.length > 1);
  assert.equal(new Set(examples.map(p => p.address)).size, examples.length);
  assert.equal(new Set(examples.map(p => p.annotationObjectID)).size, examples.length);
});

test('literal UT prefix is normalized only when legal number and contained label agree', () => {
  for (const [id, unit] of [['apache-hills', '140'], ['la-paloma', '110']]) {
    const point = deriveCountyUnitPositions(byID.get(id)).find(p => p.unit === unit);
    assert.equal(point.rawStrunit, 'UT ' + unit);
    assert.equal(point.normalization, 'literalUTPrefix');
    const changed = clone(id);
    changed.directory.features.find(f => f.attributes.strunit.trim() === 'UT ' + unit).attributes.strunit = 'UT 999';
    assert.throws(() => deriveCountyUnitPositions(changed), /legal unit|identity/i);
  }
});

test('identity, count, legal and geometry mutations fail closed', () => {
  const wrongIdentity = clone('morgyn-ridge');
  wrongIdentity.directory.features[0].attributes.subname = 'OTHER CONDO';
  assert.throws(() => deriveCountyUnitPositions(wrongIdentity), /identity/i);

  const wrongStreet = clone('vistana');
  wrongStreet.directory.features[0].attributes.strno = 9999;
  assert.throws(() => deriveCountyUnitPositions(wrongStreet), /identity/i);

  const missing = clone('cimarron-hills');
  missing.directory.features.pop();
  assert.throws(() => deriveCountyUnitPositions(missing), /count|incomplete/i);

  const wrongLegal = clone('amber-hills');
  wrongLegal.directory.features[0].attributes.LEGAL_DESCR3 = 'UNIT 999 BLDG 1';
  assert.throws(() => deriveCountyUnitPositions(wrongLegal), /legal unit/i);

  const shifted = clone('morgyn-ridge');
  const label = shifted.annotations.features.find(f => f.attributes.AnnotationClassID === 21 && f.attributes.TextString.includes('1002'));
  label.geometry.rings = label.geometry.rings.map(r => r.map(([lon, lat]) => [lon + 0.02, lat]));
  assert.throws(() => deriveCountyUnitPositions(shifted), /annotation|contained|outside/i);

  const duplicate = clone('tango-bay');
  const first = duplicate.annotations.features.find(f => f.attributes.AnnotationClassID === 21);
  const other = duplicate.annotations.features.find(f => f.attributes.AnnotationClassID === 17);
  Object.assign(other, structuredClone(first));
  assert.throws(() => deriveCountyUnitPositions(duplicate), /annotation|duplicate|ambiguous/i);
});

test('San Tropez reviewed 1043 remains a distinct county-label exception', () => {
  const raw = byID.get('san-tropez');
  const point = deriveCountyUnitPositions(raw).find(p => p.unit === '1043');
  assert.equal(point.building, '6');
  assert.equal(point.parcel, null);
  assert.equal(point.annotationObjectID, 2183061);
  assert.equal(point.evidenceType, 'reviewedCountyLabelException');
  assert.equal(point.supplementalSourceURLs.length, 1);
  assert.equal(raw.supplementalSources[0].url, point.supplementalSourceURLs[0]);
  assert.ok(!raw.directory.features.some(f => f.attributes.strunit.trim() === '1043'));
});

test('Spanish Ridge parcel labels omit building claims; Michael B excludes four unnumbered rows', () => {
  const spanish = deriveCountyUnitPositions(byID.get('spanish-ridge'));
  assert.equal(spanish.length, 180);
  assert.ok(spanish.every(p => p.building === ''));
  const michael = deriveCountyUnitPositions(byID.get('michael-b'));
  assert.equal(michael.length, 252);
  assert.equal(new Set(michael.map(p => p.address)).size, 14);
  assert.equal(byID.get('michael-b').directory.features.length, 256);
});

test('residential-only county scopes enforce storage and garage exclusions', () => {
  const esplanade = byID.get('esplanade');
  assert.equal(deriveCountyUnitPositions(esplanade).length, 382);
  assert.equal(esplanade.directory.features.length, 590);
  assert.match(esplanade.coverageNotes[0], /208.*storage/);
  const badStorage = clone('esplanade');
  badStorage.directory.features.find(f => f.attributes.LEGAL_DESCR3.trim().startsWith('UNIT ST-')).attributes.strunit = '9Z';
  assert.throws(() => deriveCountyUnitPositions(badStorage), /storage exclusion identity/);

  const portola = byID.get('portola-russell');
  const points = deriveCountyUnitPositions(portola);
  assert.equal(points.length, 280);
  assert.equal(portola.directory.features.length, 360);
  const exception = points.find(p => p.unit === '1001');
  assert.equal(exception.normalization, 'legalOnlyBlankStrunit');
  assert.equal(exception.address, '9620 W RUSSELL RD');
  assert.match(portola.coverageNotes[0], /80.*garage/);
  const badGarage = clone('portola-russell');
  badGarage.directory.features.find(f => f.attributes.LEGAL_DESCR3.trim().startsWith('UNIT G')).attributes.strunit = 'G999';
  assert.throws(() => deriveCountyUnitPositions(badGarage), /garage exclusion identity/);
});

test('Sunset Cliffs keeps 366 safe points and validates its two unlocated numbered units', () => {
  const raw = byID.get('sunset-cliffs');
  const points = deriveCountyUnitPositions(raw);
  assert.equal(points.length, 366);
  assert.ok(!points.some(p => p.unit === '1006' || p.unit === '1007'));
  assert.equal(raw.coverageStatus, 'partial');
  assert.match(raw.coverageNotes[0], /172.*28\.199/);
  assert.match(raw.coverageNotes[0], /39A-D.*unresolved/);
  const changed = clone('sunset-cliffs');
  changed.unresolvedRows.find(row => row.unit === '1006').containedLabels = 1;
  assert.throws(() => deriveCountyUnitPositions(changed), /documented unresolved annotation changed/);
});
