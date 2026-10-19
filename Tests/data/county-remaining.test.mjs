import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {loadCountyUnitCoverage, deriveCountyUnitPositions} from '../../scripts/data/county-unit-labels.mjs';

const observations = await loadCountyUnitCoverage();
const southwest = observations.find(raw => raw.communityID === 'southwest-ranch');
const conflictingRow = raw => raw.directory.features.find(f => f.attributes.APN === '16331111173');

test('hashed county snapshots use stable LF bytes on every checkout', async () => {
  const root = new URL('../../research/geography/county-unit-coverage/', import.meta.url);
  const files = new Set(observations.flatMap(raw => raw.sourceFiles));
  assert.ok(files.size > 0);
  for (const file of files) {
    const bytes = await readFile(new URL(file, root));
    assert.equal(bytes.includes(Buffer.from('\r\n')), false, file + ' changes under Git LF normalization');
  }
});

test('Southwest Ranch keeps 272 physical unit labels and preserves the one legal discrepancy', () => {
  const points = deriveCountyUnitPositions(southwest);
  assert.equal(points.length, 272);
  const point = points.find(p => p.unit === '2085');
  assert.equal(point.building, '12');
  assert.equal(point.annotationObjectID, 2183748);
  assert.equal(point.rawStrunit, '2085');
  assert.equal(point.rawLegalDescription, 'UNIT 2086 BLDG 12');
  assert.equal(point.parcel, '16331111173');
  assert.equal(point.evidenceType, 'reviewedCountyPhysicalUnitConflict');
  assert.equal(point.normalization, 'reviewedPhysicalUnitConflict');
  assert.deepEqual(point.supplementalSourceURLs, ['https://www.maprika.com/maps3/map6266.jpg']);
  assert.equal(points.filter(p => p.evidenceType === point.evidenceType).length, 1);
  assert.ok(point.coordinates[0] < points.find(p => p.unit === '2086').coordinates[0]);
  assert.ok(points.every(p => p.floor === '' && p.address === '9925 W RUSSELL RD'));
  assert.equal(conflictingRow(southwest).attributes.LEGAL_DESCR3.trim(), 'UNIT 2086 BLDG 12');
});

test('a physical-unit exception cannot repair another row, change a number, or lose its corroboration', () => {
  for (const change of [
    raw => {raw.reviewedDirectoryException = null;},
    raw => {conflictingRow(raw).attributes.strunit = '2084';},
    raw => {conflictingRow(raw).attributes.LEGAL_DESCR3 = 'UNIT 2085 BLDG 12';},
    raw => {raw.reviewedDirectoryException.parcel = '16331111174';},
    raw => {raw.reviewedDirectoryException.evidence.sourceSitePlanSHA256 = '0'.repeat(64);},
    raw => {raw.reviewedDirectoryException.evidence.rawLegalDescription = 'UNIT 2085 BLDG 12';},
    raw => {raw.supplementalSources = [];},
    raw => {raw.annotations.features.find(f => f.attributes.OBJECTID === 2183748).attributes.TextString = '2086';},
    raw => {raw.annotations.features.find(f => f.attributes.OBJECTID === 2183748).attributes.OBJECTID = 99999999;},
  ]) {
    const raw = structuredClone(southwest);
    change(raw);
    assert.throws(() => deriveCountyUnitPositions(raw), /exception|conflict|legal unit|annotation|corroboration/i);
  }
});

test('Everett derives every one of its 178 independently named condo units', () => {
  const raw = observations.find(r => r.communityID === 'everett');
  const points = deriveCountyUnitPositions(raw);
  assert.equal(points.length, 178);
  assert.equal(new Set(points.map(p => p.building)).size, 16);
  assert.equal(new Set(points.map(p => p.unit)).size, 178);
  assert.ok(points.every(p => p.address === '7227 W WINDMILL LN' && p.floor === '' && !p.normalization));
});

test('Sunset Cliffs residential exclusions retain all 172 classified rows and four unresolved exceptions', async () => {
  const root = new URL('../../research/geography/county-unit-coverage/', import.meta.url);
  const bytes = await readFile(new URL('sunset-cliffs-land-use-query.json', root));
  const query = JSON.parse(bytes);
  const report = JSON.parse(await readFile(new URL('sunset-cliffs-classification.json', root)));
  const raw = observations.find(r => r.communityID === 'sunset-cliffs');
  assert.equal(createHash('sha256').update(bytes).digest('hex'), raw.supplementalSources[0].sha256);
  assert.equal(query.features.length, 544);
  assert.ok(!query.exceededTransferLimit);
  const directory = new Map(raw.directory.features.map(f => [f.attributes.APN, f.attributes]));
  for (const {attributes: row} of query.features) {
    const source = directory.get(row.APN);
    assert.ok(source);
    for (const key of ['strunit', 'LEGAL_DESCR3', 'subname']) assert.equal(row[key], source[key]);
    assert.ok(!Object.hasOwn(row, 'owner') && !Object.hasOwn(row, 'owner2'));
  }
  const minor = query.features.filter(f => f.attributes.STATELANDUSE === '28.199');
  assert.equal(minor.length, 172);
  assert.deepEqual(new Set(report.excludedResidentialMinorImprovements.map(r => r.parcel)),
    new Set(minor.map(f => f.attributes.APN)));
  const unresolved = query.features.filter(f => /UNIT \d+-[A-Z]/.test(f.attributes.LEGAL_DESCR3) &&
    f.attributes.STATELANDUSE === '21.170.C');
  assert.deepEqual(unresolved.map(f => f.attributes.strunit.trim()), ['39A', '39B', '39C', '39D']);
  assert.deepEqual(report.remainingClassificationConflicts.map(r => r.unit), ['39A', '39B', '39C', '39D']);
});
