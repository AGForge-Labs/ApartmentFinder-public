import {validateCountyReconciliation} from '../../scripts/data/identity-evidence.mjs';
import {loadEvidence} from './load-evidence.mjs';
import test from 'node:test';import assert from 'node:assert/strict';import {readFile} from 'node:fs/promises';import {validatePack} from '../../scripts/data/validate-pack.mjs';import {inGeometry,geometriesIntersect} from '../../scripts/data/geometry.mjs';
const read=async p=>JSON.parse(await readFile(new URL('../../'+p,import.meta.url)));
const pack={catalog:await read('data/catalog.json'),locations:await read('data/locations.geojson'),paths:await read('data/paths.geojson')};const raw=(await readFile(new URL('../../research/communities.tsv',import.meta.url),'utf8')).trimEnd().split(/\r?\n/),head=raw.shift().replace(/^\uFEFF/,'').split('\t');
const evidence=await loadEvidence();
test('Spanish Wells cannot be excluded when its saved parcel overlaps a requested ZIP',()=>{const row=evidence.reconciliation.records.find(r=>r.candidateAPN==='16327710000'),poly=evidence.countyPolygons.data.features.find(f=>f.properties.APN===row.candidateAPN);assert.ok(poly.geometry.coordinates.flat().some(p=>evidence.zips.data.features.some(z=>inGeometry(p,z.geometry))));assert.notEqual(row.category,'outOfScope');});
test('moving a community reference to a different in-scope community fails',()=>{const p=structuredClone(pack),c=p.catalog.communities.find(c=>c.id==='2one5'),other=p.catalog.communities.find(c=>c.id==='abode-red-rock');c.latitude=other.latitude;c.longitude=other.longitude;assert.ok(validatePack(p,evidence).some(e=>/community reference/.test(e)));});
test('an invented alias fails evidence validation',()=>{const p=structuredClone(pack);p.catalog.communities.find(c=>c.id==='2one5').aliases.push('invented-alias');assert.ok(validatePack(p,evidence).some(e=>/alias/.test(e)));});
test('a wrong existing target must fail county join validation',()=>{const mutated=structuredClone(evidence.reconciliation);mutated.records.find(r=>r.candidateAPN==='16329411000').communityID='2one5';assert.ok(validateCountyReconciliation(mutated,evidence).some(e=>e.includes('unsupported county join 16329411000')));});

