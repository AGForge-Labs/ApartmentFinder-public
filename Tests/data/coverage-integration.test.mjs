import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {loadEvidence} from './load-evidence.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';

const read = async path => JSON.parse(await readFile(new URL('../../' + path, import.meta.url)));
const pack = {catalog: await read('data/catalog.json'), locations: await read('data/locations.geojson'), paths: await read('data/paths.geojson')};
const raw = await loadEvidence();
const units = id => pack.locations.features.filter(f => f.properties.communityID === id);

test('new manifests can use full researched directories, beyond one delivery sample', () => {
  const expected = {'san-tropez':336, 'tango-bay':136, 'spanish-ridge':180, 'south-beach':220,
    'morgyn-ridge':157, 'cimarron-hills':84, vistana:732, 'apache-hills':88, 'amber-hills':176,
    'coronado-palms':384, 'falls-rhodes-ranch':360, 'southern-vista':272, 'ashton-place':88,
    'la-paloma':156, 'michael-b':252, acerno:188, esplanade:382, 'portola-russell':280, 'sunset-cliffs':366};
  for (const [id, count] of Object.entries(expected)) assert.equal(units(id).length, count, id);
  assert.equal(units('2one5').length, 492);
  assert.equal(units('envision-at-sunset').length, 384);
});

test('repeated Vistana unit numbers retain distinct physical street addresses', () => {
  const candidates = units('vistana').filter(f => f.properties.unit === '102');
  assert.ok(candidates.length > 1);
  assert.equal(new Set(candidates.map(f => f.properties.address)).size, candidates.length);
  const community = pack.catalog.communities.find(c => c.id === 'vistana');
  assert.deepEqual(community.deliveryAddresses, [...new Set(units('vistana').map(f => f.properties.address))].sort());
  assert.deepEqual(validatePack(pack, raw), []);
});

test('a repeated unit cannot be relabeled with another building street address', () => {
  const changed = structuredClone(pack);
  const candidates = changed.locations.features.filter(f => f.properties.communityID === 'vistana' && f.properties.unit === '102');
  assert.ok(candidates.length > 1);
  candidates[0].properties.address = candidates[1].properties.address;
  assert.ok(validatePack(changed, raw).some(e => /location address mismatch/.test(e)));
});

test('catalog cannot advertise unresearched delivery-address aliases', () => {
  const changed = structuredClone(pack);
  changed.catalog.communities.find(c => c.id === 'vistana').deliveryAddresses = ['9999 Wrong Street'];
  assert.ok(validatePack(changed, raw).some(e => /delivery address/.test(e)));
});

test('expanded county positions never assert an inferred floor or checked doorway', () => {
  const county = pack.locations.features.filter(f => f.properties.positionDerivation?.type === 'countyLabelCenter');
  assert.ok(county.length > 3500);
  assert.ok(county.every(f => f.properties.floor === '' && f.properties.kind === 'unitPosition' && f.properties.verification === 'sourceMapped'));
});
