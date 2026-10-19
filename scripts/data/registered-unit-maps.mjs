import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {resolve, sep} from 'node:path';
import {pathToFileURL} from 'node:url';
import {coordinateValid, inGeometry} from './geometry.mjs';

const assert = (condition, message) => { if (!condition) throw Error(message); };
const finitePair = point => Array.isArray(point) && point.length === 2 && point.every(Number.isFinite);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');

function validateSource(source, label) {
  assert(source && typeof source.sha256 === 'string' && /^[0-9a-f]{64}$/i.test(source.sha256),
    `Missing or invalid ${label} source hash provenance`);
  let url;
  try { url = new URL(source.url); } catch { throw Error(`Invalid ${label} source URL provenance`); }
  assert(url.protocol === 'https:' && url.hostname && !url.username && !url.password,
    `Invalid ${label} HTTPS source URL provenance`);
}

function stackValidator(raw) {
  if (raw.unitNumbering) {
    const numbering = raw.unitNumbering;
    assert(raw.membershipBasis === 'diagramPrintedUnits' && numbering.kind === 'buildingQualified' &&
      numbering.buildingDigits === 2 && numbering.localDigits === 3 && numbering.separator === '-',
    'Unsupported qualified unit numbering');
    validateSource(numbering, 'unit numbering');
  }
  return stack => {
    if (typeof stack.id !== 'string' || !stack.id || typeof stack.building !== 'string' ||
      !finitePair(stack.planPixel) || !Array.isArray(stack.units) || !stack.units.length) return false;
    if (!raw.unitNumbering) return stack.units.every(unit => typeof unit === 'string' && /^\d+$/.test(unit));
    return /^[1-9]\d?$/.test(stack.building) && Array.isArray(stack.sourceUnits) &&
      stack.sourceUnits.length === stack.units.length && stack.sourceUnits.every((local, index) =>
        typeof local === 'string' && /^\d{3}$/.test(local) &&
        stack.units[index] === stack.building.padStart(2, '0') + '-' + local);
  };
}

// Solve the two affine least-squares right-hand sides together. Coordinates are
// pixels, not geographic coordinates; the retained export extent supplies WGS84.
function affine(controls) {
  const rows = controls.map(point => [...point.planPixel, 1]);
  const augmented = Array.from({length: 3}, (_, i) => [
    ...Array.from({length: 3}, (_, j) => rows.reduce((sum, row) => sum + row[i] * row[j], 0)),
    ...[0, 1].map(axis => rows.reduce((sum, row, index) => sum + row[i] * controls[index].referencePixel[axis], 0)),
  ]);
  for (let column = 0; column < 3; column++) {
    let pivot = column;
    for (let row = column + 1; row < 3; row++) {
      if (Math.abs(augmented[row][column]) > Math.abs(augmented[pivot][column])) pivot = row;
    }
    assert(Math.abs(augmented[pivot][column]) > 1e-8, 'Degenerate calibration controls');
    [augmented[column], augmented[pivot]] = [augmented[pivot], augmented[column]];
    const divisor = augmented[column][column];
    augmented[column] = augmented[column].map(value => value / divisor);
    for (let row = 0; row < 3; row++) {
      if (row === column) continue;
      const factor = augmented[row][column];
      augmented[row] = augmented[row].map((value, index) => value - factor * augmented[column][index]);
    }
  }
  return augmented.map(row => row.slice(3));
}

function transform(point, coefficients) {
  return [0, 1].map(axis => point[0] * coefficients[0][axis] + point[1] * coefficients[1][axis] + coefficients[2][axis]);
}

function toWGS84(pixel, reference) {
  const {extent, referenceDimensions: [width, height]} = reference;
  const x = extent.xmin + pixel[0] / width * (extent.xmax - extent.xmin);
  const y = extent.ymax - pixel[1] / height * (extent.ymax - extent.ymin);
  return [x / 6378137 * 180 / Math.PI, (2 * Math.atan(Math.exp(y / 6378137)) - Math.PI / 2) * 180 / Math.PI];
}

