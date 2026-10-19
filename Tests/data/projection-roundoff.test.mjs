import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {loadEvidence} from './load-evidence.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';
import {deriveEstimatedUnitPositions} from '../../scripts/data/estimated-unit-maps.mjs';
import {deriveRegisteredUnitPositions} from '../../scripts/data/registered-unit-maps.mjs';

const root=new URL('../../',import.meta.url);
const read=async path=>JSON.parse(await readFile(new URL(path,root)));
const pack={catalog:await read('data/catalog.json'),locations:await read('data/locations.geojson'),paths:await read('data/paths.geojson')};
const evidence=await loadEvidence();
const martinID='martin-fort-apache-unit-estimate-martin-1-02-102';
const martinPoint=deriveEstimatedUnitPositions(evidence.estimatedMaps.find(m=>m.communityID==='martin-fort-apache')).find(p=>'martin-fort-apache-unit-'+p.sourceUnitID===martinID);
assert.ok(martinPoint);

function step(value,count){
 const view=new DataView(new ArrayBuffer(8));view.setFloat64(0,value);
 view.setBigUint64(0,view.getBigUint64(0)+(value>=0?BigInt(count):-BigInt(count)));
 return view.getFloat64(0);
}
function withCoordinates(id,coordinates){
 const copy=structuredClone(pack);const feature=copy.locations.features.find(f=>f.id===id);assert.ok(feature);
 feature.geometry.coordinates=coordinates;return copy;
}
const coordinateError=errors=>errors.some(e=>e.includes('coordinate changed from source'));

test('captured four-step Martin reprojection roundoff keeps the same source position',()=>{
 const captured=[-115.298067718134,36.06798327645988];
 assert.deepEqual(validatePack(withCoordinates(martinID,captured),evidence),[]);
});

test('estimated reprojection permits at most eight Float64 steps and rejects real displacement',()=>{
 for(const axis of [0,1])for(const direction of [-1,1]){
  const within=[...martinPoint.coordinates];within[axis]=step(within[axis],direction*8);
  assert.deepEqual(validatePack(withCoordinates(martinID,within),evidence),[]);
  const beyond=[...martinPoint.coordinates];beyond[axis]=step(beyond[axis],direction*9);
  assert.ok(coordinateError(validatePack(withCoordinates(martinID,beyond),evidence)));
 }
 const displaced=[...martinPoint.coordinates];displaced[1]+=1e-8;
 assert.ok(coordinateError(validatePack(withCoordinates(martinID,displaced),evidence)));
});

test('registered diagram reprojection uses the same tight limit',()=>{
 const feature=pack.locations.features.find(f=>f.properties.positionDerivation?.type==='registeredDiagram');assert.ok(feature);
 const map=evidence.registeredMaps.find(m=>m.communityID===feature.properties.communityID);
 const point=deriveRegisteredUnitPositions(map).find(p=>map.communityID+'-unit-'+p.sourceUnitID===feature.id);assert.ok(point);
 const within=[...point.coordinates];within[1]=step(within[1],8);
 assert.deepEqual(validatePack(withCoordinates(feature.id,within),evidence),[]);
 const beyond=[...point.coordinates];beyond[1]=step(beyond[1],9);
 assert.ok(coordinateError(validatePack(withCoordinates(feature.id,beyond),evidence)));
});

test('literal source coordinates retain exact equality even for one Float64 step',()=>{
 const feature=pack.locations.features.find(f=>!['registeredDiagram','estimatedDiagram'].includes(f.properties.positionDerivation?.type));assert.ok(feature);
 const changed=[...feature.geometry.coordinates];changed[1]=step(changed[1],1);
 assert.ok(coordinateError(validatePack(withCoordinates(feature.id,changed),evidence)));
});

test('projection roundoff never admits malformed or out-of-scope positions',()=>{
 for(const coordinates of [[NaN,36],[Infinity,36],['-115.298067718134',36],[-115.298,Infinity],[-115.298],[-115.298,36,0],[36,-115.298],[-111.9,40.77]]){
  const errors=validatePack(withCoordinates(martinID,coordinates),evidence);
  assert.ok(coordinateError(errors));assert.ok(errors.some(e=>e.includes('point outside scope')));
 }
});

test('the approved 14517-position pack and four new evidence datasets remain byte-exact',async()=>{
 // Version-specific preservation receipt: numerical comparison must not rewrite
 // stored pins. Update these hashes only with an explicitly reviewed data pack.
 const hashes={
  'data/catalog.json':'c042837c23c51ec69782eb35d891054ef4985039c2755eb52ab465fb5c1e54b4',
  'data/locations.geojson':'ae7a1463cec93f14384cc49f28bd2c465d53ce3eee3361e4dfd81bcddd31dbf3',
  'data/paths.geojson':'a0d8fbc6e4e3ca2b0690bcc3d79e2764a326226faa0d429a82e950cca54a7bc2',
  'research/geography/estimated-unit-maps/arbor-pointe.json':'89116b3b16920a0d01b5576840c9f26afc5efb2a98b6319a3f31b983e40575eb',
  'research/geography/estimated-unit-maps/martin-fort-apache.json':'7b51cce8de97e11dcd4864e921c2c58168a9fc50edf44ac97fc2b7ba58016cfc',
  'research/geography/estimated-unit-maps/maverick.json':'8f9cb6d0b8d966dcfd7cfbd1b69bfcf0e346f6905f2b5b420cddf46ab084f564',
  'research/geography/estimated-unit-maps/clubs-rhodes-ranch.json':'6fb0cfab04a23b6de9e8c404cdb2a9fdccb417eb03f2b42e85e17fc060929f41'
 };
 for(const [path,expected] of Object.entries(hashes))assert.equal(createHash('sha256').update(await readFile(new URL(path,root))).digest('hex'),expected,path);
 assert.equal(pack.locations.features.length,14517);
});
