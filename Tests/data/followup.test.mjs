import test from 'node:test';import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';import {inGeometry} from '../../scripts/data/geometry.mjs';
import {loadCountyUnitCoverage,deriveCountyUnitPositions} from '../../scripts/data/county-unit-labels.mjs';
import {loadRegisteredUnitMaps,deriveRegisteredUnitPositions} from '../../scripts/data/registered-unit-maps.mjs';
import {loadEstimatedUnitMaps,deriveEstimatedUnitPositions} from '../../scripts/data/estimated-unit-maps.mjs';
import {reprojectedCoordinatesMatch} from '../../scripts/data/projected-coordinate-check.mjs';
const read=async p=>JSON.parse(await readFile(new URL('../../'+p,import.meta.url)));
const reconciliation=await read('research/geography/county-reconciliation.json'),saved=await read('research/geography/county-gilis20.json'),polygons=await read('research/geography/county-gilis20-polygons.json'),zips=await read('research/geography/county-zips.json'),catalog=await read('data/catalog.json'),locations=await read('data/locations.geojson'),pixel=await read('research/audits/pixel-map-audit.json');
const countyCoverage = await loadCountyUnitCoverage();
const registeredMaps = await loadRegisteredUnitMaps();
const estimatedMaps = await loadEstimatedUnitMaps();
function requireIndependentUnitEvidence(communityID) {
  const imported = locations.features.filter(f => f.properties.communityID === communityID);
  if (!imported.length) return;
  const county = countyCoverage.find(c => c.communityID === communityID);
  const registered = registeredMaps.find(c => c.communityID === communityID);
  const estimated = estimatedMaps.find(c => c.communityID === communityID);
  assert.ok(county || registered || estimated, communityID + ' cannot use a parcel center or unexplained pixel coordinate as a unit pin');
  const points = [...(county ? deriveCountyUnitPositions(county).map(p => ({...p, derivation: 'countyLabelCenter'})) : []),
                  ...(registered ? deriveRegisteredUnitPositions(registered).map(p => ({...p, derivation: 'registeredDiagram'})) : []),
                  ...(estimated ? deriveEstimatedUnitPositions(estimated).map(p => ({...p, derivation: 'estimatedDiagram'})) : [])];
  assert.equal(imported.length, points.length);
  for (const pin of imported) {
    const point = points.find(p => pin.id === communityID + '-unit-' + p.sourceUnitID);
    assert.ok(point);
    if (['registeredDiagram','estimatedDiagram'].includes(point.derivation)) {
      assert.ok(reprojectedCoordinatesMatch(pin.geometry.coordinates, point.coordinates), pin.id + ' differs from its source projection');
    } else {
      assert.deepEqual(pin.geometry.coordinates, point.coordinates);
    }
    assert.equal(pin.properties.unit, point.unit);
    assert.equal(pin.properties.building, point.building);
    assert.equal(pin.properties.positionDerivation.type, point.derivation);
    if (point.derivation === 'registeredDiagram') assert.deepEqual(pin.properties.positionDerivation.calibration, point.calibration);
    assert.equal(pin.properties.verification, point.verification ?? 'sourceMapped');
  }
}
test('every saved county candidate has exactly one evidence-backed adjudication',()=>{const ids=reconciliation.records.map(r=>r.candidateAPN);assert.equal(new Set(ids).size,ids.length);assert.deepEqual(new Set(ids),new Set(saved.data.features.map(f=>f.attributes.APN)));for(const r of reconciliation.records){assert.ok(['matchedExisting','matchedLegalAlias','addedCommunity','addedDeliveryAreaException','excludedNonResidential','outOfScope','unknownZIPConflict','unknownBoundaryConflict'].includes(r.category));assert.ok(r.evidence.length>=3);for(const e of r.evidence){assert.equal(new URL(e.url).protocol,'https:');assert.ok(e.finding.length>0&&Number.isFinite(Date.parse(e.retrievedAt)));}if(r.communityID)assert.ok(catalog.communities.some(c=>c.id===r.communityID));}});
test('non-residential county counts cannot silently become apartment communities',()=>{for(const r of reconciliation.records.filter(r=>r.category==='excludedNonResidential')){assert.equal(r.communityID,null);assert.match(r.current.landUse,/^(40|41|51|92)\./);assert.ok(r.notes.some(n=>n.includes('not a residential-only')));}});
test('new county residential groups have independently in-scope ZIP geometry and no inferred unit pins',()=>{for(const r of reconciliation.records.filter(r=>r.category==='addedCommunity')){const c=catalog.communities.find(c=>c.id===r.communityID);assert.match(r.current.landUse,/^(21|24)\./);const f=polygons.data.features.find(f=>f.properties.APN===r.candidateAPN);const p=f.geometry.type==='Polygon'?f.geometry.coordinates.flat():f.geometry.coordinates.flat(2);const center=[(Math.min(...p.map(v=>v[0]))+Math.max(...p.map(v=>v[0])))/2,(Math.min(...p.map(v=>v[1]))+Math.max(...p.map(v=>v[1])))/2];assert.ok(zips.data.features.some(z=>String(z.properties.ZIP)===c.zip&&inGeometry(center,z.geometry)));requireIndependentUnitEvidence(c.id);assert.ok(c.gapNotes.some(n=>n.includes('reference')));}});
test('conflicting ZIP candidate stays out of verified inventory',()=>{const unresolved=reconciliation.records.filter(r=>r.category==='unknownZIPConflict');assert.ok(unresolved.length>0);for(const r of unresolved){assert.equal(r.communityID,null);assert.equal(catalog.communities.some(c=>c.name===r.candidateName),false);assert.ok(r.evidence.some(e=>e.title.includes('official contact')));}});
test('all discovered pixel regions were attempted without geographic promotion',()=>{for(const c of pixel){const visited=new Set(c.pages.map(p=>new URL(p.url).searchParams.get('areaId')));for(const p of c.pages)for(const target of p.regionTargets??[])if(target!=='Region_0')assert.ok(visited.has(target),c.communityID+' unfinished '+target);assert.equal(c.pixelUnitCount,new Set(c.pages.flatMap(p=>p.pixelUnitIDs??[])).size);requireIndependentUnitEvidence(c.communityID);assert.match(c.conclusion,/No geographic positions imported/);}});
