// Explicitly lower-confidence directory bays. These never pass as strict
// registrations or checked doors. Source images remain outside the app bundle.
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {inRing,coordinateValid} from './geometry.mjs';

const root = new URL('../../research/geography/estimated-unit-maps/', import.meta.url);
const text = value => typeof value === 'string' && value.trim().length > 0;
const pair = value => Array.isArray(value) && value.length === 2 && value.every(Number.isFinite);
const requireFact = (ok,message) => { if (!ok) throw Error(message); };
const iso = value => text(value) && Number.isFinite(Date.parse(value));

export function estimatedPixelCoordinate(pixel,reference) {
 const [west,south,east,north] = reference.extent;
 const mercator = latitude => Math.log(Math.tan(Math.PI / 4 + latitude * Math.PI / 360));
 const y = mercator(north) + pixel[1] / reference.height * (mercator(south) - mercator(north));
 return [west + pixel[0] / reference.width * (east - west), (2 * Math.atan(Math.exp(y)) - Math.PI / 2) * 180 / Math.PI];
}

export function deriveEstimatedUnitPositions(raw) {
 requireFact(raw?.schemaVersion === 1 && text(raw.communityID) && text(raw.address), 'estimated directory identity/schema');
 requireFact(iso(raw.retrievedAt), 'estimated retrieval date');
 requireFact(raw.method?.type === 'buildingRelativeDiagramBays' && raw.method.strictRegistrationAccepted === false && text(raw.method.notes), 'estimated method must not claim strict registration');
 requireFact(Array.isArray(raw.sources) && raw.sources.length >= 2, 'estimated sources');
 const sourceIDs = new Set();
 for (const source of raw.sources) {
  requireFact(text(source.id) && !sourceIDs.has(source.id) && text(source.title) && text(source.kind) && iso(source.retrievedAt), 'estimated source identity');
  sourceIDs.add(source.id);
  requireFact(/^[a-f0-9]{64}$/.test(source.sha256 ?? ''), 'estimated source hash');
  if (source.localOnly) requireFact(!source.url, 'local-only source must not publish a URL');
  else {
   let url; try { url = new URL(source.url); } catch {}
   requireFact(url?.protocol === 'https:' && !!url.hostname && !url.username && !url.password, 'estimated source URL');
  }
 }
 requireFact(raw.sources.some(s => !s.localOnly), 'estimated public source required');
 const ref = raw.reference;
 requireFact(ref && raw.sources.some(s => s.id === ref.sourceID && !s.localOnly), 'estimated reference source');
 requireFact(Number.isInteger(ref.width) && ref.width > 0 && Number.isInteger(ref.height) && ref.height > 0, 'reference dimensions');
 requireFact(ref.spatialReference === 'EPSG:4326' && ref.projection === 'webMercator' && Array.isArray(ref.extent) && ref.extent.length === 4, 'reference extent/projection');
 const [west,south,east,north] = ref.extent;
 requireFact(coordinateValid([west,south]) && coordinateValid([east,north]) && west < east && south < north && Math.abs(south) < 85 && Math.abs(north) < 85, 'reference geographic extent');
 const insideImage = p => pair(p) && p[0] >= 0 && p[0] <= ref.width && p[1] >= 0 && p[1] <= ref.height;
 requireFact(Array.isArray(raw.buildings) && raw.buildings.length > 0, 'estimated buildings');
 const buildings = new Map();
 for (const b of raw.buildings) {
  requireFact(text(b.building) && b.sourceBuildingToken === b.building && !buildings.has(b.building) && text(b.correspondenceNotes), 'estimated building identity/correspondence');
  const ring = b.referencePixelOutline;
  requireFact(Array.isArray(ring) && ring.length >= 4 && ring.every(insideImage) && JSON.stringify(ring[0]) === JSON.stringify(ring.at(-1)), 'building pixel outline');
  const area = Math.abs(ring.slice(1).reduce((sum,p,i) => sum + ring[i][0]*p[1] - p[0]*ring[i][1],0))/2;
  requireFact(area > 1, 'degenerate building outline');
  buildings.set(b.building,b);
 }
 requireFact(Array.isArray(raw.stacks) && raw.stacks.length > 0, 'estimated stacks');
 const stackIDs = new Set(), identities = new Set(), byUnit = new Map(), points = [];
 for (const stack of raw.stacks) {
  requireFact(text(stack.id) && /^[a-z0-9-]+$/.test(stack.id) && !stackIDs.has(stack.id), 'duplicate/malformed stack');
  stackIDs.add(stack.id);
  const building = buildings.get(stack.building);
  requireFact(!!building, 'unknown estimated building');
  requireFact(pair(stack.sourcePixel) && stack.sourcePixel.every(v => v >= 0) && insideImage(stack.referencePixel), 'invalid source/reference pixel');
  requireFact(inRing(stack.referencePixel,building.referencePixelOutline), 'estimated pixel outside observed building');
  requireFact(Number.isFinite(stack.uncertaintyMeters) && stack.uncertaintyMeters > 0 && stack.uncertaintyMeters <= 100, 'estimated uncertainty required');
  requireFact(text(stack.notes) && Array.isArray(stack.sourceUnits) && stack.sourceUnits.length > 0, 'estimated literal unit evidence');
  const units = stack.units ?? stack.sourceUnits;
  if (stack.units !== undefined) requireFact(Array.isArray(units) && units.length === stack.sourceUnits.length && stack.identityHypothesis?.basis === 'directorySequence' && text(stack.identityHypothesis.notes), 'unit substitution requires an explicit numbering hypothesis');
  else requireFact(!stack.identityHypothesis, 'identity hypothesis requires explicit proposed units');
  for (const [index,unit] of units.entries()) {
   const sourceUnit = stack.sourceUnits[index];
   requireFact(text(sourceUnit) && /^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/.test(sourceUnit), 'invalid literal source unit token');
   requireFact(text(unit) && /^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*$/.test(unit), 'invalid literal unit token');
   const key = stack.building + '|' + unit.toLowerCase();
   requireFact(!identities.has(key), 'duplicate unit in building'); identities.add(key);
   const other = byUnit.get(unit.toLowerCase()) ?? [];
   other.push(stack); byUnit.set(unit.toLowerCase(),other);
   points.push({sourceUnitID:'estimate-'+stack.id+'-'+unit.toLowerCase(), sourceStackID:stack.id,
    address:raw.address, unit, building:stack.building, floor:'', verification:'estimated',
    coordinates:estimatedPixelCoordinate(stack.referencePixel,ref), uncertaintyMeters:stack.uncertaintyMeters,
    identityAmbiguous:stack.identityAmbiguous === true, sourceUnit,
    identityHypothesis:stack.identityHypothesis ?? null,
    identityUncertain:stack.identityAmbiguous === true || !!stack.identityHypothesis, notes:stack.notes});
  }
 }
 for (const stacks of byUnit.values()) if (stacks.length > 1) {
  requireFact(stacks.every(s => s.identityAmbiguous === true && text(s.ambiguityGroup) && s.ambiguityGroup === stacks[0].ambiguityGroup), 'repeated identity requires explicit ambiguity');
 }
 requireFact(Number.isInteger(raw.expectedPositions) && points.length === raw.expectedPositions, 'estimated position count mismatch');
 requireFact(Array.isArray(raw.unresolved) && Array.isArray(raw.coverageNotes) && raw.coverageNotes.every(text), 'estimated coverage accounting');
 return points;
}

export async function loadEstimatedUnitMaps() {
 const manifest = JSON.parse(await readFile(new URL('manifest.json',root),'utf8'));
 requireFact(manifest.schemaVersion === 1 && Array.isArray(manifest.datasets), 'estimated manifest');
 const communities = new Set(), datasets = [];
 for (const entry of manifest.datasets) {
  requireFact(text(entry.file) && /^[a-z0-9-]+\.json$/.test(entry.file) && !communities.has(entry.communityID), 'estimated manifest file/duplicate');
  const bytes = await readFile(new URL(entry.file,root));
  requireFact(createHash('sha256').update(bytes).digest('hex') === entry.sha256, 'estimated snapshot hash mismatch '+entry.file);
  const raw = JSON.parse(bytes);
  requireFact(raw.communityID === entry.communityID && raw.expectedPositions === entry.expectedPositions, 'estimated manifest identity/count');
  deriveEstimatedUnitPositions(raw); communities.add(raw.communityID); datasets.push(raw);
 }
 return datasets;
}
