import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {loadEvidence} from './load-evidence.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';

const read = async path => JSON.parse(await readFile(new URL('../../' + path, import.meta.url), 'utf8'));
const pack = {catalog:await read('data/catalog.json'), locations:await read('data/locations.geojson'), paths:await read('data/paths.geojson')};
const evidence = await loadEvidence();
const expected = ['13:1203','13:1204','15:1241','15:1242','6:1098','6:1097','9:1135','9:1136'];
const maverick = () => pack.locations.features.filter(f=>f.properties.communityID==='maverick');

test('Maverick adds eight explicit carriage labels as estimates with literal directional order', () => {
  const pins = maverick();
  assert.equal(pins.length,8);
  assert.deepEqual(pins.map(f=>f.properties.building+':'+f.properties.unit).sort(),expected.toSorted());
  assert.equal(new Set(pins.map(f=>JSON.stringify(f.geometry.coordinates))).size,8);
  for (const pin of pins) {
    assert.equal(pin.properties.verification,'estimated');
    assert.equal(pin.properties.kind,'unitPosition');
    assert.equal(pin.properties.floor,'');
    assert.equal(pin.properties.identityUncertain,false);
    assert.equal(pin.properties.positionDerivation.type,'estimatedDiagram');
    assert.equal(pin.properties.positionDerivation.uncertaintyMeters,20);
    assert.equal(pin.properties.positionDerivation.sourceUnit,pin.properties.unit);
    assert.match(pin.properties.notes,/May be inaccurate/);
    assert.match(pin.properties.notes,/advisory and not measured image accuracy/);
    assert.match(pin.properties.notes,/not an entrance or exact door/);
  }
  const coordinate = unit=>pins.find(f=>f.properties.unit===unit).geometry.coordinates;
  assert.ok(coordinate('1098')[0]<coordinate('1097')[0]);
  assert.ok(coordinate('1135')[1]>coordinate('1136')[1]);
  assert.deepEqual(validatePack(pack,evidence),[]);
});

test('Maverick conserves all 344 identities while withholding native coordinates and 336 bays', async () => {
  assert.equal(maverick().length,8);
  const dataset = await read('research/geography/estimated-unit-maps/maverick.json');
  assert.equal(dataset.nativeCoordinateDecision.acceptedNativeCoordinates,0);
  assert.equal(dataset.nativeCoordinateDecision.sourceLabelCount,344);
  assert.equal(dataset.nativeCoordinateDecision.wholePropertyRegistrationAccepted,false);
  assert.equal(dataset.method.strictRegistrationAccepted,false);
  const deferred = dataset.unresolved.flatMap(u=>u.sourceUnits);
  assert.equal(deferred.length,336);
  assert.equal(new Set(deferred).size,336);
  const added = maverick().map(f=>f.properties.unit);
  assert.ok(added.every(u=>!deferred.includes(u)));
  assert.equal(new Set([...added,...deferred]).size,344);
  assert.ok(dataset.coverageNotes.some(n=>n.includes('narrower physical delivery area')));
  for (const change of [
    f=>f.properties.verification='sourceMapped',
    f=>f.properties.kind='door',
    f=>f.properties.floor='1',
    f=>f.properties.notes='Approximate, not an entrance or exact door.'
  ]) {
    const altered = structuredClone(pack);
    change(altered.locations.features.find(f=>f.properties.communityID==='maverick'));
    assert.ok(validatePack(altered,evidence).length>0);
  }
});
