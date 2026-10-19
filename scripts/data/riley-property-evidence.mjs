import {createHash} from 'node:crypto';
import {coordinateValid,inGeometry} from './geometry.mjs';

function require(ok,message){if(!ok)throw Error(message);}
function validParcels(parcels){
 require(parcels&&JSON.stringify(Object.keys(parcels).sort())==='["6350","6355"]','Exact street parcel inventory required');
 for(const rows of Object.values(parcels)){
  require(Array.isArray(rows)&&rows.length>0,'Empty street parcel inventory');
  for(const row of rows){
   require(Array.isArray(row.units)&&row.units.length>0&&row.units.every(u=>typeof u==='string'&&/^[0-9]+$/.test(u)),'Invalid county unit inventory');
   const rings=row.geometry?.rings;require(Array.isArray(rings)&&rings.length>0,'Missing county parcel rings');
   for(const ring of rings){
    require(Array.isArray(ring)&&ring.length>=4&&ring.every(coordinateValid)&&JSON.stringify(ring[0])===JSON.stringify(ring.at(-1)),'Malformed county parcel ring');
    const origin=ring[0];let area=0;
    for(let i=0;i<ring.length-1;i++){const a=ring[i],b=ring[i+1];area+=(a[0]-origin[0])*(b[1]-origin[1])-(b[0]-origin[0])*(a[1]-origin[1]);}
    require(Math.abs(area)>1e-14,'Degenerate county parcel ring');
   }
  }
 }
}
const contains=(point,row)=>inGeometry(point,{type:'Polygon',coordinates:row.geometry.rings});
export function classifyRileyPosition(point,parcels){
 require(coordinateValid(point),'Invalid Riley source coordinate');validParcels(parcels);
 const found=Object.entries(parcels).filter(([,rows])=>rows.some(row=>contains(point,row))).map(([street])=>street);
 require(found.length===1,'Outside or overlapping independent street parcels');return found[0];
}
export function validateRileyEvidence(record,maps){
 // Pin the JavaScript canonical form of the retained snapshot, then independently
 // recompute source membership and containment. A new snapshot needs review.
 const raw=JSON.stringify(record,null,2)+'\n';
 require(createHash('sha256').update(raw).digest('hex')==='6eb575e3082cfebd80425f4a4702dcc5446754164782547ade4a78f42aeb76e6','Retained Riley evidence changed');
 require(record.schemaVersion===1&&record.sourcePackVersion==='2026.10.14.1','Unsupported Riley source binding');
 validParcels(record.streetParcels);
 const actual=new Map();
 for(const directory of maps.filter(m=>m.communityID==='alcove'))for(const layer of directory.maps)for(const point of layer.points){
  const id='alcove-unit-'+point.sourceUnitID;require(!actual.has(id),'Duplicated original map source');
  const floor=layer.floors.find(f=>String(f.id)===point.floorID);require(!!floor,'Missing published source floor');
  actual.set(id,{...point,floor:String(floor.filter_short_label??floor.filter_label)});
 }
 require(actual.size===456&&record.positions.length===456&&new Set(record.positions.map(p=>p.sourceID)).size===456,'Source unit lost or duplicated');
 const counts={'6350':0,'6355':0,uncertain:0};
 for(const p of record.positions){
  const source=actual.get(p.sourceID);
  require(source&&source.unit===p.unit&&source.building===p.building&&source.floor===p.floor&&JSON.stringify(source.coordinates)===JSON.stringify(p.coordinates),'Changed source coordinate or label');
  const street=classifyRileyPosition(p.coordinates,record.streetParcels);
  require(p.address===street+' S Riley St','Wrong independent delivery street');counts[street]++;
  const exact=record.streetParcels[street].some(row=>row.units.includes(p.unit)&&contains(p.coordinates,row));
  require(p.countyUnitLabelMatches===exact,'Unsupported county unit identity');if(!exact)counts.uncertain++;
 }
 require(counts['6350']===154&&counts['6355']===302&&counts.uncertain===2,'Changed bounded Riley split');return counts;
}
