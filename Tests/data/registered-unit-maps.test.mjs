import test from 'node:test';
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';

const api = await import('../../scripts/data/registered-unit-maps.mjs').catch(error => {
  if (error.code === 'ERR_MODULE_NOT_FOUND') return null;
  throw error;
});
async function cabrillo() {
  assert.ok(api, 'registered unit-map loader is implemented');
  return (await api.loadRegisteredUnitMaps()).find(raw => raw.communityID === 'cabrillo');
}

test('Cabrillo reconstructs 242 county-matched unit identities from 84 printed stacks', async () => {
  const raw = await cabrillo();
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 242);
  assert.equal(new Set(units.map(unit => unit.unit)).size, 242);
  assert.equal(new Set(units.map(unit => JSON.stringify(unit.coordinates))).size, 84);
  assert.ok(units.every(unit => unit.floor === '' && unit.address === '7955 W BADURA AVE'));
  assert.ok(units.every(unit => unit.calibration.heldoutMaximumResidualMeters < 2));
  const first = units.find(unit => unit.unit === '101');
  assert.equal(first.building, '1');
  assert.match(first.sourceUnitID, /^registered-cabrillo-/);
  assert.ok(Math.abs(first.coordinates[0] - (-115.26499662306391)) < 1e-10);
  assert.ok(Math.abs(first.coordinates[1] - 36.060783831280595) < 1e-10);
  assert.deepEqual(first.coordinates, units.find(unit => unit.unit === '201').coordinates);
});

test('a moved fit control fails independent held-out validation', async () => {
  const raw = structuredClone(await cabrillo());
  raw.controls.find(point => point.role === 'fit').referencePixel[0] += 250;
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /calibration|residual/i);
});

test('a mislabeled county legal unit or building is rejected', async () => {
  const raw = structuredClone(await cabrillo());
  raw.membership.records[0].legalDescription = 'UNIT 999 BLDG 1';
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /membership|legal|identity/i);
});

test('a printed stack moved outside its independently supported building is rejected', async () => {
  const raw = structuredClone(await cabrillo());
  raw.stacks[0].planPixel = [800, 800];
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /outside.*building/i);
});

test('missing printed units cannot silently reduce the directory', async () => {
  const raw = structuredClone(await cabrillo());
  raw.stacks[0].units.pop();
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /count|membership|missing/i);
});

test('duplicate or collinear controls cannot pass as independent calibration evidence', async () => {
  const raw = structuredClone(await cabrillo());
  for (const point of raw.controls.filter(point => point.role === 'fit')) point.planPixel = [100, 100];
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /control|degenerate|calibration/i);
});

async function sw() {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'sw');
  assert.ok(raw, 'SW has independently checked aerial building envelopes');
  return raw;
}

test('SW reconstructs 302 unambiguous diagram units and preserves the eight identity gaps', async () => {
  const raw = await sw();
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 302);
  assert.equal(new Set(units.map(unit => unit.building)).size, 27);
  for (const id of ['1075', '1076', '1077', '1078', '1175', '1176', '1177', '1178']) {
    assert.ok(!units.some(unit => unit.unit === id));
    assert.ok(raw.unresolved.units.includes(id));
  }
  assert.ok(units.every(unit => unit.membershipBasis === 'diagramPrintedUnits' && !unit.parcel));
  assert.ok(units.every(unit => unit.calibration.heldoutMaximumResidualMeters < 4));
  assert.equal(units.find(unit => unit.unit === '2021').building, '3');
});

test('SW labels cannot be assigned outside the independently digitized roof envelope', async () => {
  const raw = structuredClone(await sw());
  raw.buildings[0].referencePolygon = raw.buildings[0].referencePolygon.map(([x, y]) => [x + 300, y]);
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /outside.*building/i);
});

test('SW ambiguous source labels cannot be silently assigned to either building', async () => {
  const raw = structuredClone(await sw());
  raw.membership.ambiguousUnitIdentities = [];
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /ambiguous|duplicate/i);
});

