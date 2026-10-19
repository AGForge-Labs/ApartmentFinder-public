import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

const facts = JSON.parse(await readFile(new URL('../../research/maps/public-map-facts.json', import.meta.url)));

// Public directory facts, independent of delivery-manifest contents.
for (const expected of [
  {communityID: '2one5', unit: '1379', building: '37'},
  {communityID: 'envision-at-sunset', unit: '1087', building: '11'},
]) {
  test(`${expected.communityID} unit ${expected.unit} retains its verified public building label`, () => {
    const map = facts.find(record => record.communityID === expected.communityID).maps[0];
    const points = map.points.filter(point => point.unit === expected.unit);
    assert.equal(points.length, 1);
    assert.equal(points[0].building, expected.building);
    const evidence = map.buildingLabelUpdates.find(update => update.sourceUnitID === points[0].sourceUnitID);
    assert.equal(evidence.building, expected.building);
    assert.match(evidence.apiSHA256, /^[a-f0-9]{64}$/);
    assert.match(evidence.buildingGroupingSHA256, /^[a-f0-9]{64}$/);
    assert.ok(evidence.witnesses.length > 0);
    assert.ok(evidence.witnesses.every(witness => witness.building === expected.building &&
      witness.buildingGroupID === evidence.buildingGroupID));
  });
}
