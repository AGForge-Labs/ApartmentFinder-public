import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {deriveTuscanoUnitPositions} from '../../scripts/data/county-unit-labels.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';
import {loadEvidence} from './load-evidence.mjs';

const read = async p => JSON.parse(await readFile(new URL('../../' + p, import.meta.url)));
const catalog = await read('data/catalog.json');
const locations = await read('data/locations.geojson');
const evidence = await loadEvidence();
const pack = {catalog, locations, paths: await read('data/paths.geojson')};

test('reported Tuscano deliveries have researched unit pins in the correct buildings', () => {
  const points = ['2066', '2137'].map(unit => locations.features.filter(f =>
    f.properties.communityID === 'tuscano' && f.properties.unit === unit));
  assert.deepEqual(points.map(matches => matches.length), [1, 1]);
  assert.deepEqual(points.map(([f]) => f.properties.building), ['9', '19']);
  assert.notDeepEqual(points[0][0].geometry.coordinates, points[1][0].geometry.coordinates);
  for (const [f] of points) {
    assert.equal(f.properties.kind, 'unitPosition');
    assert.equal(f.properties.verification, 'sourceMapped');
    assert.match(f.properties.notes, /not an entrance or exact door/);
    assert.ok(f.properties.sourceIDs.some(id => catalog.sources.find(s => s.id === id)?.url.includes('GISMO/AssessorAnno')));
  }
});

test('all 352 Tuscano units join exactly once with no guessed floor', () => {
  const points = deriveTuscanoUnitPositions(evidence.countyUnits);
  assert.equal(points.length, 352);
  assert.equal(new Set(points.map(p => p.unit)).size, 352);
  assert.equal(new Set(points.map(p => p.building)).size, 23);
  assert.ok(points.every(p => p.floor === ''));
  const pin = points.find(p => p.unit === '2066');
  assert.equal(pin.annotationObjectID, 2187653);
  assert.ok(Math.abs(pin.coordinates[0] - (-115.24931556308532)) < 1e-12);
  assert.ok(Math.abs(pin.coordinates[1] - 36.06897516053954) < 1e-12);
});

for (const [name, mutate, expected] of [
  ['a unit moved to the community center', (f) => { const c = catalog.communities.find(c => c.id === 'tuscano'); f.geometry.coordinates = [c.longitude, c.latitude]; }, /coordinate changed from source/],
  ['an invented building assignment', f => { f.properties.building = '10'; }, /unsupported unit\/building/],
  ['a floor guessed from the unit number', f => { f.properties.floor = '2'; }, /unsupported floor/],
  ['a broken annotation citation', f => { f.properties.positionDerivation.annotationObjectID = 0; }, /county label derivation mismatch/],
  ['a source label promoted to a verified door', f => { f.properties.kind = 'door'; f.properties.verification = 'fieldVerified'; }, /unsupported precision/],
]) {
  test('rejects ' + name, () => {
    const changed = structuredClone(pack);
    mutate(changed.locations.features.find(f => f.properties.communityID === 'tuscano' && f.properties.unit === '2066'));
    assert.ok(validatePack(changed, evidence).some(error => expected.test(error)));
  });
}

test('a missing or duplicate county label cannot silently choose a unit position', () => {
  const raw = structuredClone(evidence.countyUnits);
  const label = raw.annotations.features.find(f => f.attributes.OBJECTID === 2187653);
  raw.annotations.features.push(structuredClone(label));
  assert.throws(() => deriveTuscanoUnitPositions(raw), /Ambiguous or missing county annotation/);
  raw.annotations.features = raw.annotations.features.filter(f => f.attributes.OBJECTID !== 2187653);
  assert.throws(() => deriveTuscanoUnitPositions(raw), /Ambiguous or missing county annotation/);
});

test('county unit labels must remain inside their own building envelopes', () => {
  const raw = structuredClone(evidence.countyUnits);
  const label = raw.annotations.features.find(f => f.attributes.OBJECTID === 2187653);
  label.geometry.rings = label.geometry.rings.map(ring => ring.map(([lon, lat]) => [lon + 0.001, lat]));
  assert.throws(() => deriveTuscanoUnitPositions(raw), /outside its assigned building/);
});