test('Sunset Canyon preserves 187 printed labels including the three unpaired building-8 labels', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'sunset-canyon');
  assert.ok(raw, 'Sunset Canyon source facts are independently reviewed');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 187);
  assert.equal(new Set(units.map(unit => JSON.stringify(unit.coordinates))).size, 95);
  assert.deepEqual(units.filter(unit => unit.building === '8').map(unit => unit.unit), ['1045', '1046', '1047']);
  assert.ok(!units.some(unit => ['2045', '2046', '2047'].includes(unit.unit)));
  assert.ok(units.every(unit => unit.floor === '' && unit.calibration.heldoutMaximumResidualMeters < 4));
});

test('Arbor Pointe keeps the unsupported building-6 registration as an explicit 20-unit gap', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'arbor-pointe');
  assert.ok(raw, 'Arbor Pointe partial registration is independently reviewed');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 160);
  assert.equal(new Set(units.map(unit => unit.building)).size, 7);
  assert.ok(units.every(unit => unit.building !== '6'));
  assert.equal(raw.excludedRegistration.stacks.flatMap(stack => stack.units).length, 20);
  assert.ok(raw.excludedRegistration.controls.some(point => point.residualMeters > 9));
  assert.ok(raw.excludedRegistration.stacks.flatMap(stack => stack.units).every(unit =>
    raw.unresolved.units.includes(unit) && !units.some(position => position.unit === unit)));
});

test('mandatory source hashes and HTTPS URLs cannot disappear from registered facts', async () => {
  for (const source of ['plan', 'reference', 'membership']) {
    const raw = structuredClone(await cabrillo());
    delete raw[source].sha256;
    assert.throws(() => api.deriveRegisteredUnitPositions(raw), /source|hash|provenance/i);
    const badURL = structuredClone(await cabrillo());
    badURL[source].url = 'http://example.com/map';
    assert.throws(() => api.deriveRegisteredUnitPositions(badURL), /source|https|provenance/i);
  }
  const raw = structuredClone(await sw());
  raw.propertyBoundary.sha256 = 'not-a-digest';
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /source|hash|provenance/i);
});

test('every calibration control has a positive integer observation ID', async () => {
  for (const id of [undefined, -1, 1.5, '1']) {
    const raw = structuredClone(await cabrillo());
    raw.controls[0].id = id;
    assert.throws(() => api.deriveRegisteredUnitPositions(raw), /control/i);
  }
});

test('EVO reconstructs 374 printed labels while retaining two unsupported building-20 observations', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'evo');
  assert.ok(raw, 'EVO source labels and aerial registration are independently reviewed');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 374);
  assert.equal(new Set(units.map(unit => unit.building)).size, 31);
  assert.deepEqual(raw.unresolved.units, ['2153', '2154']);
  assert.ok(!units.some(unit => unit.building === '20'));
  assert.deepEqual(raw.excludedRegistration.stacks.flatMap(stack => stack.units), ['2153', '2154']);
  assert.ok(['1226', '1228', '1233'].every(id => units.some(unit => unit.unit === id)));
  assert.ok(units.every(unit => unit.floor === '' && unit.calibration.heldoutMaximumResidualMeters < 4.1));
});

test('Solana preserves 192 printed labels and leaves all 12 building-5 labels unresolved', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'solana-post');
  assert.ok(raw, 'Solana partial registration retains independently measured outline corners');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 192);
  assert.equal(new Set(units.map(unit => unit.building)).size, 16);
  assert.equal(new Set(units.map(unit => JSON.stringify(unit.coordinates))).size, 80);
  assert.equal(raw.excludedRegistration.stacks.flatMap(stack => stack.units).length, 12);
  assert.ok(units.every(unit => unit.building !== '5' && unit.calibration.heldoutMaximumResidualMeters < 3));
  assert.equal(units.find(unit => unit.unit === '1076').building, '16');
  assert.ok(!units.some(unit => unit.unit === '1003')); // The plan prints only 2003 and 3003.
});

