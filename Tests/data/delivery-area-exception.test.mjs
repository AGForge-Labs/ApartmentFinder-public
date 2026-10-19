import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {loadEvidence} from './load-evidence.mjs';
import {inDeliveryArea,validateDeliveryAreaException} from '../../scripts/data/delivery-area-exceptions.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';

const read=async path=>JSON.parse(await readFile(new URL('../../'+path,import.meta.url),'utf8'));
const raw=await loadEvidence();
const pack={catalog:await read('data/catalog.json'),locations:await read('data/locations.geojson'),paths:await read('data/paths.geojson')};

test('Spanish Wells is one source-backed, parcel-bounded exception',()=>{
 assert.deepEqual(validateDeliveryAreaException(raw.areaException,raw),[]);
 assert.equal(pack.catalog.scopeZIPs.join(','),'89113,89148');
 assert.deepEqual(pack.catalog.deliveryAreaExceptions.map(e=>e.communityID),['spanish-wells']);
 const inside=raw.areaException.communityReference.coordinates,outside=[-115.246,36.0917];
 assert.equal(inDeliveryArea(inside,'spanish-wells',raw.zips,raw.areaException),true);
 assert.equal(inDeliveryArea(outside,'spanish-wells',raw.zips,raw.areaException),false);
 assert.equal(pack.locations.features.filter(f=>f.properties.communityID==='spanish-wells').length,180);
 assert.deepEqual(validatePack(pack,raw),[]);
});

test('unrelated postal 89118 and a Spanish Wells point moved off its parcel fail closed',()=>{
 const unrelated=structuredClone(pack);
 unrelated.catalog.communities.find(c=>c.id==='2one5').zip='89118';
 assert.ok(validatePack(unrelated,raw).some(e=>e.includes('ZIP contamination 2one5')));
 const moved=structuredClone(pack);
 moved.locations.features.find(f=>f.properties.communityID==='spanish-wells').geometry.coordinates=[-115.246,36.0917];
 assert.ok(validatePack(moved,raw).some(e=>e.includes('point outside scope spanish-wells-unit-')));
 const changedBoundary=structuredClone(raw);
 changedBoundary.areaException.physicalBoundary.geometry.coordinates[0][0][0]+=0.001;
 assert.ok(validateDeliveryAreaException(changedBoundary.areaException,changedBoundary).some(e=>e.includes('property polygon mismatch')));
});
