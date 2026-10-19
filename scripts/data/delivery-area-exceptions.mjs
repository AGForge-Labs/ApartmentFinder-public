import {readFile} from 'node:fs/promises';
import {addressMatches} from './identity-evidence.mjs';
import {coordinateValid,inGeometry} from './geometry.mjs';

export async function loadDeliveryAreaException(){
 return JSON.parse(await readFile(new URL('../../research/geography/delivery-area-exceptions/spanish-wells.json',import.meta.url),'utf8'));
}

export function inDeliveryArea(point,communityID,zips,exception){
 if(!coordinateValid(point))return false;
 if(communityID===exception?.communityID)return inGeometry(point,exception.physicalBoundary.geometry);
 return zips.data.features.some(z=>['89113','89148'].includes(String(z.properties.ZIP))&&inGeometry(point,z.geometry));
}

export function validateDeliveryAreaException(exception,raw){
 const errors=[],check=(ok,message)=>{if(!ok)errors.push(message)};
 const shape=raw.countyPolygons.data.features.find(f=>f.properties.APN===exception.physicalBoundary.historicalAPN);
 const identity=raw.identities.find(i=>i.id===exception.communityID);
 const a=exception.currentCountyProperty.attributes;
 const polygon=exception.physicalBoundary.geometry;
 check(exception.schemaVersion===1&&exception.communityID==='spanish-wells'&&exception.name==='Spanish Wells Apartments'&&exception.address==='5355 S Rainbow Blvd'&&exception.postalZIP==='89118','unsupported delivery-area exception identity');
 check(identity?.name===exception.name&&identity?.address===exception.address&&identity?.zip===exception.postalZIP,'delivery-area exception inventory mismatch');
 const officialAddress=exception.officialIdentity.publishedAddress.replace(/\bSouth\b/gi,'S').replace(/\bBoulevard\b/gi,'Blvd');
 check(exception.officialIdentity.url===identity?.url&&addressMatches(officialAddress,exception.address),'delivery-area exception official address mismatch');
 check(a?.APN==='16327710181'&&a?.Parcel===a.APN&&a?.strno===5355&&a?.strdir?.trim()==='S'&&a?.strname?.trim()==='RAINBOW'&&a?.strtype?.trim()==='BLVD'&&a?.subname?.trim()==='SPANISH WELLS'&&a?.LEGAL_DESCR3?.trim()==='ALL UNITS BUILDINGS 1-23','delivery-area exception county identity mismatch');
 check(exception.currentCountyProperty.queryURLs?.length===2&&exception.currentCountyProperty.queryURLs.some(u=>u.includes('strno%3D5355'))&&exception.currentCountyProperty.queryURLs.some(u=>u.includes('16327710')),'delivery-area exception county query missing');
 check(shape&&exception.physicalBoundary.sourceURL===raw.countyPolygons.url&&JSON.stringify(polygon)===JSON.stringify(shape.geometry),'delivery-area exception property polygon mismatch');
 check(exception.physicalBoundary.cadastralMapURL==='https://maps.clarkcountynv.gov/assessor/parcelmap/mapfiles/map163277.pdf'&&exception.physicalBoundary.cadastralFinding.includes('south of Hacienda Avenue and west of Rainbow Boulevard'),'delivery-area exception physical boundary proof missing');
 const footprints=exception.currentCountyProperty.buildingFootprints?.rings;
 check(Array.isArray(footprints)&&footprints.length===23&&footprints.every(r=>r.length>=4&&r.every(p=>inGeometry(p,polygon))),'delivery-area exception building footprints outside property');
 check(inGeometry(exception.communityReference.coordinates,polygon),'delivery-area exception reference outside property');
 check(exception.communityReference.sourceURL?.startsWith('https://maps.app.goo.gl/')&&exception.communityReference.meaning.includes('not an entrance'),'delivery-area exception reference source missing');
 return errors;
}