test('untranscribed label gaps require an integer count, explicit scope, and an honest total', async () => {
  for (const count of [-1, 1.5, '248']) {
    const raw = structuredClone(await sw());
    raw.unresolved.unmappedPrintedLabelCount = count;
    assert.throws(() => api.deriveRegisteredUnitPositions(raw), /unmapped|scope|count/i);
  }
  const raw = structuredClone(await sw());
  raw.unresolved.unmappedPrintedLabelCount = 10;
  assert.throws(() => api.deriveRegisteredUnitPositions(raw), /scope|total/i);
});

test('manifest and hashed source facts use LF bytes that survive Git normalization', async () => {
  const root = new URL('../../research/geography/registered-unit-maps/', import.meta.url);
  const bytes = await readFile(new URL('manifest.json', root));
  assert.ok(!bytes.includes(13), 'manifest uses LF bytes');
  for (const entry of JSON.parse(bytes).snapshots) {
    const facts = await readFile(new URL(entry.file, root));
    assert.ok(!facts.includes(13), entry.file + ' uses LF bytes');
  }
});

test('Level25 Sunset accepts only building 10 and retains the 248-label geographic gap', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'level25-sunset');
  assert.ok(raw, 'Sunset building-10 local corners are independently reviewed');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 12);
  assert.deepEqual([...new Set(units.map(unit => unit.building))], ['10']);
  assert.equal(raw.unresolved.unmappedPrintedLabelCount, 248);
  assert.equal(raw.membership.totalPrintedLabelCount, 260);
  assert.ok(raw.rejectedGlobalCalibration.heldoutMaximumResidualMeters > 10);
  assert.ok(units.every(unit => unit.calibration.heldoutMaximumResidualMeters < 0.5));
  for (const change of [
    item => { item.membership.totalPrintedLabelCount = 12; },
    item => { delete item.unresolved.unmappedPrintedLabelCount; },
    item => { item.registrationScope.buildings = ['1']; },
  ]) {
    const invalid = structuredClone(raw);
    change(invalid);
    assert.throws(() => api.deriveRegisteredUnitPositions(invalid), /scope|total|unmapped|count/i);
  }
});

test('Level25 Curve preserves its 326 explicit labels without inventing building 10 or loft floors', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'level25-curve');
  assert.ok(raw, 'Curve controls, labels, and independent roof envelopes are reviewed');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 326);
  assert.equal(new Set(units.map(unit => unit.building)).size, 19);
  assert.ok(!units.some(unit => unit.building === '10'));
  assert.deepEqual(units.filter(unit => unit.building === '5').map(unit => unit.unit), ['2026', '2027']);
  assert.ok(units.every(unit => unit.calibration.heldoutMaximumResidualMeters < 3.8));
});

test('Level25 Oquendo preserves corrected 2118 and all eight printed building-23 identities', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'level25-oquendo');
  assert.ok(raw, 'Oquendo source identities and independent registration are reviewed');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 302);
  assert.equal(new Set(units.map(unit => unit.building)).size, 23);
  assert.deepEqual(units.filter(unit => unit.building === '22').map(unit => unit.unit), ['2118']);
  assert.deepEqual(units.filter(unit => unit.building === '23').map(unit => unit.unit),
    ['1119', '1120', '1121', '1122', '2119', '2120', '2121', '2122']);
  assert.ok(!units.some(unit => ['1093', '1100', '3118'].includes(unit.unit)));
  assert.ok(units.every(unit => unit.calibration.heldoutMaximumResidualMeters < 3.8));
});

