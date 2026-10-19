import {deriveRegisteredUnitPositions} from './registered-unit-maps.mjs';
import {deriveEstimatedUnitPositions} from './estimated-unit-maps.mjs';
import {deriveTuscanoUnitPositions,deriveCountyUnitPositions} from './county-unit-labels.mjs';
import {areaReferenceSupported} from './area-reference.mjs';
// Independently recompute catalog reference/alias claims from retained source observations.
import {boundsCenter,geometryPoints} from './geometry.mjs';
import {findAliasBasis,websiteCoordinate,deriveJoinBasis,validateCountyReconciliation} from './identity-evidence.mjs';
import {inDeliveryArea} from './delivery-area-exceptions.mjs';
export function validateCommunityMetadata(catalog,raw){
 const errors=validateCountyReconciliation(raw.reconciliation,raw),sources=new Map(catalog.sources.map(s=>[s.id,s]));
 const check=(ok,m)=>{if(!ok)errors.push(m);};
 const sourceURLs=(ids,c,label)=>{check(Array.isArray(ids)&&ids.length>0&&ids.every(id=>sources.has(id)&&c.sourceIDs.includes(id)),label+' provenance '+c.id);return (ids??[]).map(id=>sources.get(id)?.url).filter(Boolean).sort();};
 const urlsEqual=(a,b)=>JSON.stringify([...new Set(a)].sort())===JSON.stringify([...new Set(b)].sort());
 const coordinatesEqual=(a,b)=>a?.length===2&&b?.length===2&&a.every((v,i)=>Number.isFinite(v)&&Number.isFinite(b[i])&&Math.abs(v-b[i])<=1e-12);
 const inScope=(p,id)=>inDeliveryArea(p,id,raw.zips,raw.areaException);
 const countyPoints=new Map();
 for(const county of raw.countyCoverage??[]){try{countyPoints.set(county.communityID,deriveCountyUnitPositions(county));}catch(error){check(false,'invalid county reference evidence '+county.communityID);}}
 const registeredPoints=new Map();
 for(const directory of raw.registeredMaps??[]){try{registeredPoints.set(directory.communityID,deriveRegisteredUnitPositions(directory));}catch(error){check(false,'invalid registered reference evidence '+directory.communityID);}}
 const estimatedPoints=new Map();
 for(const directory of raw.estimatedMaps??[]){try{estimatedPoints.set(directory.communityID,deriveEstimatedUnitPositions(directory));}catch(error){check(false,'invalid estimated reference evidence '+directory.communityID);}}
 for(const c of catalog.communities){
  const identity=raw.identities.find(r=>r.id===c.id);if(!identity)continue;
  const physicalAddresses=[...new Set([...(countyPoints.get(c.id)??[]),...(registeredPoints.get(c.id)??[]),...(estimatedPoints.get(c.id)??[])].map(p=>p.address))].sort();
  check(JSON.stringify(c.deliveryAddresses??[])===JSON.stringify(physicalAddresses),'unsupported delivery address aliases '+c.id);
  const countyAddresses=(raw.audits.find(a=>a.communityID===c.id)?.pages??[]).filter(p=>p.observation?.parcel&&p.observation?.address).map(p=>p.observation.address);
  if(c.address.endsWith('(area reference)')&&countyAddresses.length)check(areaReferenceSupported(c.address,countyAddresses),'unsupported area-reference street '+c.id);
  const aliasClaims=(identity.aliases??'').split('|').filter(Boolean),expectedAliases=aliasClaims.filter(a=>findAliasBasis(identity,a,raw));
  check(JSON.stringify(c.aliases)===JSON.stringify(expectedAliases),'unsupported alias list '+c.id);
  check(Array.isArray(c.aliasDerivations)&&c.aliasDerivations.length===c.aliases.length,'alias derivation count '+c.id);
  for(const alias of c.aliases){const expected=findAliasBasis(identity,alias,raw),d=c.aliasDerivations?.find(d=>d.alias===alias);check(!!expected&&!!d,'unsupported alias '+c.id+' '+alias);if(expected&&d){check(Object.entries(expected).every(([k,v])=>d[k]===v),'alias derivation mismatch '+c.id);check(urlsEqual(sourceURLs(d.sourceIDs,c,'alias'),[expected.sourceURL]),'alias source mismatch '+c.id);}}
  const d=c.referenceDerivation;
  if(c.latitude===undefined&&c.longitude===undefined){check(!d,'community reference derivation without coordinates '+c.id);continue;}
  check(!!d,'community reference derivation missing '+c.id);if(!d)continue;
  const urls=sourceURLs(d.sourceIDs,c,'community reference');let expected=null,expectedURLs=[];
  if(d.type==='unitBoundsCenter'){
   const maps=raw.maps.filter(r=>r.communityID===c.id).flatMap(r=>r.maps).filter(m=>m.points.length&&m.points.every(p=>inScope(p.coordinates,c.id)));
   const points=maps.flatMap(m=>m.points.map(p=>p.coordinates));expectedURLs=maps.map(m=>m.mapURL);
   if(c.id===raw.countyUnits?.communityID){try{points.push(...deriveTuscanoUnitPositions(raw.countyUnits).map(p=>p.coordinates));expectedURLs.push(raw.countyUnits.annotationURL);}catch(error){check(false,'invalid county reference evidence '+c.id);}}
   const county=(raw.countyCoverage??[]).find(r=>r.communityID===c.id);
   if(county){points.push(...(countyPoints.get(c.id)??[]).map(p=>p.coordinates));expectedURLs.push(county.annotationURL);}
   const registered=(raw.registeredMaps??[]).find(r=>r.communityID===c.id);
   if(registered){points.push(...(registeredPoints.get(c.id)??[]).map(p=>p.coordinates));expectedURLs.push(registered.plan.url);}
   const estimated=(raw.estimatedMaps??[]).find(r=>r.communityID===c.id);
   if(estimated){points.push(...(estimatedPoints.get(c.id)??[]).map(p=>p.coordinates));expectedURLs.push(estimated.sources.find(s=>s.id===estimated.reference.sourceID).url);}
   if(points.length)expected=boundsCenter(points);
  }else if(d.type==='deliveryAreaExceptionReference'){
   if(c.id===raw.areaException?.communityID){expected=raw.areaException.communityReference.coordinates;expectedURLs=[raw.areaException.communityReference.sourceURL];}
  }else if(d.type==='websiteMetadata'){
   const page=raw.audits.find(a=>a.communityID===c.id)?.pages.find(p=>p.url===d.pageURL);if(page){expected=websiteCoordinate(page);expectedURLs=[page.url];}
  }else if(d.type==='countyParcelReference'){
   const row=raw.reconciliation.records.find(r=>r.candidateAPN===d.candidateAPN&&r.communityID===c.id),shape=raw.countyPolygons.data.features.find(f=>f.properties.APN===d.candidateAPN);
   const basis=row&&deriveJoinBasis(row.candidateAPN,identity,raw);
   if(row&&shape&&basis){expected=boundsCenter(geometryPoints(shape.geometry));expectedURLs=[raw.countyPolygons.url,basis.sourceURL,basis.mapURL,basis.apiURL,basis.identitySourceURL].filter(Boolean);}
  }else check(false,'community reference unknown derivation '+c.id);
  check(coordinatesEqual([c.longitude,c.latitude],expected),'community reference differs from raw source '+c.id);
  check(expectedURLs.length>0&&urlsEqual(urls,expectedURLs),'community reference source mismatch '+c.id);
 }
 return errors;
}
