import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {classifyRileyPosition,validateRileyEvidence} from '../../scripts/data/riley-property-evidence.mjs';
import {inGeometry} from '../../scripts/data/geometry.mjs';
const read=async p=>JSON.parse(await readFile(new URL('../../'+p,import.meta.url)));
const record=await read('research/geography/riley-property-separation.json');
const maps=await read('research/maps/public-map-facts.json');

test('every Riley source position is contained by only one address-specific county parcel',()=>{
  assert.deepEqual(validateRileyEvidence(record,maps),{'6350':154,'6355':302,uncertain:2});
  assert.equal(classifyRileyPosition([-115.2834065,36.0728175],record.streetParcels),'6350');
  assert.equal(classifyRileyPosition([-115.28419099999999,36.073499999999996],record.streetParcels),'6355');
});
test('overlapping unit105 is distinguished by parcel geometry rather than the label',()=>{
  const matches=record.positions.filter(p=>p.unit==='105');
  assert.equal(matches.length,2);
  assert.deepEqual(new Set(matches.map(p=>classifyRileyPosition(p.coordinates,record.streetParcels))),new Set(['6350','6355']));
});
test('county ZIP polygons describe each Riley street separately and do not establish postal ZIPs',async()=>{
  const zips=await read('research/geography/county-zips.json');
  const count={'6350 S Riley St':{},'6355 S Riley St':{}};
  for(const p of record.positions){
    const matches=zips.data.features.filter(z=>inGeometry(p.coordinates,z.geometry));
    assert.equal(matches.length,1);
    const zip=String(matches[0].properties.ZIP);
    count[p.address][zip]=(count[p.address][zip]??0)+1;
  }
  assert.deepEqual(count,{'6350 S Riley St':{'89113':154},'6355 S Riley St':{'89148':302}});
});
test('outside, invalid and overlapping street parcels cannot assign a position',()=>{
  assert.throws(()=>classifyRileyPosition([-110,40],record.streetParcels));
  assert.throws(()=>classifyRileyPosition([NaN,36],record.streetParcels));
  const overlap=structuredClone(record.streetParcels);overlap['6355']=structuredClone(overlap['6350']);
  assert.throws(()=>classifyRileyPosition([-115.2834065,36.0728175],overlap));
});
test('malformed, unclosed and nonfinite parcel rings are rejected',()=>{
  for(const rings of [[],[[[0,0],[1,1]]],[[[0,0],[1,0],[1,1],[NaN,0]]],[[[0,0],[1,0],[1,1],[0,1]]]]){
    const changed=structuredClone(record.streetParcels);changed['6350'][0].geometry.rings=rings;
    assert.throws(()=>classifyRileyPosition([-115.2834065,36.0728175],changed));
  }
});
test('dropped, duplicated or relabeled source records cannot weaken the retained split',()=>{
  for(const mutate of [r=>r.positions.pop(),r=>r.positions.push(r.positions[0]),r=>r.positions[0].address='6350 S Riley St',
    r=>r.positions[0].coordinates[0]+=.01,r=>r.positions[0].unit='99999',r=>r.rawSHA256['6350']='0'.repeat(64)]){
    const changed=structuredClone(record);mutate(changed);assert.throws(()=>validateRileyEvidence(changed,maps));
  }
});
test('two unmatched county labels stay uncertain despite property containment',()=>{
  assert.deepEqual(record.positions.filter(p=>!p.countyUnitLabelMatches).map(p=>[p.unit,p.building]),[['327','6'],['303','7']]);
  const changed=structuredClone(record);changed.positions.find(p=>p.unit==='327'&&p.building==='6').countyUnitLabelMatches=true;
  assert.throws(()=>validateRileyEvidence(changed,maps));
});
