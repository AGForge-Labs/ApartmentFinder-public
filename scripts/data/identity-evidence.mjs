// Evidence-based joins. No APN-to-community expected-target table is used here.
import {inGeometry,geometriesIntersect} from './geometry.mjs';
export function normalizeName(s){return s.toUpperCase().replace(/^THE\s+/,'').replace(/\bNO\s+\d+(?:\s+\d+(?:ST|ND|RD|TH))?.*$/,'').replace(/#\s*\d+/g,'').replace(/\bUNIT\s*\d+.*$/,'').replace(/\b(?:AMD|AMENDED)\b/g,'').replace(/CONDOMINIUMS?|CONDOS?/g,'CONDOMINIUM').replace(/[^A-Z0-9]/g,'');}
export function legalStem(s){return normalizeName(s).replace(/CONDOMINIUM|APARTMENTS?|TOWNHOMES?|TOWNHOUSES?/g,'');}
function addressParts(s){const m=s.toUpperCase().trim().match(/^(\d+)(?:-(\d+))?\s+(?:(N|S|E|W)\s+)?(.+?)\s+(RD|ROAD|DR|DRIVE|ST|STREET|LN|LANE|AVE|AVENUE|WAY|CT|COURT|BLVD|BOULEVARD)(?:\s+.*)?$/);if(!m)return null;return{numbers:[m[1],m[2]].filter(Boolean),direction:m[3]??'',street:m[4].replace(/[^A-Z0-9]/g,''),type:({ROAD:'RD',DRIVE:'DR',STREET:'ST',LANE:'LN',AVENUE:'AVE',COURT:'CT',BOULEVARD:'BLVD'})[m[5]]??m[5]};}
export function addressMatches(a,b){const x=addressParts(a),y=addressParts(b);return !!(x&&y&&x.numbers.some(n=>y.numbers.includes(n))&&x.street===y.street&&x.type===y.type&&(!x.direction||!y.direction||x.direction===y.direction));}
export function websiteCoordinate(page){const parse=key=>page.coordinateEvidence?.find(x=>x.includes(key))?.match(/(-?\d+\.\d+)/)?.[1];const lat=parse('latitude'),lon=parse('longitude');return lat&&lon?[+lon,+lat]:null;}
export function deriveJoinBasis(candidateAPN,community,raw){
 const parcel=raw.countyParcels.find(r=>r.candidateAPN===candidateAPN),shape=raw.countyPolygons.data.features.find(f=>f.properties.APN===candidateAPN);if(!parcel||!shape||!community)return null;
 const ownSource=community.url;
 const exception=raw.areaException;
 if(exception?.physicalBoundary.historicalAPN===candidateAPN&&exception.communityID===community.id&&
    exception.name===community.name&&exception.address===community.address&&exception.postalZIP===community.zip&&
    exception.officialIdentity.url===ownSource&&addressMatches(exception.officialIdentity.publishedAddress.replace(/\bSouth\b/gi,'S').replace(/\bBoulevard\b/gi,'Blvd'),community.address)&&
    JSON.stringify(exception.physicalBoundary.geometry)===JSON.stringify(shape.geometry)){
  return{type:'verifiedDeliveryAreaProperty',parcel:exception.currentCountyProperty.apn,
   sourceURL:exception.currentCountyProperty.queryURLs.find(u=>u.includes('strno%3D5355')),
   identitySourceURL:ownSource,boundarySourceURL:exception.physicalBoundary.cadastralMapURL};
 }
 for(const p of parcel.lookups){if(p.address&&addressMatches(p.address,community.address))return{type:'normalizedAddress',parcel:p.parcel,sourceURL:p.url,identitySourceURL:ownSource};}
 for(const r of raw.maps.filter(m=>m.communityID===community.id))for(const m of r.maps){const count=m.points.filter(p=>inGeometry(p.coordinates,shape.geometry)).length;if(count>=3)return{type:'publishedMapOverlap',mapURL:m.mapURL,apiURL:m.apiURL,identitySourceURL:ownSource,overlappingUnitLabels:count};}
 for(const p of parcel.lookups){if(p.description&&legalStem(p.description)===legalStem(community.name))return{type:'legalSubdivisionIdentity',parcel:p.parcel,sourceURL:p.url,identitySourceURL:ownSource};}
 for(const o of raw.cadastralObservations??[]){if(o.map===candidateAPN.slice(0,6)&&o.block===candidateAPN.slice(5,8)&&legalStem(o.subdivisionLabel)===legalStem(community.name))return{type:'cadastralBlockLabel',map:o.map,block:o.block,sourceURL:o.sourceURL,identitySourceURL:ownSource};}
 for(const page of raw.audits.find(a=>a.communityID===community.id)?.pages??[]){const p=websiteCoordinate(page);if(p&&inGeometry(p,shape.geometry))return{type:'websiteReferenceInsideParcel',sourceURL:page.url,identitySourceURL:ownSource};}
 return null;
}
export function validateCountyReconciliation(ledger,raw){const errors=[];
 for(const r of ledger.records){const shape=raw.countyPolygons.data.features.find(f=>f.properties.APN===r.candidateAPN);if(!shape){errors.push('county missing polygon '+r.candidateAPN);continue;}
  const expectedZIPs=raw.zips.data.features.filter(z=>geometriesIntersect(shape.geometry,z.geometry)).map(z=>String(z.properties.ZIP)).sort();
  if(JSON.stringify([...(r.scopeCountyZIPs??[])].sort())!==JSON.stringify(expectedZIPs))errors.push('county polygon ZIP intersection mismatch '+r.candidateAPN);
  if(r.category==='outOfScope'&&expectedZIPs.length)errors.push('county out-of-scope polygon intersects requested ZIP '+r.candidateAPN);
  if(r.communityID){const c=raw.identities.find(c=>c.id===r.communityID),basis=deriveJoinBasis(r.candidateAPN,c,raw);if(!basis||JSON.stringify(basis)!==JSON.stringify(r.joinBasis))errors.push('unsupported county join '+r.candidateAPN);
   if(basis){for(const url of [basis.sourceURL,basis.mapURL,basis.apiURL,basis.identitySourceURL,basis.boundarySourceURL].filter(Boolean))if(!r.evidence.some(e=>e.url===url))errors.push('county join source absent '+r.candidateAPN);}
  }else if(r.joinBasis)errors.push('county excluded candidate has join basis '+r.candidateAPN);
 }
 return errors;
}
export function findAliasBasis(community,alias,raw){const target=normalizeName(alias);
 for(const r of raw.maps.filter(m=>m.communityID===community.id))for(const m of r.maps)if(normalizeName(m.assetName)===target)return{type:'publishedAssetName',sourceURL:m.apiURL};
 for(const r of raw.reconciliation.records.filter(r=>r.communityID===community.id)){
  if(!deriveJoinBasis(r.candidateAPN,community,raw))continue;
  for(const p of raw.countyParcels.find(p=>p.candidateAPN===r.candidateAPN)?.lookups??[])if(p.description&&normalizeName(p.description)===target)return{type:'countySubdivisionName',candidateAPN:r.candidateAPN,parcel:p.parcel,sourceURL:p.url};
 }
 return null;
}