function calibration(raw) {
  const {reference, acceptance, controls} = raw;
  assert(reference?.extent?.spatialReference?.latestWkid === 3857 &&
    finitePair(reference.referenceDimensions) && reference.referenceDimensions.every(value => value > 0),
  'Invalid calibration reference projection or dimensions');
  const extent = reference.extent;
  assert(['xmin', 'xmax', 'ymin', 'ymax'].every(key => Number.isFinite(extent[key])) &&
    extent.xmin < extent.xmax && extent.ymin < extent.ymax, 'Invalid calibration extent');
  const center = toWGS84(reference.referenceDimensions.map(value => value / 2), reference);
  const scale = Math.cos(center[1] * Math.PI / 180);
  const metersX = (extent.xmax - extent.xmin) / reference.referenceDimensions[0] * scale;
  const metersY = (extent.ymax - extent.ymin) / reference.referenceDimensions[1] * scale;
  assert(Array.isArray(controls) && controls.every(point =>
    Number.isInteger(point.id) && point.id > 0 && finitePair(point.planPixel) &&
    finitePair(point.referencePixel) && ['fit', 'heldout'].includes(point.role)),
  'Invalid calibration control');
  assert(new Set(controls.map(point => point.id)).size === controls.length &&
    new Set(controls.map(point => JSON.stringify(point.planPixel))).size === controls.length,
  'Duplicate calibration controls');
  const fit = controls.filter(point => point.role === 'fit');
  const heldout = controls.filter(point => point.role === 'heldout');
  assert(acceptance?.minimumFitControls >= 5 && acceptance?.minimumHeldoutControls >= 3 &&
    fit.length >= acceptance.minimumFitControls && heldout.length >= acceptance.minimumHeldoutControls,
  'Insufficient independent calibration controls');
  assert(acceptance.maximumFitRMSEMeters <= 3 && acceptance.maximumFitResidualMeters <= 5 &&
    acceptance.maximumHeldoutRMSEMeters <= 3 && acceptance.maximumHeldoutResidualMeters <= 5,
  'Unsupported calibration residual limits');
  for (const axis of [0, 1]) {
    const span = points => Math.max(...points.map(point => point[axis])) - Math.min(...points.map(point => point[axis]));
    assert(span(fit.map(point => point.planPixel)) >= 0.6 * span(raw.stacks.map(stack => stack.planPixel)),
      'Calibration controls do not span the directory');
  }
  const coefficients = affine(fit);
  const provenance = {model: 'affine', coefficients, fitControls: fit.length, heldoutControls: heldout.length,
    planURL: raw.plan.url, planSHA256: raw.plan.sha256,
    referenceURL: reference.url, referenceSHA256: reference.sha256,
    sourceAcquisitionDate: reference.acquisitionDate, absoluteAccuracyMeters: reference.absoluteAccuracyMeters,
    meaning: 'Residuals measure diagram registration consistency, not absolute door accuracy.'};
  for (const [role, points] of [['fit', fit], ['heldout', heldout]]) {
    const errors = points.map(point => {
      const predicted = transform(point.planPixel, coefficients);
      return Math.hypot((predicted[0] - point.referencePixel[0]) * metersX,
        (predicted[1] - point.referencePixel[1]) * metersY);
    });
    const rmse = Math.sqrt(errors.reduce((sum, error) => sum + error * error, 0) / errors.length);
    const maximum = Math.max(...errors);
    const title = role === 'fit' ? 'Fit' : 'Heldout';
    assert(rmse <= acceptance[`maximum${title}RMSEMeters`] && maximum <= acceptance[`maximum${title}ResidualMeters`],
      `${role} calibration residual exceeds accepted limit`);
    provenance[`${role}RMSEMeters`] = rmse;
    provenance[`${role}MaximumResidualMeters`] = maximum;
  }
  return provenance;
}

