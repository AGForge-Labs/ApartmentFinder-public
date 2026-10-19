import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {deriveCountyUnitPositions, loadCountyUnitCoverage} from '../../scripts/data/county-unit-labels.mjs';

const read = async name => JSON.parse(await readFile(new URL('../../' + name, import.meta.url)));
const catalog = await read('data/catalog.json');
const points = (await read('data/locations.geojson')).features;
const snapshot = await read('research/geography/county-unit-coverage/spanish-ridge-7380.json');
const membership = await read('research/geography/county-unit-coverage/spanish-ridge-7380-membership.json');
const fixture = () => ({
  communityID: 'spanish-ridge-7380', mode: 'parcelLabels', retrievedAt: snapshot.retrievedAt,
  expectedDirectoryRows: 1, expectedAnnotationRows: 80, expectedUnitRows: 0, expectedPositions: 68,
  identity: {street: {direction:'W', name:'RUSSELL', type:'RD', numbers:[[7380,1]]},
    subdivisionPlats:[['SPANISH RIDGE CONDO','67','68',1]], apnPrefixes:['16327412'],
    exactAPN:'16327412069', legalDescription:'ALL UNITS BUILDINGS A-H,J'},
  directory:{...structuredClone(snapshot.directory.data), count:1},
  annotations:{...structuredClone(snapshot.annotations.data), count:80},
  excludedAPNs:[], excludedDirectoryRows:[], legalOnlyRows:[], unresolvedRows:[], allowedUTPrefixUnits:[],
  parcelUnitDigits:3, reviewedParcelMembership:structuredClone(membership),
  supplementalSources:[{url:membership.sourceSitePlanURL, sha256:membership.sourceSitePlanSHA256}],
});

test('7380 and 7340 Russell have separate catalog and saved-unit address identities', () => {
  const small = catalog.communities.find(c => c.id === 'spanish-ridge-7380');
  const large = catalog.communities.find(c => c.id === 'spanish-ridge');
  assert.ok(small, 'Missing the separate 7380 Russell section');
  assert.equal(small.address, '7380 W Russell Rd');
  assert.equal(small.zip, '89113');
  assert.equal(large.address, '7340 W Russell Rd');
  assert.deepEqual(small.deliveryAddresses, ['7380 W RUSSELL RD']);
  assert.deepEqual(large.deliveryAddresses, ['7340 W RUSSELL RD']);
  assert.deepEqual(small.aliases, []);
  assert.deepEqual(large.aliases, []);
  const savedSmall = points.filter(f => f.properties.communityID === small.id);
  const savedLarge = points.filter(f => f.properties.communityID === large.id);
  assert.equal(savedSmall.length, 68);
  assert.equal(savedLarge.length, 180);
  assert.ok(savedSmall.every(f => f.properties.address === '7380 W RUSSELL RD' && /^\d{3}$/.test(f.properties.unit)));
  assert.ok(savedLarge.every(f => f.properties.address === '7340 W RUSSELL RD' && /^\d{4}$/.test(f.properties.unit)));
  assert.ok(Math.max(...savedSmall.map(f => f.geometry.coordinates[0])) < Math.min(...savedLarge.map(f => f.geometry.coordinates[0])),
    'The 7380 section must remain west of the separate 7340 section');
  assert.ok(savedSmall.every(f => f.properties.kind === 'unitPosition' && f.properties.verification === 'sourceMapped' && f.properties.floor === ''));
  assert.match(savedSmall.find(f => f.properties.unit === '201').properties.notes, /201.*211/);
});

test('source derivation retains all 68 literal county labels and separately evidenced lettered buildings', () => {
  const derived = deriveCountyUnitPositions(fixture());
  assert.equal(derived.length, 68);
  for (const [unit, building] of [['101','A'], ['105','B'], ['112','C'], ['113','D'], ['117','E'],
    ['122','F'], ['126','G'], ['130','H'], ['134','J'], ['211','C'], ['234','J']]) {
    const point = derived.find(p => p.unit === unit);
    assert.equal(point?.building, building, 'Unsupported or missing building for ' + unit);
    assert.equal(point.address, '7380 W RUSSELL RD');
    assert.equal(point.parcel, '16327412069');
    assert.equal(point.floor, '');
    assert.deepEqual(point.supplementalSourceURLs, [membership.sourceSitePlanURL]);
  }
  const disputed = derived.find(p => p.unit === '201');
  assert.ok(disputed, 'Retain county 201 without converting it to the diagram typo 211');
  assert.equal(disputed.building, '');
  assert.equal(derived.filter(p => p.unit === '211').length, 1);
});

test('loader binds the 7380 street, source hashes and membership evidence without modifying 7340', async () => {
  const datasets = await loadCountyUnitCoverage();
  const small = datasets.find(r => r.communityID === 'spanish-ridge-7380');
  assert.ok(small, '7380 public source snapshot is not included in the reproducible pack');
  assert.equal(small.parcelUnitDigits, 3);
  assert.deepEqual(small.identity.street.numbers, [[7380,1]]);
  assert.equal(deriveCountyUnitPositions(small).length, 68);
  const large = datasets.find(r => r.communityID === 'spanish-ridge');
  assert.equal(deriveCountyUnitPositions(large).length, 180);
  assert.ok(deriveCountyUnitPositions(large).every(p => p.address === '7340 W RUSSELL RD' && p.building === ''));
});

test('7380 derivation rejects changed section identity, duplicate membership and unsupported precision', () => {
  const wrongStreet = fixture(); wrongStreet.directory.features[0].attributes.strno = 7340;
  assert.throws(() => deriveCountyUnitPositions(wrongStreet), /identity/i);
  const wrongDigits = fixture(); wrongDigits.parcelUnitDigits = 2;
  assert.throws(() => deriveCountyUnitPositions(wrongDigits), /digits|precision|parcel/i);
  const duplicate = fixture(); duplicate.reviewedParcelMembership.buildings[0].units.push('211');
  assert.throws(() => deriveCountyUnitPositions(duplicate), /membership|duplicate/i);
  const fakeBuilding = fixture(); fakeBuilding.reviewedParcelMembership.buildings[0].building = 'I';
  assert.throws(() => deriveCountyUnitPositions(fakeBuilding), /membership|building/i);
  const moved = fixture();
  const label = moved.annotations.features.find(f => f.attributes.AnnotationClassID === 21 && f.attributes.TextString.trim() === '105');
  label.geometry.rings = label.geometry.rings.map(r => r.map(([lon,lat]) => [lon+0.02,lat]));
  assert.throws(() => deriveCountyUnitPositions(moved), /annotation|contained|outside/i);
});

test('the 7380 addition preserves all 14449 previously shipped pin records exactly', () => {
  const original = points.filter(f => f.properties.communityID !== 'spanish-ridge-7380').sort((a,b) => a.id.localeCompare(b.id,'en'));
  assert.equal(original.length, 14449);
  assert.equal(createHash('sha256').update(JSON.stringify(original)).digest('hex'), '687041458c35171989df084cc3f352892def948b10f8791006bbf3418ddbdf19');
});
