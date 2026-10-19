// Deterministic build from retained public factual observations. No live network calls.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {inGeometry} from './geometry.mjs';
import {findAliasBasis,validateCountyReconciliation} from './identity-evidence.mjs';
import {deriveTuscanoUnitPositions,deriveCountyUnitPositions,loadCountyUnitCoverage} from './county-unit-labels.mjs';
import {deriveRegisteredUnitPositions,loadRegisteredUnitMaps} from './registered-unit-maps.mjs';
import {deriveEstimatedUnitPositions,loadEstimatedUnitMaps} from './estimated-unit-maps.mjs';
import {inDeliveryArea,loadDeliveryAreaException} from './delivery-area-exceptions.mjs';
const root=new URL('../../',import.meta.url),read=async p=>JSON.parse(await readFile(new URL(p,root)));
const audits=await read('research/audits/site-audit.json'),maps=await read('research/maps/public-map-facts.json'),zips=await read('research/geography/county-zips.json'),roads=await read('research/geography/pace-road-facts.json');
const countyUnits=await read('research/geography/tuscano-county-unit-labels.json'),countyPoints=deriveTuscanoUnitPositions(countyUnits);
const countyCoverage=await loadCountyUnitCoverage();
const countyDatasets=[{raw:countyUnits,points:countyPoints},...countyCoverage.map(raw=>({raw,points:deriveCountyUnitPositions(raw)}))];
const registeredDatasets=(await loadRegisteredUnitMaps()).map(raw=>({raw,points:deriveRegisteredUnitPositions(raw)}));
const estimatedDatasets=(await loadEstimatedUnitMaps()).map(raw=>({raw,points:deriveEstimatedUnitPositions(raw)}));
const areaException=await loadDeliveryAreaException();
const raw=(await readFile(new URL('research/communities.tsv',root),'utf8')).trimEnd().split(/\r?\n/),headers=raw.shift().replace(/^\uFEFF/,'').split('\t');
const rows=raw.filter(Boolean).map(l=>Object.fromEntries(l.split('\t').map((v,i)=>[headers[i],v])));
const scopeZIPs=['89113','89148'],packVersion='2026.10.14.1';let generatedAt=[...audits.map(a=>a.retrievedAt),...maps.map(m=>m.retrievedAt),...countyDatasets.map(d=>d.raw.retrievedAt),...registeredDatasets.map(d=>d.raw.retrievedAt),...estimatedDatasets.map(d=>d.raw.retrievedAt),areaException.officialIdentity.retrievedAt,areaException.currentCountyProperty.retrievedAt,roads.retrievedAt].sort().at(-1);
const sources=[],seenSource=new Map(),features=[],estimatedFeatures=[],rejections=[];
const legacySourceRegistry=await read('research/audits/legacy-source-retrieval-dates.json');
const legacySourceRetrievals=legacySourceRegistry.sources;
const retainedCatalogSources=new Map((legacySourceRegistry.catalogSources??[]).map(s=>[s.url,s]));
function source(id,title,url,retrievedAt=legacySourceRetrievals[id]??generatedAt){if(seenSource.has(url))return seenSource.get(url);const record=retainedCatalogSources.get(url)??{id,title,url,retrievedAt};sources.push(record);seenSource.set(url,record.id);return record.id;}
const zipSource=source('county-zip-boundaries','Clark County ZIP boundary polygons',zips.url,zips.retrievedAt);
const gilis=await read('research/geography/county-gilis20.json');source('county-gilis20','Clark County GILIS20 multifamily candidate crosscheck (2020 vintage)',gilis.url,gilis.retrievedAt);
const exceptionSourceIDs={identity:source('spanish-wells-official-identity','Spanish Wells official address and postal ZIP',areaException.officialIdentity.url,areaException.officialIdentity.retrievedAt),county:source('spanish-wells-current-county','Clark County Spanish Wells current address and building footprints',areaException.currentCountyProperty.queryURLs.find(u=>u.includes('strno%3D5355')),areaException.currentCountyProperty.retrievedAt),boundary:source('spanish-wells-property-boundary','Clark County GILIS20 Spanish Wells property polygon',areaException.physicalBoundary.sourceURL,areaException.physicalBoundary.retrievedAt),cadastral:source('spanish-wells-cadastral-map','Clark County Spanish Wells cadastral block and streets',areaException.physicalBoundary.cadastralMapURL,areaException.physicalBoundary.retrievedAt),reference:source('spanish-wells-official-reference','Spanish Wells official site place-marker link',areaException.communityReference.sourceURL,areaException.communityReference.retrievedAt)};
for(const zip of scopeZIPs){source('directory-apartments-'+zip,'Apartments.com ZIP discovery '+zip,'https://www.apartments.com/las-vegas-nv-'+zip+'/');source('directory-apartments-'+zip+'-page2','Apartments.com ZIP discovery page 2 '+zip,'https://www.apartments.com/las-vegas-nv-'+zip+'/2/');source('directory-rentcafe-'+zip,'RentCafe ZIP discovery '+zip,'https://www.rentcafe.com/apartments-for-rent/'+zip+'-nv/');}
source('pace-pdf-2021','Pace site map dated 2021-12-07 (older crosscheck)','https://www.simpsonpropertygroup.com/Uploads2/CommunitySitePlans/Pace_Site_Map_12-7-21.pdf');
const notesByID={
 maverick:'A published property map was recovered, but its unit coordinates do not align reliably with the residential buildings. Those locations are withheld; accurate unit positions remain unresolved.',
 'level25-durango':'A printed unit directory was found, but its geographic alignment does not pass independent checks. Its labels remain research evidence rather than usable unit positions.',
 'martin-fort-apache':'The printed directory could not be aligned reliably to the residential buildings. Its unit locations remain unresolved.',
 'clubs-rhodes-ranch':'The printed directory does not pass independent geographic alignment checks. Its unit locations remain unresolved.',
 'springs-spanish-trail':'County subdivision and townhouse land use support identity; broker community listings independently label ZIP 89113. Street names are area references, not leasing-office or destination addresses. No geographic directory, entry or unit alignment established.',
 'court-yards-spanish-trail':'County subdivision and townhouse land use support identity; broker community listings independently label ZIP 89113. Mission Hills Dr is an area reference, not a leasing-office or destination address. No geographic directory, entry or unit alignment established.',
 'gardens-spanish-trail':'County subdivision and townhouse land use support identity; broker community listings independently label ZIP 89113. Street names are area references, not leasing-office or destination addresses. No geographic directory, entry or unit alignment established.',
 'islands-spanish-trail':'County records identify townhouse/condo ownership on shared private streets. Listed streets are area references, not a leasing-office address. No building or unit geography has been established.',
 'ashton-place':'County subdivision is Eldorado Condo; a broker-owned community listing identifies the Ashton Place name. No official geographic building/unit directory recovered.',
 'la-paloma':'County subdivision is Innovative Resorts Condos; public listing directions call the community La Paloma. No official geographic building/unit directory recovered.',
 melody:'The live site embeds SightMap ryzvg6mywln, whose API identifies The Milo / The Monroe in Utah. All 1,804 labels from that unrelated asset were rejected. Melody remains inventory-only.',
 alcove:'Postal address uses 89148. County ZIP polygons place 154 published unit labels in adjoining 89113; both ZIPs are in scope. The complex straddles the county boundary.',
 cabrillo:'Amenities and floor-plan pages inspected. Public image/widget material needs visual alignment; no supported geographic unit layer extracted.',
 vistana:'Condominium group spans several street numbers on S Durango (including 7103–7185); 7181 is a reference address, not every building address. HOA identity found; official directory map unresolved.',
 tuscano:'Clark County cartographic unit labels are joined to its condo unit/building directory. Label centers are approximate unit locations; exact doors, floor levels and access paths remain unverified. County source currency and horizontal accuracy are not published.',
 'southwest-ranch':'County assessor parcel map supports the subdivision. It is a cadastral map, not an access or door directory; no building alignment asserted.',
 'morgyn-ridge':'County assessor record supports subdivision identity. Owner information was not retained. No community directory geometry extracted.',
 'southern-vista':'HOA statement in a county public-comment document supports identity and address. No resident or author identity retained; no community map aligned.',
 'falls-rhodes-ranch':'HOA directory and listing subdivision names support discovery; current HOA-published directory and precise building addresses unresolved.',
 'sunset-cliffs':'Property-management and condo directory sources identify the community; a postal label is not a georeferenced unit directory.',
 'cimarron-hills':'Broker listing identifies the subdivision; listing map pins are not door coordinates and are not imported.',
 'apache-hills':'Listing directions identify Apache Hills and shared access. HOA directory and geographic building/unit layer unresolved.',
 'amber-hills':'Broker subdivision record identifies Amber Hills 2-B. Current HOA directory and geographic building/unit layer unresolved.',
 'coronado-palms':'Condo broker directory identifies this community. Current HOA directory and geographic building/unit layer unresolved.',
 'solaris-warm-springs':'Builder address identifies the townhome community. Individual homes, internal streets and construction phases still need an aligned public plan.'
};
const communities=rows.map(c=>{
 const a=audits.find(a=>a.communityID===c.id),refs=[source(c.id+'-identity',c.name+' — identity source',c.url,a?.retrievedAt)];
 if(c.id===areaException.communityID)refs.push(...Object.values(exceptionSourceIDs));
 for(const [i,p] of (a?.pages??[]).entries())refs.push(source(c.id+'-page-'+(i+1),c.name+' — inspected public page',p.url,a.retrievedAt));
 const countyDataset=countyDatasets.find(d=>d.raw.communityID===c.id);
 const registeredDataset=registeredDatasets.find(d=>d.raw.communityID===c.id);
 const estimatedDataset=estimatedDatasets.find(d=>d.raw.communityID===c.id);
 const gaps=[];if(notesByID[c.id]&&!countyDataset&&!registeredDataset&&!estimatedDataset)gaps.push(notesByID[c.id]);
 let n=0,unlabeled=0;const knownPoints=[],knownMapSourceIDs=[],deliveryAddresses=new Set();
 for(const r of maps.filter(m=>m.communityID===c.id)){
  const embedID=source(c.id+'-embed',c.name+' — public map embed',r.embedURL,r.retrievedAt);refs.push(embedID);
  for(const [i,m] of r.maps.entries()){
   if(!m.points.length)continue;
   const valid=m.points.every(p=>inDeliveryArea(p.coordinates,c.id,zips,areaException));
   if(!valid){rejections.push({communityID:c.id,assetName:m.assetName,apiURL:m.apiURL,reason:'Outside both permitted county ZIP polygons',count:m.points.length});continue;}
   const geoID=source(c.id+'-geo-'+i,c.name+' — published WGS84 unit-label layer',m.mapURL,r.retrievedAt);
   const apiID=source(c.id+'-map-api-'+i,c.name+' — public unit/floor map facts',m.apiURL,r.retrievedAt);
   const groupID=m.buildingGroupingURL?source(c.id+'-building-groups-'+i,c.name+' — published unit/building grouping',m.buildingGroupingURL,r.retrievedAt):null;
   refs.push(geoID,apiID,...(groupID?[groupID]:[]));knownMapSourceIDs.push(geoID);
   for(const p of m.points){
    const floor=m.floors.find(f=>String(f.id)===p.floorID);if(!floor)throw Error('Unknown source floor '+c.id+' '+p.floorID);
    if(!p.building)unlabeled++;
    features.push({type:'Feature',id:c.id+'-unit-'+p.sourceUnitID,geometry:{type:'Point',coordinates:p.coordinates},properties:{communityID:c.id,address:c.address,building:p.building??'',unit:p.unit,floor:String(floor.filter_short_label??floor.filter_label),kind:'unitPosition',verification:'sourceMapped',sourceIDs:[geoID,apiID,...(p.building&&groupID?[groupID]:[])],notes:'Published unit-label position in an official-site map. Approximate unit location, not an entrance or exact door. '+(p.building?'Building label joined through the published unit/building grouping.':'Building label not established by the inspected public map facts.')}});
    n++;knownPoints.push(p.coordinates);
   }
  }
 }
 if(registeredDataset){
  const {raw:directory,points}=registeredDataset;
  const planID=source(c.id+'-registered-plan',c.name+' — printed unit directory',directory.plan.url,directory.plan.retrievedAt);
  const referenceID=source(c.id+'-registered-reference',c.name+' — aerial calibration reference',directory.reference.url,directory.reference.retrievedAt);
  const membershipID=source(c.id+'-registered-membership',c.name+' — unit/building membership evidence',directory.membership.url,directory.retrievedAt);
  const boundaryID=directory.propertyBoundary?source(c.id+'-registered-property',c.name+' — independent property boundary',directory.propertyBoundary.url,directory.propertyBoundary.retrievedAt):null;
  const numberingID=directory.unitNumbering?source(c.id+'-registered-numbering',c.name+' — official building-qualified unit numbering',directory.unitNumbering.url,directory.unitNumbering.retrievedAt):null;
  const evidenceIDs=[...new Set([planID,referenceID,membershipID,...(boundaryID?[boundaryID]:[]),...(numberingID?[numberingID]:[])])];refs.push(...evidenceIDs);knownMapSourceIDs.push(planID);
  for(const p of points){
   if(!inDeliveryArea(p.coordinates,c.id,zips,areaException))throw Error('Registered unit outside delivery area '+p.unit);
   deliveryAddresses.add(p.address);
   features.push({type:'Feature',id:c.id+'-unit-'+p.sourceUnitID,geometry:{type:'Point',coordinates:p.coordinates},properties:{communityID:c.id,address:p.address,building:p.building,unit:p.unit,floor:'',kind:'unitPosition',verification:'sourceMapped',sourceIDs:evidenceIDs,positionDerivation:{type:'registeredDiagram',sourceStackID:p.sourceStackID,membershipBasis:p.membershipBasis,parcel:p.parcel??null,calibration:p.calibration},notes:'Printed directory unit-stack position aligned to a public aerial reference with independent control checks. Approximate unit location, not an entrance or exact door. Floors sharing a printed stack share one position; floor level, doorway and walking access remain unverified. Registration residuals do not establish absolute door accuracy.'}});
   n++;knownPoints.push(p.coordinates);
  }
  gaps.push(directory.precision,...(directory.gapNotes??[]),...(directory.unresolved?.notes??[]));
 }
 if(countyDataset){
  const {raw:county,points}=countyDataset;
  const geoID=source(c.id+'-county-unit-labels','Clark County — '+c.name+' geographic unit labels',county.annotationURL,county.retrievedAt);
  const directoryID=source(c.id+'-county-unit-buildings','Clark County — '+c.name+' unit/building directory',county.unitDirectoryURL,county.retrievedAt);
  const supplemental=new Map((county.supplementalSources??[]).map((s,i)=>[s.url,source(c.id+'-county-supplement-'+i,s.title,s.url,s.retrievedAt??county.retrievedAt)]));
  refs.push(geoID,directoryID);knownMapSourceIDs.push(geoID);
  refs.push(...supplemental.values());
  for(const p of points){
   if(!inDeliveryArea(p.coordinates,c.id,zips,areaException))throw Error('County unit outside delivery area '+p.unit);
   const address=p.address??c.address;deliveryAddresses.add(address);if(!p.building)unlabeled++;
   const extraIDs=(p.supplementalSourceURLs??[]).map(url=>{if(!supplemental.has(url))throw Error('Missing county supplemental source '+url);return supplemental.get(url);});
   features.push({type:'Feature',id:c.id+'-unit-'+p.sourceUnitID,geometry:{type:'Point',coordinates:p.coordinates},properties:{communityID:c.id,address,building:p.building,unit:p.unit,floor:'',kind:'unitPosition',verification:'sourceMapped',sourceIDs:[geoID,directoryID,...extraIDs],positionDerivation:{type:'countyLabelCenter',annotationObjectID:p.annotationObjectID,parcel:p.parcel,...(p.normalization?{normalization:p.normalization}:{})},notes:'Center of the published county unit-label extent, matched to retained property or unit/building evidence. Approximate unit location, not an entrance or exact door. Floor, doorway, stairs, gates and walking access remain unverified; source last-updated date and accuracy are unknown.'+(p.membershipUncertainty?' '+p.membershipUncertainty:'')}});
   n++;knownPoints.push(p.coordinates);
  }
  gaps.push('County map-label centers are matched to retained physical address and property/building evidence. Numerical accuracy and source last-updated date are not published; floors and exact doorways remain unverified.');
  gaps.push(...(county.coverageNotes??[]));
  if(c.id==='san-tropez')gaps.push('Unit 1043 is absent from the county address directory; its county map label is separately corroborated by the reviewed San Tropez site plan in building 6.');
 }
 if(estimatedDataset){
  const {raw:directory,points}=estimatedDataset;
  // Preserve the old strict evidence and explain its gaps in terms of that tier.
  for(let i=0;i<gaps.length;i++)if(registeredDataset?.raw.unresolved?.notes?.includes(gaps[i]))gaps[i]='Strict-registration tier: '+gaps[i];
  const publicSources=directory.sources.filter(s=>!s.localOnly);
  const evidenceIDs=publicSources.map((s,i)=>source(c.id+'-estimated-source-'+i,s.title,s.url,s.retrievedAt));
  refs.push(...evidenceIDs);knownMapSourceIDs.push(evidenceIDs[publicSources.findIndex(s=>s.id===directory.reference.sourceID)]);
  for(const p of points){
   if(!inDeliveryArea(p.coordinates,c.id,zips,areaException))throw Error('Estimated unit outside delivery area '+p.unit);
   const duplicates=f=>f.properties.communityID===c.id&&f.properties.unit===p.unit&&f.properties.building===p.building;
   if(features.some(duplicates)||estimatedFeatures.some(duplicates))throw Error('Estimate would duplicate an existing unit '+c.id+' '+p.unit);
   deliveryAddresses.add(p.address);
   estimatedFeatures.push({type:'Feature',id:c.id+'-unit-'+p.sourceUnitID,geometry:{type:'Point',coordinates:p.coordinates},properties:{communityID:c.id,address:p.address,building:p.building,unit:p.unit,floor:'',kind:'unitPosition',verification:'estimated',sourceIDs:evidenceIDs,positionDerivation:{type:'estimatedDiagram',sourceStackID:p.sourceStackID,uncertaintyMeters:p.uncertaintyMeters,identityAmbiguous:p.identityAmbiguous,sourceUnit:p.sourceUnit,identityHypothesis:p.identityHypothesis},identityUncertain:p.identityUncertain,notes:'May be inaccurate. Best-effort diagram bay matched to an observed building, not an entrance or exact door. '+p.notes+' Check and correct the actual door in person.'}});
   n++;knownPoints.push(p.coordinates);
  }
  gaps.push(points.length+' additional lower-confidence candidate positions are available with a May be inaccurate warning. These do not pass the strict-registration tier; the stated uncertainty is advisory, not a measured accuracy guarantee.');
  gaps.push(...directory.coverageNotes);
 }
 if(n){gaps.push('Unit positions are source mapped or estimated; doors, entrances, stair access and current gate conditions have not been field verified.');if(unlabeled)gaps.push(unlabeled+' unit positions have no supported building label.');if(c.id!=='pace')gaps.push('Internal drive/walk graph has not yet been extracted or confirmed.');}
 else {const propertyMap=(a?.pages??[]).flatMap(p=>p.links??[]).some(u=>/interactivepropertymap/i.test(u));gaps.push(propertyMap?'An official interactive property-map link was found. Image/pixel geometry still needs geographic alignment; no location precision is asserted.':'No usable geographic unit layer recovered in this audit. This is an unresolved research gap, not proof that no map exists.');}
 const failed=(a?.pages??[]).filter(p=>p.error||(!p.browserRendered&&p.status!==200));if(failed.length)gaps.push(failed.length+' inspected source request(s) returned an error or non-200 response; retry or browser inspection required.');
 const estimatedPositions=estimatedDataset?.points.length??0;
 const researchStatus=!n?'inventoryOnly':!estimatedPositions?'sourceMappedUnits':n===estimatedPositions?'estimatedUnits':'sourceMappedAndEstimatedUnits';
 const community={id:c.id,name:c.name,address:c.address,zip:c.zip,aliases:(c.aliases??'').split('|').filter(Boolean),sourceIDs:[...new Set(refs)],researchStatus,gapNotes:gaps};
 if(registeredDataset||estimatedDataset||(countyDataset&&countyDataset.raw.communityID!=='tuscano'))community.deliveryAddresses=[...deliveryAddresses].sort();
 if(knownPoints.length){community.longitude=(Math.min(...knownPoints.map(p=>p[0]))+Math.max(...knownPoints.map(p=>p[0])))/2;community.latitude=(Math.min(...knownPoints.map(p=>p[1]))+Math.max(...knownPoints.map(p=>p[1])))/2;community.referenceDerivation={type:'unitBoundsCenter',sourceIDs:[...new Set(knownMapSourceIDs)]};community.gapNotes.push(estimatedPositions?'Community reference coordinate is the center of candidate unit-position bounds, including estimates, not a destination entrance.':'Community reference coordinate is the center of published unit-label bounds, not a destination entrance.');}
 else if(c.id===areaException.communityID){community.longitude=areaException.communityReference.coordinates[0];community.latitude=areaException.communityReference.coordinates[1];community.referenceDerivation={type:'deliveryAreaExceptionReference',sourceIDs:[exceptionSourceIDs.reference]};community.gapNotes.push('Community reference is an official-site place marker within the verified property boundary, not a building, entrance or door.');}
 else {
  for(const p of a?.pages??[]){const lat=p.coordinateEvidence?.find(x=>x.includes('latitude'))?.match(/(-?\d+\.\d+)/)?.[1],lon=p.coordinateEvidence?.find(x=>x.includes('longitude'))?.match(/(-?\d+\.\d+)/)?.[1];if(lat&&lon&&zips.data.features.some(z=>inGeometry([+lon,+lat],z.geometry))){community.latitude=+lat;community.longitude=+lon;community.referenceDerivation={type:'websiteMetadata',pageURL:p.url,sourceIDs:[source(c.id+'-reference-metadata',c.name+' — reference metadata',p.url,a.retrievedAt)]};community.gapNotes.push('Community reference coordinate is published website metadata, not a building, entrance or exact door.');break;}}
 }
 return community;
}).sort((a,b)=>a.name.localeCompare(b.name));
features.push(...estimatedFeatures);
// Split OSM ways only at shared explicit node IDs, retaining curved intermediate vertices.
const occurrences=new Map();for(const way of roads.ways)for(const node of way.nodes)occurrences.set(node.id,(occurrences.get(node.id)??0)+1);
const pathFeatures=[];for(const way of roads.ways){const sid=source('osm-way-'+way.id,'OpenStreetMap contributors — Pace service way '+way.id,'https://www.openstreetmap.org/way/'+way.id,roads.retrievedAt);let start=0;for(let i=1;i<way.nodes.length;i++){if(i!==way.nodes.length-1&&occurrences.get(way.nodes[i].id)<2)continue;const seg=way.nodes.slice(start,i+1);pathFeatures.push({type:'Feature',id:'pace-osm-'+way.id+'-'+start,geometry:{type:'LineString',coordinates:seg.map(n=>n.coordinates)},properties:{communityID:'pace',fromNode:'osm-'+seg[0].id,toNode:'osm-'+seg.at(-1).id,mode:'drive',oneWay:way.tags.oneway==='yes',blocked:false,stairs:false,confirmed:false,sourceIDs:[sid],notes:'OpenStreetMap contributors, ODbL 1.0. Source-mapped service road; NOT field confirmed. Gate access, restrictions and closures unresolved. Junctions follow OSM node IDs; no proximity joins. Verify before routing.'}});start=i;}}
// Enrich provenance from the bounded follow-up; never turn parcel centers into location features.
const reconciled=await read('research/geography/county-reconciliation.json');
const countyPolygons=await read('research/geography/county-gilis20-polygons.json');
const pixelAudit=await read('research/audits/pixel-map-audit.json');
const countyParcels=await read('research/geography/county-parcel-identities.json');
const identityRaw={identities:rows,maps,zips,audits,countyParcels,countyPolygons,reconciliation:reconciled,cadastralObservations:await read('research/geography/cadastral-identity-observations.json'),areaException};
const joinErrors=validateCountyReconciliation(reconciled,identityRaw);if(joinErrors.length)throw Error(joinErrors.join('\n'));
const aliasReview=[];
generatedAt=[generatedAt,reconciled.generatedAt,...pixelAudit.map(p=>p.retrievedAt)].sort().at(-1);
for(const c of communities){
 const records=reconciled.records.filter(r=>r.communityID===c.id);
 if(c.id==='ashton-place')c.sourceIDs.push(source('ashton-place-name','Broker-owned Ashton Place community listing','https://ashtonlv.com/'));
 if(c.id==='la-paloma')c.sourceIDs.push(source('la-paloma-name','Listing directions identify La Paloma community','https://www.realtor.com/realestateandhomes-detail/7701-W-Robindale-Rd-Unit-259_Las-Vegas_NV_89113_M27937-40998'));
 for(const r of records)for(const [i,e] of r.evidence.entries())c.sourceIDs.push(source('county-'+r.candidateAPN+'-'+i,e.title,e.url,e.retrievedAt));
 if(records.length&&c.latitude===undefined){
  const poly=countyPolygons.data.features.find(f=>f.properties.APN===records[0].candidateAPN);const p=poly.geometry.type==='Polygon'?poly.geometry.coordinates.flat():poly.geometry.coordinates.flat(2);
  const ref=[(Math.min(...p.map(v=>v[0]))+Math.max(...p.map(v=>v[0])))/2,(Math.min(...p.map(v=>v[1]))+Math.max(...p.map(v=>v[1])))/2];
  if(zips.data.features.some(z=>inGeometry(ref,z.geometry))){c.longitude=ref[0];c.latitude=ref[1];const b=records[0].joinBasis;const urls=[countyPolygons.url,b.sourceURL,b.mapURL,b.apiURL,b.identitySourceURL].filter(Boolean);c.referenceDerivation={type:'countyParcelReference',candidateAPN:records[0].candidateAPN,sourceIDs:[...new Set(urls.map((url,i)=>source(c.id+'-county-reference-'+i,c.name+' — identified county reference',url,countyPolygons.retrievedAt)))]};c.sourceIDs.push(...c.referenceDerivation.sourceIDs);c.gapNotes.push('Community reference is the center of one matched historical county parcel polygon. It is for area discovery only, not a building, gate, entrance or delivery destination.');}
 }
 const pixel=pixelAudit.find(p=>p.communityID===c.id);
 if(pixel){c.gapNotes.push(pixel.pixelUnitCount+' unique source unit IDs were found across '+pixel.pages.length+' inspected pixel-map pages. These pixel positions have no established geographic transform; any imported county positions use separate geographic evidence.');for(const [i,p] of pixel.pages.entries())c.sourceIDs.push(source(c.id+'-pixel-'+i,c.name+' — inspected local-coordinate map region',p.url,pixel.retrievedAt));}
 const retainedAliases=[];c.aliasDerivations=[];const identity=rows.find(r=>r.id===c.id);
 for(const [i,alias] of c.aliases.entries()){
  const basis=findAliasBasis(identity,alias,identityRaw);
  aliasReview.push({communityID:c.id,alias,status:basis?'supported':'researchOnly',basis,notes:basis?'Name matches the retained published asset or county subdivision field.':'Historical/variant alias remains a research claim; no retained matching source field was established. Not exported as a verified alias.'});
  if(basis){const id=source(c.id+'-alias-'+i,c.name+' — alias identity evidence',basis.sourceURL);c.sourceIDs.push(id);retainedAliases.push(alias);c.aliasDerivations.push({alias,...basis,sourceIDs:[id]});}
 }
 const unresolvedAliasCount=c.aliases.length-retainedAliases.length;c.aliases=retainedAliases;
 if(unresolvedAliasCount)c.gapNotes.push(unresolvedAliasCount+' earlier alias claim(s) remain research-only because retained identity evidence is insufficient.');
 c.sourceIDs=[...new Set(c.sourceIDs)];
}
generatedAt=[generatedAt,countyUnits.retrievedAt].sort().at(-1);
const catalog={schemaVersion:1,packVersion,generatedAt,scopeZIPs,deliveryAreaExceptions:[{communityID:areaException.communityID,address:areaException.address,postalZIP:areaException.postalZIP,propertyAPN:areaException.physicalBoundary.historicalAPN,currentCountyAPN:areaException.currentCountyProperty.apn,identitySourceID:exceptionSourceIDs.identity,countySourceID:exceptionSourceIDs.county,boundarySourceID:exceptionSourceIDs.boundary,cadastralSourceID:exceptionSourceIDs.cadastral}],sources,communities,coverage:{inventoryComplete:false,notes:[
 'Discovery snapshot: official leasing/builder sources, Apartments.com and RentCafe ZIP directories, condo/HOA records and Clark County GILIS20. Renames deduplicated. This is not a certified exhaustive inventory.',
 'Published geographic labels, independently calibrated printed directories, and explicitly lower-confidence estimated bays are imported with their derivation evidence. Estimated pins say May be inaccurate and require owner confirmation. There are no field-verified doors or entrances in this pack. Missing units or communities remain research gaps.',
 'Pace roads are unconfirmed OSM source geometry. Other community drive/walk graphs, gates, entrances, stairs and exact doors remain unresolved.',
 'Clark County ZIP boundaries crosscheck the original scope. Spanish Wells at 5355 S Rainbow Blvd is one bounded 89118 exception within the owner-defined delivery area; its points must remain inside its retained property polygon. Alcove straddles the two original ZIPs.',
 'All 73 saved GILIS20 candidate records were reconciled: 48 existing/alias matches, 4 records for 3 previously added communities, Spanish Wells as one verified delivery-area exception, 18 non-residential exclusions, 1 out-of-scope site and Revel Vegas as an unresolved ZIP conflict. This exhausts the saved leads, not the 2026 community census.',
 'Public source availability and a recent retrieval date do not establish current accuracy or redistribution rights. No copyrighted map artwork is bundled. OSM geometry requires OpenStreetMap contributors attribution and ODbL compliance.'
]}};
await mkdir(new URL('data/',root),{recursive:true});const write=async(p,x)=>writeFile(new URL(p,root),JSON.stringify(x,null,2)+'\n');
await write('research/identity-alias-review.json',aliasReview);await write('data/catalog.json',catalog);await write('data/locations.geojson',{type:'FeatureCollection',schemaVersion:1,packVersion,features});await write('data/paths.geojson',{type:'FeatureCollection',schemaVersion:1,packVersion,features:pathFeatures});await write('research/audits/rejected-map-assets.json',rejections);
const mappedCount=new Set(features.map(f=>f.properties.communityID)).size;
const estimatedCount=features.filter(f=>f.properties.verification==='estimated').length;
const lines=['# Coverage audit — '+generatedAt.slice(0,10),'',`${mappedCount} of ${communities.length} catalog communities have mapped units; ${features.length} candidate positions (${estimatedCount} lower-confidence estimates); ${pathFeatures.length} unconfirmed Pace road segments. No exact doors, entrances, field verifications, or completeness claim.`,
 '', 'Each directory is bundled independently of a delivery manifest. Importing a new manifest matches its address and unit against the available directory; it cannot supply missing coordinates.',
 '', 'This report describes an acquisition audit, not an exhaustive visual review of every widget. Linked image maps remain actionable gaps. A missing extraction is not a missing map.',
 '',...catalog.coverage.notes.map(n=>'- '+n),'','## Coverage by community','',
 '| Community | ZIP | Candidate positions | Directory status |','| --- | --- | ---: | --- |'];
