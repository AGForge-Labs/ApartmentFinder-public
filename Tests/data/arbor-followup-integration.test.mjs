import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {loadEvidence} from './load-evidence.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';

const read = async path => JSON.parse(await readFile(new URL('../../' + path, import.meta.url), 'utf8'));
const pack = {catalog:await read('data/catalog.json'), locations:await read('data/locations.geojson'), paths:await read('data/paths.geojson')};
const evidence = await loadEvidence();
const added = feature => feature.id.startsWith('arbor-pointe-unit-estimate-b6-bay-');
const addedMartin = feature => feature.id.startsWith('martin-fort-apache-unit-estimate-martin-');
const addedMaverick = feature => /^maverick-unit-estimate-b(13|15|6|9)-carriage-/.test(feature.id);
const addedClubs = feature => /^clubs-rhodes-ranch-unit-estimate-b14-(1094|2095)-\1$/.test(feature.id);
const literalUnits = ['1045','2045','1046','2046','3046','1047','2047','3047','1048','2048',
  '1044','2044','1043','2043','3043','1042','2042','3042','1041','2041'];

test('Arbor Pointe adds only the twenty literal building-6 labels as qualified estimates', () => {
  const pins = pack.locations.features.filter(added);
  assert.equal(pins.length,20);
  assert.deepEqual(pins.map(f=>f.properties.unit).sort(),literalUnits.toSorted());
  assert.equal(new Set(pins.map(f=>JSON.stringify(f.geometry.coordinates))).size,8);
  for (const pin of pins) {
    assert.equal(pin.properties.building,'6');
    assert.equal(pin.properties.verification,'estimated');
    assert.equal(pin.properties.kind,'unitPosition');
    assert.equal(pin.properties.floor,'');
    assert.equal(pin.properties.positionDerivation.type,'estimatedDiagram');
    assert.equal(pin.properties.positionDerivation.sourceUnit,pin.properties.unit);
    assert.equal(pin.properties.identityUncertain,false);
    assert.match(pin.properties.notes,/May be inaccurate/);
    assert.match(pin.properties.notes,/advisory, not measured absolute accuracy/);
    assert.match(pin.properties.notes,/not an entrance or exact door/);
  }
  const arbor = pack.locations.features.filter(f=>f.properties.communityID==='arbor-pointe');
  assert.equal(arbor.length,180);
  assert.equal(arbor.filter(f=>f.properties.verification==='sourceMapped').length,160);
  const community = pack.catalog.communities.find(c=>c.id==='arbor-pointe');
  assert.equal(community.researchStatus,'sourceMappedAndEstimatedUnits');
  assert.ok(community.gapNotes.some(n=>n.startsWith('Strict-registration tier:')&&n.includes('Building 6')));
  assert.deepEqual(validatePack(pack,evidence),[]);
});

test('the follow-up preserves all 14329 released position features exactly', () => {
  assert.equal(pack.locations.features.filter(added).length,20);
  assert.equal(pack.locations.features.filter(addedMartin).length,90);
  assert.equal(pack.locations.features.filter(addedMaverick).length,8);
  assert.equal(pack.locations.features.filter(addedClubs).length,2);
  const original = pack.locations.features.filter(f=>!added(f)&&!addedMartin(f)&&!addedMaverick(f)&&!addedClubs(f)&&f.properties.communityID!=='spanish-ridge-7380').sort((a,b)=>a.id.localeCompare(b.id,'en'));
  assert.equal(original.length,14329);
  // SHA of full parsed features at reviewed HEAD 41846f8, sorted by stable ID.
  const sha = createHash('sha256').update(JSON.stringify(original)).digest('hex');
  assert.equal(sha,'3d669fc960031cd6fc601b20d76bf7b8cf882b502e611ab2cc2a5dca8ab20675');
});

test('new pin research does not redate nine unchanged legacy discovery sources', () => {
  for (const id of ['directory-apartments-89113','directory-apartments-89113-page2','directory-rentcafe-89113',
    'directory-apartments-89148','directory-apartments-89148-page2','directory-rentcafe-89148',
    'pace-pdf-2021','ashton-place-name','la-paloma-name']) {
    const source = pack.catalog.sources.find(s=>s.id===id);
    assert.equal(source?.retrievedAt,'2026-09-27T09:14:21.084856+00:00');
  }
});

test('Arbor estimates cannot be promoted, acquire guessed floors or lose their warning', () => {
  assert.equal(pack.locations.features.filter(added).length,20);
  for (const change of [
    f=>f.properties.verification='sourceMapped',
    f=>f.properties.kind='door',
    f=>f.properties.floor='1',
    f=>f.properties.notes='Approximate, not an entrance or exact door.'
  ]) {
    const altered = structuredClone(pack);
    change(altered.locations.features.find(added));
    assert.ok(validatePack(altered,evidence).length>0);
  }
});
