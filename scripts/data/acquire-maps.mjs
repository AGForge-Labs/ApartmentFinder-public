// Public embedded map facts only. Never convert marketing imagery to exact doors.
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const root=new URL('../../',import.meta.url);
const audit=JSON.parse(await readFile(new URL('research/audits/site-audit.json',root)));
await mkdir(new URL('research/maps/',root),{recursive:true});
const results=[];
async function get(url){const r=await fetch(url,{signal:AbortSignal.timeout(20000)});if(!r.ok)throw Error(`HTTP ${r.status}`);return await r.text();}
for(const c of audit){
 const ids=[...new Set(c.pages.flatMap(p=>p.links??[]).map(u=>u.match(/sightmap\.com\/embed\/([a-z0-9]{11})/)?.[1]).filter(Boolean))];
 for(const id of ids){
  const record={communityID:c.communityID,embedURL:`https://sightmap.com/embed/${id}`,retrievedAt:new Date().toISOString(),maps:[]};
  try{
   const html=await get(record.embedURL);
   const config=JSON.parse(html.match(/window\.__APP_CONFIG__ = (.+)\s*\n/)[1]);
   for(const map of config.sightmaps){
    const apiText=await get(map.href);const d=JSON.parse(apiText).data;
    const entry={apiURL:map.href,assetName:d.asset.name,mapURL:d.unit_map?.geojson_url,sha256:createHash('sha256').update(apiText).digest('hex'),floors:d.floors,units:[],points:[]};
    if(entry.mapURL){
     const geoText=await get(entry.mapURL);const g=JSON.parse(geoText);
     entry.geometrySHA256=createHash('sha256').update(geoText).digest('hex');entry.geometryCreatedAt=g.properties?.created_at;entry.bounds=g.properties?.bounds;
     entry.points=g.features.filter(f=>f.geometry?.type==='Point'&&f.properties?.type==='UnitLabel').map(f=>({sourceUnitID:String(f.properties.unit_id),unit:String(f.properties.unit_label),floorID:String(f.properties.floor_id),coordinates:f.geometry.coordinates}));
     // Published umap joins map unit IDs to building-group IDs; labels only when the API explicitly names that group.
     if(d.unit_map.url){
      const um=JSON.parse(await get(d.unit_map.url));const groups=new Map();
      function walk(e,building){building=e.tags?.building??building;if(e.type==='Unit'&&e.id)groups.set(String(e.id),String(building??''));for(const child of e.elements??[])walk(child,building)}
      for(const e of um.elements??[])walk(e,'');
      const buildingLabels=new Map();for(const u of d.units??[]){if(u.building&&groups.get(String(u.id)))buildingLabels.set(groups.get(String(u.id)),String(u.building))}
      for(const p of entry.points)p.building=buildingLabels.get(groups.get(p.sourceUnitID))??'';
      entry.buildingGroupingURL=d.unit_map.url;
     }
     entry.units=(d.units??[]).map(u=>({id:String(u.id),unit:String(u.unit_number),floorID:String(u.floor_id),building:String(u.building??'')}));
    } else entry.gap='No public geographic unit layer linked; floorplate geometry is not latitude/longitude.';
    record.maps.push(entry);
   }
  }catch(e){record.error=e.message;}
  results.push(record);console.log(c.communityID,record.maps.reduce((n,m)=>n+m.points.length,0),record.error??'');
 }
}
await writeFile(new URL('research/maps/public-map-facts.json',root),JSON.stringify(results,null,2)+'\n');
