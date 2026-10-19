import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {loadEvidence} from './load-evidence.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';

const read = async path => JSON.parse(await readFile(new URL('../../' + path, import.meta.url), 'utf8'));
const pack = {catalog:await read('data/catalog.json'), locations:await read('data/locations.geojson'), paths:await read('data/paths.geojson')};
const evidence = await loadEvidence();
// Independently read literal printed tokens; no completion of numeric sequences.
const literalByBuilding = {
  '1':'102 202 302 105 205 305 201 301 203 303 204 304',
  '2':'107 207 307 110 210 208 308 209 309 206',
  '3':'115 215 315 112 212 312 211 311 214 314 313 213 113',
  '4':'219 319 218 318 216 120 220 320 217 117',
  '5':'224 324 223 323 221 125 225 325 222 122',
  '6':'127 227 327 130 230 228 328 229 329 226',
  '7':'135 235 335 134 234 334 233 333 132 232 332 231 331',
  '8':'140 240 340 236 336 239 339 137 237 337 238 338'
};
const martin = () => pack.locations.features.filter(f=>f.properties.communityID==='martin-fort-apache');

test('Martin adds only its ninety literal labels in forty-two estimated bays', () => {
  const pins = martin();
  assert.equal(pins.length,90);
  assert.equal(new Set(pins.map(f=>JSON.stringify(f.geometry.coordinates))).size,42);
  assert.equal(new Set(pins.map(f=>f.properties.unit)).size,90);
  for (const [building,literal] of Object.entries(literalByBuilding)) {
    assert.deepEqual(pins.filter(f=>f.properties.building===building).map(f=>f.properties.unit).sort(), literal.split(' ').sort());
  }
  for (const pin of pins) {
    assert.equal(pin.properties.verification,'estimated');
    assert.equal(pin.properties.kind,'unitPosition');
    assert.equal(pin.properties.floor,'');
    assert.equal(pin.properties.identityUncertain,false);
    assert.equal(pin.properties.positionDerivation.type,'estimatedDiagram');
    assert.equal(pin.properties.positionDerivation.sourceUnit,pin.properties.unit);
    assert.match(pin.properties.notes,/May be inaccurate/);
    assert.match(pin.properties.notes,/advisory radius, not a validated accuracy bound/);
    assert.match(pin.properties.notes,/not an entrance or exact door/);
    assert.doesNotMatch(pin.properties.notes,/NOT IMPORTED/);
  }
  const community = pack.catalog.communities.find(c=>c.id==='martin-fort-apache');
  assert.equal(community.researchStatus,'estimatedUnits');
  assert.deepEqual(validatePack(pack,evidence),[]);
});

test('Martin has public aerial corroboration without strict, floor or entrance promotion', async () => {
  assert.equal(martin().length,90);
  const dataset = await read('research/geography/estimated-unit-maps/martin-fort-apache.json');
  assert.equal(dataset.method.strictRegistrationAccepted,false);
  assert.ok(dataset.sources.some(s=>s.kind==='publicAerialImagery'));
  assert.ok(dataset.sources.some(s=>s.kind==='publicAerialExtentMetadata'));
  assert.equal(dataset.sourceArtworkPrintedDate,'051116');
  for (const change of [
    f=>f.properties.verification='sourceMapped',
    f=>f.properties.kind='door',
    f=>f.properties.floor='1',
    f=>f.properties.notes='Approximate, not an entrance or exact door.'
  ]) {
    const altered = structuredClone(pack);
    change(altered.locations.features.find(f=>f.properties.communityID==='martin-fort-apache'));
    assert.ok(validatePack(altered,evidence).length>0);
  }
});
