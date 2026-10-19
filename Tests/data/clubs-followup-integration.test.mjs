import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {loadEvidence} from './load-evidence.mjs';
import {validatePack} from '../../scripts/data/validate-pack.mjs';
import {estimatedPixelCoordinate} from '../../scripts/data/estimated-unit-maps.mjs';
import {inRing} from '../../scripts/data/geometry.mjs';

const read = async path => JSON.parse(await readFile(new URL('../../' + path, import.meta.url), 'utf8'));
const pack = {catalog:await read('data/catalog.json'), locations:await read('data/locations.geojson'), paths:await read('data/paths.geojson')};
const evidence = await loadEvidence();
const clubs = feature => feature.properties.communityID === 'clubs-rhodes-ranch';
const expected = [
  {unit:'1094',code:'141094',opaqueID:'5200829',roof:'789240097',pixel:[1537,471],sourcePixel:[304.75,634.96484375]},
  {unit:'2095',code:'142095',opaqueID:'5200838',roof:'789240096',pixel:[1537,532],sourcePixel:[413.75,635.96484375]}
];

test('Clubs adds exactly two qualified estimates and preserves every previously prepared feature', () => {
  const pins = pack.locations.features.filter(clubs);
  assert.equal(pins.length,2);
  assert.deepEqual(pins.map(f=>f.properties.unit).sort(),['1094','2095']);
  assert.equal(pack.catalog.coverage.inventoryComplete,false);
  assert.deepEqual(pack.catalog.sources.find(s=>s.id==='clubs-rhodes-ranch-pixel-1'),{
    id:'clubs-rhodes-ranch-pixel-1',
    title:'The Clubs at Rhodes Ranch — inspected local-coordinate map region',
    url:'https://www.theclubsapt.com/interactivepropertymap?handler=IPMArea&areaId=Region_1139361',
    retrievedAt:'2026-09-18T05:56:26.175Z'
  });
  for (const pin of pins) {
    assert.ok(pin.properties.sourceIDs.includes('clubs-rhodes-ranch-pixel-1'));
    assert.equal(pin.id,`clubs-rhodes-ranch-unit-estimate-b14-${pin.properties.unit}-${pin.properties.unit}`);
    assert.equal(pin.properties.building,'14');
    assert.equal(pin.properties.floor,'');
    assert.equal(pin.properties.verification,'estimated');
    assert.equal(pin.properties.kind,'unitPosition');
    assert.equal(pin.properties.identityUncertain,false);
    assert.equal(pin.properties.positionDerivation.uncertaintyMeters,25);
    assert.equal(pin.properties.positionDerivation.sourceUnit,pin.properties.unit);
    assert.match(pin.properties.notes,/May be inaccurate/);
    assert.match(pin.properties.notes,/advisory and not measured image accuracy/);
    assert.match(pin.properties.notes,/not an entrance or exact door/);
  }
  const prepared = pack.locations.features.filter(f=>!clubs(f)&&f.properties.communityID!=='spanish-ridge-7380').sort((a,b)=>a.id.localeCompare(b.id,'en'));
  assert.equal(prepared.length,14447);
  assert.equal(createHash('sha256').update(JSON.stringify(prepared)).digest('hex'),
    '5a2c49444c71e397910c2fa7712fa62601cf5d06ddae9c7f31c7808555a2df46');
  assert.deepEqual(validatePack(pack,evidence),[]);
  for (const change of [
    f=>f.properties.verification='sourceMapped',
    f=>f.properties.kind='door',
    f=>f.properties.floor='1',
    f=>f.properties.notes='Approximate, not an entrance or exact door.'
  ]) {
    const altered=structuredClone(pack);
    change(altered.locations.features.find(clubs));
    assert.ok(validatePack(altered,evidence).length>0);
  }
});

test('Clubs literal witnesses retain their own roof wing and unresolved inventory limits', async () => {
  const bytes=await readFile(new URL('../../research/geography/estimated-unit-maps/clubs-rhodes-ranch.json',import.meta.url));
  assert.equal(createHash('sha256').update(bytes).digest('hex'),
    '6fb0cfab04a23b6de9e8c404cdb2a9fdccb417eb03f2b42e85e17fc060929f41');
  const dataset=JSON.parse(bytes);
  assert.equal(dataset.method.strictRegistrationAccepted,false);
  assert.equal(dataset.inventoryComplete,false);
  assert.equal(dataset.currentUnitCountVerified,false);
  assert.equal(dataset.sourceArtworkPrintedDate,'05.13.14');
  assert.equal(dataset.unresolved[0].historicalPrintedLabels,272);
  assert.equal(dataset.unresolved[0].currentUnitLinks,270);
  assert.equal(dataset.expectedPositions,2);
  assert.equal(dataset.stacks.length,2);
  assert.equal(dataset.buildings.length,1);
  const building=dataset.buildings[0];
  assert.equal(building.building,'14');
  assert.equal(building.referenceRoofParts.length,2);
  for (const witness of expected) {
    const stack=dataset.stacks.find(s=>s.sourceUnits[0]===witness.unit);
    assert.deepEqual(stack.sourceUnits,[witness.unit]);
    assert.equal(stack.units,undefined);
    assert.equal(stack.identityHypothesis,undefined);
    assert.equal(stack.literalLiveWitness.opaqueUnitID,witness.opaqueID);
    assert.equal(stack.literalLiveWitness.publishedUnitCode,witness.code);
    assert.deepEqual(stack.sourcePixel,witness.sourcePixel);
    assert.deepEqual(stack.referencePixel,witness.pixel);
    assert.equal(stack.referenceRoofPartOSMWayID,witness.roof);
    const ownRoof=building.referenceRoofParts.find(p=>p.osmWayID===witness.roof);
    const oppositeRoof=building.referenceRoofParts.find(p=>p.osmWayID!==witness.roof);
    assert.ok(inRing(stack.referencePixel,ownRoof.referencePixelOutline));
    assert.equal(inRing(stack.referencePixel,oppositeRoof.referencePixelOutline),false);
    const pin=pack.locations.features.find(f=>clubs(f)&&f.properties.unit===witness.unit);
    assert.deepEqual(pin.geometry.coordinates,estimatedPixelCoordinate(stack.referencePixel,dataset.reference));
  }
  // A group envelope includes the central gap: individual wing containment is essential.
  const gap=[1537,501];
  assert.ok(inRing(gap,building.referencePixelOutline));
  assert.equal(building.referenceRoofParts.some(p=>inRing(gap,p.referencePixelOutline)),false);
  const north=pack.locations.features.find(f=>clubs(f)&&f.properties.unit==='1094');
  const south=pack.locations.features.find(f=>clubs(f)&&f.properties.unit==='2095');
  assert.ok(north.geometry.coordinates[1]>south.geometry.coordinates[1]);
});