test('Wyatt keeps all 58 repeated occurrences as evidence while deriving only 250 unique labels', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'wyatt');
  assert.ok(raw, 'Wyatt repeated identities remain explicitly excluded');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 250);
  assert.equal(raw.membership.printedLabelCount, 308);
  assert.equal(raw.rejectedAmbiguousStacks.flatMap(stack => stack.units).length, 58);
  assert.equal(raw.membership.ambiguousUnitIdentities.length, 22);
  assert.ok(units.every(unit => !raw.membership.ambiguousUnitIdentities.includes(unit.unit)));
  assert.ok(!units.some(unit => ['14', '17'].includes(unit.building)));
  assert.equal(new Set(units.map(unit => JSON.stringify(unit.coordinates))).size, 135);
  const missingEvidence = structuredClone(raw);
  delete missingEvidence.rejectedAmbiguousStacks;
  assert.throws(() => api.deriveRegisteredUnitPositions(missingEvidence), /ambiguous|count/i);
  const falseExclusion = structuredClone(raw);
  falseExclusion.rejectedAmbiguousStacks.push({id: 'fabricated', building: '14', planPixel: [1, 2], units: ['99999']});
  assert.throws(() => api.deriveRegisteredUnitPositions(falseExclusion), /rejected ambiguous/i);
});

test('St. Clair preserves 184 literal labels with occluded controls excluded from the fit', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'st-clair');
  assert.ok(raw, 'St. Clair source labels and independent corner review are retained');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 184);
  assert.equal(new Set(units.map(unit => unit.building)).size, 23);
  assert.equal(units[0].calibration.fitControls, 7);
  assert.equal(units[0].calibration.heldoutControls, 14);
  assert.deepEqual(raw.observationReview.excludedControls.map(point => point.id), [8, 16, 17, 20]);
  assert.ok(raw.observationReview.excludedControls.every(point => !raw.controls.some(used => used.id === point.id)));
  assert.ok(units.every(unit => unit.calibration.heldoutMaximumResidualMeters < 3.9));
  assert.equal(units.find(unit => unit.unit === '242').building, '11');
  assert.deepEqual(units.find(unit => unit.unit === '142').coordinates, units.find(unit => unit.unit === '242').coordinates);
});

test('Zerzura keeps 466 exact building-qualified units, with local labels retained separately', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'zerzura');
  assert.ok(raw, 'Zerzura has source-backed qualified numbering and independent roofs');
  const units = api.deriveRegisteredUnitPositions(raw);
  assert.equal(units.length, 466);
  assert.equal(new Set(units.map(unit => unit.unit)).size, 466);
  assert.equal(new Set(units.map(unit => unit.building)).size, 24);
  assert.equal(new Set(units.map(unit => JSON.stringify(unit.coordinates))).size, 162);
  assert.ok(units.every(unit => /^\d{2}-\d{3}$/.test(unit.unit) && unit.floor === ''));
  assert.ok(raw.stacks.filter(stack => stack.sourceUnits.includes('201')).length > 20);
  assert.equal(units.find(unit => unit.unit === '03-201').building, '3');
  assert.ok(!units.some(unit => unit.unit === '201'));
  assert.deepEqual(units.filter(unit => unit.building === '8').map(unit => unit.unit), ['08-201', '08-202']);
  assert.ok(raw.identityEvidence.explicitCurrentUnitCodes.every(id => units.some(unit => unit.unit === id)));
  assert.ok(units.every(unit => unit.calibration.heldoutMaximumResidualMeters < 4));
});

test('qualified numbering rejects stripped or wrong prefixes, missing source labels, and absent format provenance', async () => {
  const raw = (await api.loadRegisteredUnitMaps()).find(item => item.communityID === 'zerzura');
  assert.ok(raw);
  for (const change of [
    item => { item.stacks[0].units[0] = item.stacks[0].sourceUnits[0]; },
    item => { item.stacks[0].units[0] = '02-' + item.stacks[0].sourceUnits[0]; },
    item => { delete item.stacks[0].sourceUnits; },
    item => { delete item.unitNumbering.sha256; },
    item => { item.unitNumbering.localDigits = 4; },
    item => { delete item.unitNumbering; },
  ]) {
    const invalid = structuredClone(raw);
    change(invalid);
    assert.throws(() => api.deriveRegisteredUnitPositions(invalid), /numbering|provenance|stack|identity/i);
  }
});
