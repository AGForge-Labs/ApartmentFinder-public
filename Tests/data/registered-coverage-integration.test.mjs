import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {loadEvidence} from './load-evidence.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';

const read = async file => JSON.parse(await readFile(new URL('../../' + file, import.meta.url)));
const pack = {catalog: await read('data/catalog.json'), locations: await read('data/locations.geojson'), paths: await read('data/paths.geojson')};
const raw = await loadEvidence();

test('Cabrillo imports registered printed units with explicit approximate provenance', () => {
  const pins = pack.locations.features.filter(f => f.properties.communityID === 'cabrillo');
  assert.equal(pins.length, 242);
  assert.ok(pins.every(f => f.properties.positionDerivation?.type === 'registeredDiagram' &&
    f.properties.verification === 'sourceMapped' && f.properties.floor === ''));
  assert.deepEqual(validatePack(pack, raw), []);
});

test('registered pins cannot drift from calibrated source labels', () => {
  const changed = structuredClone(pack);
  const pin = changed.locations.features.find(f => f.properties.communityID === 'cabrillo' && f.properties.unit === '101');
  assert.ok(pin);
  pin.geometry.coordinates[0] += 0.0001;
  assert.ok(validatePack(changed, raw).some(error => /coordinate changed/.test(error)));
});

test('registered pins cannot claim an unverified floor or lose calibration provenance', () => {
  const changed = structuredClone(pack);
  const pin = changed.locations.features.find(f => f.properties.communityID === 'cabrillo');
  assert.ok(pin);
  pin.properties.floor = '1';
  delete pin.properties.positionDerivation;
  const errors = validatePack(changed, raw);
  assert.ok(errors.some(error => /unsupported floor/.test(error)));
  assert.ok(errors.some(error => /registered.*derivation/.test(error)));
});

test('a diagram pin cannot omit the independent county parcel used to accept it', () => {
  const changed = structuredClone(pack);
  const pin = changed.locations.features.find(f => f.properties.communityID === 'sw');
  const boundaryURL = raw.registeredMaps.find(r => r.communityID === 'sw').propertyBoundary.url;
  const boundaryID = changed.catalog.sources.find(s => s.url === boundaryURL).id;
  pin.properties.sourceIDs = pin.properties.sourceIDs.filter(id => id !== boundaryID);
  assert.ok(validatePack(changed, raw).some(error => /missing registered source provenance/.test(error)));
});

test('every calibrated directory supplies address aliases and a partial-coverage disclosure when needed', () => {
  for (const directory of raw.registeredMaps) {
    const community = pack.catalog.communities.find(c => c.id === directory.communityID);
    assert.ok(community.deliveryAddresses.includes(directory.address));
    assert.ok(community.gapNotes.includes(directory.precision));
    for (const note of directory.unresolved?.notes ?? []) assert.ok(community.gapNotes.includes(note) || community.gapNotes.includes('Strict-registration tier: '+note));
  }
});

test('qualified unit pins expose their official numbering source and cannot omit it', () => {
  const directory = raw.registeredMaps.find(r => r.communityID === 'zerzura');
  const source = pack.catalog.sources.find(s => s.url === directory.unitNumbering.url);
  assert.ok(source, 'official qualified numbering source missing from catalog');
  const pins = pack.locations.features.filter(f => f.properties.communityID === directory.communityID);
  assert.equal(pins.length, 466);
  assert.ok(pins.every(f => f.properties.sourceIDs.includes(source.id)));
  const changed = structuredClone(pack);
  const pin = changed.locations.features.find(f => f.properties.communityID === directory.communityID);
  pin.properties.sourceIDs = pin.properties.sourceIDs.filter(id => id !== source.id);
  assert.ok(validatePack(changed, raw).some(error => /missing registered source provenance/.test(error)));
});

test('coverage reports a building-scoped directory as partial even without transcribing all missing units', async () => {
  const report = await readFile(new URL('../../research/COVERAGE.md', import.meta.url), 'utf8');
  for (const directory of raw.registeredMaps.filter(r => r.unresolved?.unmappedPrintedLabelCount > 0)) {
    const community = pack.catalog.communities.find(c => c.id === directory.communityID);
    const row = report.split('\n').find(line => line.startsWith(`| ${community.name} |`));
    assert.match(row, raw.estimatedMaps.some(d=>d.communityID===community.id) ? /Includes estimates/ : /Partial; unresolved units below/);
  }
});