for(const c of communities){const n=features.filter(f=>f.properties.communityID===c.id).length;const county=countyDatasets.find(d=>d.raw.communityID===c.id)?.raw;
 const registered=registeredDatasets.find(d=>d.raw.communityID===c.id)?.raw;
 const estimatedDataset=estimatedDatasets.find(d=>d.raw.communityID===c.id),estimated=estimatedDataset?.raw;
 const partial=estimated?estimated.unresolved.length>0:county?.coverageStatus==='partial'||registered?.unresolved?.units?.length>0||registered?.unresolved?.unmappedPrintedLabelCount>0;
 const identityUncertain=estimatedDataset?.points.some(p=>p.identityUncertain);
 lines.push(`| ${c.name} | ${c.zip} | ${n} | ${n?(estimated?(identityUncertain?'Includes estimates; unit/building identity ambiguous or hypothesized; check/correct on arrival':partial?'Includes estimates; identity gaps below':'Includes estimates; check/correct on arrival'):(partial?'Partial; unresolved units below':'Source-mapped units; check door on arrival')):'Unit geography unresolved'} |`);
}
lines.push('','## Community evidence and remaining work','');
for(const c of communities){
 const a=audits.find(a=>a.communityID===c.id),n=features.filter(f=>f.properties.communityID===c.id).length;
 const county=countyDatasets.find(d=>d.raw.communityID===c.id)?.raw;
 const registered=registeredDatasets.find(d=>d.raw.communityID===c.id)?.raw;
 lines.push('### '+c.name+' — '+c.zip,'',c.address+`. ${n} candidate unit positions. Status: ${c.researchStatus}.`,'',
  ...(a?.pages??[]).map(p=>`- [Inspected source](${p.url}) — ${p.error??(p.browserRendered?'Rendered in browser':'HTTP '+p.status)}; retrieved ${p.observedAt??a.retrievedAt}.`),
  ...maps.filter(m=>m.communityID===c.id).flatMap(m=>[`- [Public embed](${m.embedURL})`,...m.maps.map(g=>`- [Geographic source](${g.mapURL??g.apiURL}) — asset ${g.assetName}; ${g.points.length} source labels; source geometry created ${g.geometryCreatedAt??'unknown'}. ${rejections.some(r=>r.apiURL===g.apiURL)?'REJECTED: unrelated out-of-scope map.':''}`)]),
  ...(county?[`- [County unit labels](${county.annotationURL}) and [physical unit/building directory](${county.unitDirectoryURL}); retrieved ${county.retrievedAt}.`]:[]),
  ...(registered?[`- [Printed unit directory](${registered.plan.url}) aligned to a [public aerial reference](${registered.reference.url}); ${registered.expectedPositions} accepted unit labels. Calibration and independent containment evidence retained in research/geography/registered-unit-maps.`]:[]),
  '',...c.gapNotes.map(n=>'- '+n),'');
}
await writeFile(new URL('research/COVERAGE.md',root),lines.map(line=>line.trimEnd()).join('\n'));
console.log(JSON.stringify({communities:communities.length,sources:sources.length,locations:features.length,mappedCommunities:new Set(features.map(f=>f.properties.communityID)).size,buildingLabels:features.filter(f=>f.properties.building).length,paths:pathFeatures.length,rejectedAssets:rejections.length},null,2));
