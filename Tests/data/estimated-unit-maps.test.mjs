import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';

const module = await import('../../scripts/data/estimated-unit-maps.mjs').catch(() => ({}));
test('retained estimated snapshots keep their checksums after a Git checkout',async()=>{
 const directory=new URL('../../research/geography/estimated-unit-maps/',import.meta.url);
 const manifest=JSON.parse(await readFile(new URL('manifest.json',directory),'utf8'));
 for(const entry of manifest.datasets){
  const bytes=await readFile(new URL(entry.file,directory));
  assert.equal(bytes.includes(13),false,entry.file+' must use LF as required by .gitattributes');
  assert.equal(createHash('sha256').update(bytes).digest('hex'),entry.sha256,entry.file);
 }
});
const source = {id:'plan',title:'Synthetic directory',kind:'directory',url:'https://example.org/directory',sha256:'a'.repeat(64),retrievedAt:'2026-09-27T00:00:00Z'};
const fixture = () => ({
 schemaVersion:1,communityID:'synthetic',address:'5453 S Durango Dr',retrievedAt:source.retrievedAt,expectedPositions:2,
 sources:[{...source},{...source,id:'aerial',kind:'aerial',url:'https://example.org/aerial'}],
 method:{type:'buildingRelativeDiagramBays',notes:'Observed building corners and printed bay order.',strictRegistrationAccepted:false},
 reference:{sourceID:'aerial',width:1000,height:1000,extent:[-115.282,36.088,-115.280,36.090],spatialReference:'EPSG:4326',projection:'webMercator'},
 buildings:[{building:'1',sourceBuildingToken:'1',referencePixelOutline:[[100,100],[900,100],[900,900],[100,900],[100,100]],correspondenceNotes:'Same physical building supported by orientation and visible roof.'}],
 stacks:[{id:'b1-west',building:'1',sourceUnits:['1002','2002'],sourcePixel:[200,250],referencePixel:[250,250],uncertaintyMeters:15,notes:'Printed western bay; actual entrance unknown.'}],
 unresolved:[],coverageNotes:['Estimates require an on-site check.']
});
function derive(value) { assert.equal(typeof module.deriveEstimatedUnitPositions,'function','estimated directory loader must exist'); return module.deriveEstimatedUnitPositions(value); }

test('derives literal stacked units at a reproducible estimated bay, never inferred floors',()=>{
 const points=derive(fixture());
 assert.equal(points.length,2);assert.deepEqual(points.map(p=>p.unit),['1002','2002']);
 assert.equal(points[0].verification,'estimated');assert.equal(points[0].floor,'');
 assert.deepEqual(points[0].coordinates,points[1].coordinates);
 assert.ok(Math.abs(points[0].coordinates[0]-(-115.2815))<1e-10);
 assert.ok(points[0].coordinates[1]>36.0894 && points[0].coordinates[1]<36.0896);
});
for(const [name,mutate,pattern] of [
 ['untraceable imagery',d=>d.reference.sourceID='absent',/reference source/],
 ['outside-building estimate',d=>d.stacks[0].referencePixel=[950,950],/outside.*building/],
 ['invented building',d=>d.stacks[0].building='9',/building/],
 ['missing uncertainty',d=>delete d.stacks[0].uncertaintyMeters,/uncertainty/],
 ['duplicate unit within a building',d=>{d.stacks[0].sourceUnits.push('1002');d.expectedPositions++;},/duplicate/],
 ['field-verification claim',d=>d.method.strictRegistrationAccepted=true,/strict/],
 ['lost printed label',d=>d.expectedPositions=3,/count/],
 ['missing source hash',d=>d.sources[0].sha256='',/hash/],
 ['nonfinite pixel',d=>d.stacks[0].referencePixel=[NaN,200],/pixel/]
]) test('rejects '+name,()=>{const d=fixture();mutate(d);assert.throws(()=>derive(d),pattern);});

test('retains ambiguous labels in different buildings only with explicit ambiguity metadata',()=>{
 const d=fixture();d.expectedPositions=4;
 d.buildings.push({...d.buildings[0],building:'2',sourceBuildingToken:'2'});
 d.stacks.push({...d.stacks[0],id:'b2-west',building:'2'});
 assert.throws(()=>derive(d),/ambigu/);
 for(const s of d.stacks){s.identityAmbiguous=true;s.ambiguityGroup='repeated-labels';}
 assert.equal(derive(d).length,4);
});

test('explicit numbering hypothesis retains original printed tokens and uncertainty',()=>{
 const d=fixture();
 d.stacks[0].units=['1075','1076'];d.stacks[0].sourceUnits=['1175','1176'];
 d.stacks[0].identityHypothesis={basis:'directorySequence',notes:'A repeated block conflicts with the surrounding 107x sequence; inferred, not corroborated.'};
 const points=derive(d);
 assert.deepEqual(points.map(p=>p.unit),['1075','1076']);
 assert.deepEqual(points.map(p=>p.sourceUnit),['1175','1176']);
 assert.ok(points.every(p=>p.identityUncertain && p.identityHypothesis.basis==='directorySequence'));
 delete d.stacks[0].identityHypothesis;
 assert.throws(()=>derive(d),/hypothesis/);
});