test('intersection handles edge crossings, holes, multipolygons and boundary contact',()=>{
 const box=(x0,y0,x1,y1)=>({type:'Polygon',coordinates:[[[x0,y0],[x1,y0],[x1,y1],[x0,y1],[x0,y0]]]});
 assert.equal(geometriesIntersect(box(0,4,10,6),box(4,0,6,10)),true);
 const holed=box(0,0,10,10);holed.coordinates.push(box(2,2,8,8).coordinates[0]);assert.equal(geometriesIntersect(holed,box(3,3,7,7)),false);
 assert.equal(geometriesIntersect(box(0,0,1,1),box(1,0,2,1)),true);
 assert.equal(geometriesIntersect(box(0,0,1,1),box(2,2,3,3)),false);
 assert.equal(geometriesIntersect({type:'MultiPolygon',coordinates:[box(20,20,21,21).coordinates,box(0,0,1,1).coordinates]},box(0.5,0.5,2,2)),true);
});
test('every out-of-scope candidate is actually disjoint from both requested ZIPs',()=>{const rows=evidence.reconciliation.records.filter(r=>r.category==='outOfScope');assert.ok(rows.length);for(const r of rows){const polygon=evidence.countyPolygons.data.features.find(f=>f.properties.APN===r.candidateAPN).geometry;assert.equal(evidence.zips.data.features.some(z=>geometriesIntersect(polygon,z.geometry)),false);}});
test('an invented disjoint classification fails even if its claimed ZIP list is emptied',()=>{const ledger=structuredClone(evidence.reconciliation),r=ledger.records.find(r=>r.candidateAPN==='16327710000');r.category='outOfScope';r.scopeCountyZIPs=[];assert.ok(validateCountyReconciliation(ledger,evidence).some(e=>e.includes('out-of-scope polygon intersects')));});
test('website and county references are recomputed, not only ZIP checked',()=>{for(const type of ['websiteMetadata','countyParcelReference']){const p=structuredClone(pack),c=p.catalog.communities.find(c=>c.referenceDerivation?.type===type),other=p.catalog.communities.find(c=>c.id==='2one5');c.latitude=other.latitude;c.longitude=other.longitude;assert.ok(validatePack(p,evidence).some(e=>e==='community reference differs from raw source '+c.id));}});
test('reference source metadata cannot be omitted',()=>{const p=structuredClone(pack),c=p.catalog.communities.find(c=>c.id==='2one5');delete c.referenceDerivation;assert.ok(validatePack(p,evidence).some(e=>e.includes('community reference derivation missing')));});
test('a real alias with the wrong real source fails',()=>{const p=structuredClone(pack),c=p.catalog.communities.find(c=>c.id==='falls-rhodes-ranch');c.aliasDerivations[0].sourceIDs=['county-zip-boundaries'];c.sourceIDs.push('county-zip-boundaries');assert.ok(validatePack(p,evidence).some(e=>e.includes('alias source mismatch')));});
test('adding an alias to both TSV evidence and catalog is insufficient without a matching raw source label',()=>{const p=structuredClone(pack),raw=structuredClone(evidence),c=p.catalog.communities.find(c=>c.id==='2one5');raw.identities.find(c=>c.id==='2one5').aliases+='|invented-alias';c.aliases.push('invented-alias');assert.ok(validatePack(p,raw).some(e=>e.includes('unsupported alias')));});
test('Ely overlap-based join requires its actual geographic source citation',()=>{const ledger=structuredClone(evidence.reconciliation),r=ledger.records.find(r=>r.communityID==='ely-gramercy');assert.equal(r.joinBasis.type,'publishedMapOverlap');r.evidence=r.evidence.filter(e=>e.url!==r.joinBasis.mapURL);assert.ok(validateCountyReconciliation(ledger,evidence).some(e=>e.includes('county join source absent')));});

test('Spanish Trail additions retain county identity and ZIP evidence without invented geography',()=>{
 const additions=evidence.audits.filter(a=>a.pages.some(p=>p.observation?.landUse==='24.160 - SFR Unit/Row House. Townhouse')&&a.communityID.endsWith('spanish-trail'));
 assert.equal(additions.length,3);
 for(const a of additions){const c=pack.catalog.communities.find(c=>c.id===a.communityID);assert.ok(c);assert.equal(c.researchStatus,'inventoryOnly');assert.equal(c.latitude,undefined);assert.equal(c.longitude,undefined);assert.deepEqual(c.aliases,[]);assert.match(c.address,/area reference/);
 const county=a.pages.find(p=>p.observation?.description),zip=a.pages.find(p=>p.observation?.zip);assert.ok(county.observation.description.startsWith(c.name.toUpperCase()));assert.equal(zip.observation.zip,c.zip);
 for(const source of [county,zip])assert.ok(c.sourceIDs.some(id=>pack.catalog.sources.find(s=>s.id===id)?.url===source.url));
 assert.ok(!pack.locations.features.some(f=>f.properties.communityID===c.id));
 }
});

test('an area-reference street copied into inventory and broker notes still needs independent county support',()=>{
 const p=structuredClone(pack),r=structuredClone(evidence),id='springs-spanish-trail',address='Emerald Springs Ln / Invented Ct (area reference)';
 p.catalog.communities.find(c=>c.id===id).address=address;r.identities.find(c=>c.id===id).address=address;
 r.audits.find(a=>a.communityID===id).pages.find(p=>p.observation?.zip).observation.areaReference=address;
 assert.ok(validatePack(p,r).some(e=>e.includes('unsupported area-reference street')));
});
