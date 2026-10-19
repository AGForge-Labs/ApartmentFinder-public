import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {loadEvidence} from './load-evidence.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';
const read=async path=>JSON.parse(await readFile(new URL('../../'+path,import.meta.url),'utf8'));
const pack={catalog:await read('data/catalog.json'),locations:await read('data/locations.geojson'),paths:await read('data/paths.geojson')};
const raw=await loadEvidence();
const units=id=>pack.locations.features.filter(f=>f.properties.communityID===id);

test('remaining delivery-area directories supply all explicitly counted candidates',()=>{
 for(const [id,count,estimated] of [['level25-durango',168,168],['level25-sunset',260,248],['solana-post',204,12],['evo',376,2],['sw',314,12],['spanish-wells',180,180]]) {
  assert.equal(units(id).length,count,id);
  assert.equal(units(id).filter(f=>f.properties.verification==='estimated').length,estimated,id);
 }
 assert.deepEqual(validatePack(pack,raw),[]);
});

test('catalog and coverage report distinguish estimated candidates from source-mapped positions',async()=>{
 const communities=new Map(pack.catalog.communities.map(c=>[c.id,c]));
 assert.equal(communities.get('level25-durango').researchStatus,'estimatedUnits');
 assert.equal(communities.get('spanish-wells').researchStatus,'estimatedUnits');
 for(const id of ['level25-sunset','solana-post','evo','sw']) {
  assert.equal(communities.get(id).researchStatus,'sourceMappedAndEstimatedUnits',id);
  assert.match(communities.get(id).gapNotes.join(' '),/candidate unit-position bounds, including estimates/);
 }
 const report=await readFile(new URL('../../research/COVERAGE.md',import.meta.url),'utf8');
 assert.match(report,/\| Community \| ZIP \| Candidate positions \| Directory status \|/);
 assert.match(report,/168 candidate unit positions\. Status: estimatedUnits\./);
 assert.match(report,/\| SW \| 89113 \| 314 \| Includes estimates; unit\/building identity ambiguous or hypothesized;/);
 assert.doesNotMatch(report,/published unit positions/);
});

test('Sunset keeps the original building-10 coordinates separate from its additional estimates',()=>{
 const pins=units('level25-sunset');
 assert.equal(pins.filter(f=>f.properties.building==='10').length,12);
 assert.ok(pins.filter(f=>f.properties.building==='10').every(f=>f.properties.verification==='sourceMapped'&&f.properties.positionDerivation.type==='registeredDiagram'));
 assert.equal(new Set(pins.map(f=>f.properties.unit)).size,260);
});

test('SW guesses retain both numbering evidence and explicit identity uncertainty',()=>{
 const pins=units('sw');
 for(const unit of ['1075','1076','1077','1078']) {
  const pin=pins.find(f=>f.properties.unit===unit);
  assert.equal(pin.properties.building,'7');assert.equal(pin.properties.verification,'estimated');
  assert.equal(pin.properties.identityUncertain,true);
  assert.equal(pin.properties.positionDerivation.identityHypothesis.basis,'directorySequence');
  assert.equal(pin.properties.positionDerivation.sourceUnit,'11'+unit.slice(2));
 }
 for(const unit of ['1175','1176','1177','1178']) assert.deepEqual(pins.filter(f=>f.properties.unit===unit).map(f=>f.properties.building).sort(),['15','7']);
});

test('estimates cannot lose warnings, change geometry, claim confirmed precision, or erase identity uncertainty',()=>{
 for(const change of [
  f=>f.properties.verification='sourceMapped',
  f=>f.properties.kind='door',
  f=>f.geometry.coordinates[0]+=0.001,
  f=>f.properties.notes='Approximate, not an entrance or exact door.',
  f=>f.properties.identityUncertain=false,
  f=>delete f.properties.positionDerivation.sourceUnit
 ]) {
  const altered=structuredClone(pack);
  const pin=altered.locations.features.find(f=>f.properties.communityID==='sw'&&f.properties.unit==='1075');
  assert.ok(pin);change(pin);assert.ok(validatePack(altered,raw).length>0);
 }
});