export function deriveRegisteredUnitPositions(raw) {
  assert(raw.version === 1 && /^[a-z0-9-]+$/.test(raw.communityID) &&
    Number.isInteger(raw.expectedPositions) && raw.expectedPositions > 0, 'Invalid registered directory identity');
  validateSource(raw.plan, 'plan');
  validateSource(raw.reference, 'reference');
  validateSource(raw.membership, 'membership');
  if (raw.propertyBoundary) validateSource(raw.propertyBoundary, 'property boundary');
  assert(['countyDirectory', 'diagramPrintedUnits'].includes(raw.membershipBasis) && raw.membership?.basis === raw.membershipBasis,
    'Unsupported registered directory membership basis');
  const validStack = stackValidator(raw);
  assert(raw.stacks?.length === raw.expectedStackCount && raw.stacks.every(validStack),
    'Invalid printed stack count or identity');
  assert(new Set(raw.stacks.map(stack => stack.id)).size === raw.stacks.length, 'Duplicate printed stack identity');
  const buildingMap = new Map();
  for (const building of raw.buildings ?? []) {
    let geometry = building.geometry;
    if (raw.membershipBasis === 'diagramPrintedUnits') {
      assert(building.basis === 'aerialRoofEnvelope' && building.referencePolygon?.length >= 4 &&
        building.referencePolygon.every(finitePair), 'Invalid independent aerial building envelope');
      geometry = {type: 'Polygon', coordinates: [building.referencePolygon.map(pixel => toWGS84(pixel, raw.reference))]};
    } else assert(building.basis === 'countyDirectoryBuildingEnvelope', 'Invalid county building evidence basis');
    assert(!buildingMap.has(building.building) &&
      geometry?.type === 'Polygon' && geometry.coordinates.length &&
      geometry.coordinates.every(ring => ring.length >= 4 && ring.every(coordinateValid) &&
        JSON.stringify(ring[0]) === JSON.stringify(ring.at(-1))), 'Invalid independent building geometry');
    buildingMap.set(building.building, {...building, geometry});
  }
  const directory = new Map();
  const ambiguous = new Set();
  const unmappedCount = raw.unresolved?.unmappedPrintedLabelCount;
  if (unmappedCount !== undefined || raw.registrationScope || raw.membership.totalPrintedLabelCount !== undefined) {
    assert(Number.isInteger(unmappedCount) && unmappedCount >= 0, 'Invalid unmapped printed label count');
    assert(raw.membershipBasis === 'diagramPrintedUnits' &&
      raw.registrationScope?.kind === 'selectedBuildings' &&
      Array.isArray(raw.registrationScope.buildings) && raw.registrationScope.buildings.length > 0 &&
      new Set(raw.registrationScope.buildings).size === raw.registrationScope.buildings.length &&
      raw.registrationScope.buildings.length === buildingMap.size &&
      raw.registrationScope.buildings.every(building => buildingMap.has(building)) &&
      raw.stacks.every(stack => raw.registrationScope.buildings.includes(stack.building)),
    'Invalid selected-building registration scope');
    assert(Number.isInteger(raw.membership.totalPrintedLabelCount) &&
      raw.membership.totalPrintedLabelCount === raw.membership.printedLabelCount + unmappedCount,
    'Printed label total does not preserve the unmapped count');
  }
  if (raw.membershipBasis === 'countyDirectory') {
    for (const record of raw.membership.records ?? []) {
      const legal = /^UNIT (\d+) BLDG (\d+)$/.exec(record.legalDescription ?? '');
      assert(legal && legal[1] === record.unit && legal[2] === record.building &&
        record.subdivision === raw.membership.expectedSubdivision && record.address === raw.address &&
        /^\d{11}$/.test(record.parcel) && !directory.has(record.unit), 'Invalid county legal unit membership');
      directory.set(record.unit, record);
    }
  } else {
    const rejectedAmbiguous = raw.rejectedAmbiguousStacks ?? [];
    assert(Array.isArray(rejectedAmbiguous) && rejectedAmbiguous.every(validStack),
    'Invalid rejected ambiguous stack observation');
    const identityStacks = [...raw.stacks, ...rejectedAmbiguous];
    assert(new Set(identityStacks.map(stack => stack.id)).size === identityStacks.length,
      'Duplicate rejected ambiguous stack observation');
    const counts = new Map();
    for (const stack of identityStacks) for (const unit of stack.units) counts.set(unit, (counts.get(unit) ?? 0) + 1);
    for (const [unit, count] of counts) if (count > 1) ambiguous.add(unit);
    assert(rejectedAmbiguous.every(stack => stack.units.every(unit => ambiguous.has(unit))),
      'Rejected ambiguous stack contains an unrepeated unit identity');
    assert(JSON.stringify([...ambiguous].sort()) === JSON.stringify([...raw.membership.ambiguousUnitIdentities].sort()) &&
      [...ambiguous].every(unit => raw.unresolved.units.includes(unit)), 'Ambiguous printed unit identity exclusions changed');
    const excludedStacks = raw.excludedRegistration?.stacks ?? [];
    for (const stack of excludedStacks) {
      assert(validStack(stack) && raw.excludedRegistration.buildings.includes(stack.building) && !buildingMap.has(stack.building) &&
        !raw.stacks.some(included => included.building === stack.building) &&
        stack.units.every(unit => raw.unresolved.units.includes(unit) && !counts.has(unit)),
      'Excluded registration building or unit identity overlaps accepted source facts');
    }
    assert([...identityStacks, ...excludedStacks].reduce((sum, stack) => sum + stack.units.length, 0) === raw.membership.printedLabelCount,
      'Printed directory label count mismatch');
    assert(raw.propertyBoundary?.basis === 'countyPropertyParcelOnly' && raw.propertyBoundary.geometry?.type === 'Polygon',
      'Missing independent property parcel containment');
    for (const stack of raw.stacks) for (const unit of stack.units) {
      if (!ambiguous.has(unit)) directory.set(unit, {unit, building: stack.building, address: raw.address});
    }
  }
  assert(directory.size === raw.expectedPositions, 'Unit membership count mismatch');
  const provenance = calibration(raw);
  if (raw.unitNumbering) provenance.unitNumbering = {...raw.unitNumbering};
  const seen = new Set();
  const positions = [];
  for (const stack of raw.stacks) {
    const building = buildingMap.get(stack.building);
    assert(building, 'Missing independent building geometry');
    const coordinates = toWGS84(transform(stack.planPixel, provenance.coefficients), raw.reference);
    assert(coordinateValid(coordinates) && inGeometry(coordinates, building.geometry),
      'Registered unit stack outside its assigned building ' + stack.id);
    if (raw.propertyBoundary) assert(inGeometry(coordinates, raw.propertyBoundary.geometry),
      'Registered unit stack outside its independent property parcel');
    for (const unit of stack.units) {
      if (ambiguous.has(unit)) continue;
      const membership = directory.get(unit);
      assert(!seen.has(unit) && membership && membership.building === stack.building,
        'Printed unit identity does not match unique building membership ' + unit);
      seen.add(unit);
      positions.push({unit, building: stack.building, floor: '', address: membership.address,
        coordinates: [...coordinates], sourceUnitID: `registered-${raw.communityID}-${stack.building}-${unit}`,
        parcel: membership.parcel, sourceStackID: stack.id, membershipBasis: raw.membershipBasis,
        calibration: provenance});
    }
  }
  assert(positions.length === raw.expectedPositions && [...directory.keys()].every(unit => seen.has(unit)),
    'Printed unit count or county membership is missing');
  return positions.sort((left, right) => left.unit.localeCompare(right.unit));
}

