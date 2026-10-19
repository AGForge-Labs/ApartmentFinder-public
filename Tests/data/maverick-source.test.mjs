import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {inGeometry} from '../../scripts/data/geometry.mjs';

const root = new URL('../../', import.meta.url);
const read = async path => JSON.parse(await readFile(new URL(path, root)));

test('Maverick native map is withheld despite valid public identity and all 344 source joins', async () => {
  const review = await read('research/audits/maverick-geography-review.json');
  assert.equal(review.status, 'withheld');
  assert.equal(review.identity.assetID, '9559');
  assert.equal(review.identity.officialEmbedURL, 'https://sightmap.com/embed/zdqw9918wo9');
  assert.equal(review.identity.parcel, '17604601021');
  assert.equal(review.reviewMetrics.unitLabels, 344);
  assert.equal(review.reviewMetrics.insideCountyPropertyParcel, 344);
  assert.equal(review.reviewMetrics.outsideBroadRoofEnvelope, 114);
  assert.equal(review.reviewMetrics.acceptedPositions, 0);
  const records = await read('research/maps/public-map-facts.json');
  assert.equal(records.filter(r => r.communityID === 'maverick').flatMap(r => r.maps)
    .filter(m => m.geometrySHA256 === review.sources.geojson.sha256 && m.points.length).length, 0);
  for (const source of Object.values(review.sources)) {
    assert.equal(new URL(source.url).protocol, 'https:');
    assert.match(source.sha256, /^[a-f0-9]{64}$/);
    assert.ok(Number.isFinite(Date.parse(source.retrievedAt)));
  }
});

test('Maverick rejected native coordinates remain outside their observed roofs and out of accepted pins', async () => {
  const review = await read('research/audits/maverick-geography-review.json');
  const locations = await read('data/locations.geojson');
  const {extent, dimensions: [width, height]} = review.reference;
  assert.deepEqual(review.rejectedExamples.map(e => e.unit), ['1204', '1238', '1242', '1025']);
  for (const example of review.rejectedExamples) {
    const [longitude, latitude] = example.nativeCoordinates;
    const mx = longitude * Math.PI / 180 * 6378137;
    const my = Math.log(Math.tan(Math.PI / 4 + latitude * Math.PI / 360)) * 6378137;
    const pixel = [(mx - extent.xmin) / (extent.xmax - extent.xmin) * width,
      (extent.ymax - my) / (extent.ymax - extent.ymin) * height];
    assert.ok(pixel.every((v, axis) => Math.abs(v - example.referencePixel[axis]) < 1e-5));
    assert.equal(inGeometry(pixel, {type: 'Polygon', coordinates: [example.broadRoofReferencePolygon]}), false);
    assert.ok(example.distanceOutsideBroadRoofMeters > 5);
    assert.equal(locations.features.some(f => f.properties.communityID === 'maverick' &&
      f.properties.kind === 'unitPosition' && f.geometry.coordinates.every((v, axis) =>
        Math.abs(v - example.nativeCoordinates[axis]) < 1e-8)), false);
  }
});