export async function loadRegisteredUnitMaps(rootURL = new URL('../../research/geography/registered-unit-maps/', import.meta.url)) {
  const root = rootURL instanceof URL ? rootURL : typeof rootURL === 'string' && rootURL.startsWith('file:')
    ? new URL(rootURL) : pathToFileURL(resolve(rootURL) + sep);
  const manifest = JSON.parse(await readFile(new URL('manifest.json', root), 'utf8'));
  assert(manifest.version === 1 && Array.isArray(manifest.snapshots), 'Invalid registered map manifest');
  const seen = new Set();
  const maps = [];
  for (const entry of manifest.snapshots) {
    assert(!seen.has(entry.communityID) && /^[a-z0-9][a-z0-9.-]*\.json$/.test(entry.file),
      'Duplicate community or invalid registered map filename');
    seen.add(entry.communityID);
    const bytes = await readFile(new URL(entry.file, root));
    assert(digest(bytes) === entry.sha256, 'Registered source facts hash mismatch: ' + entry.file);
    const raw = JSON.parse(bytes);
    assert(raw.communityID === entry.communityID && raw.expectedPositions === entry.expectedPositions,
      'Registered source identity or count mismatch');
    raw.sourceFiles = [entry.file];
    deriveRegisteredUnitPositions(raw);
    maps.push(raw);
  }
  return maps;
}
