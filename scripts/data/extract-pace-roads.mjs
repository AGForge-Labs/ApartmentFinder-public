// Convert only explicitly inspected Pace service ways, preserving OSM junction IDs.
// OSM contributors, ODbL 1.0. This file never joins nearby but distinct nodes.
import {readFile,writeFile,unlink} from 'node:fs/promises';
const x=await readFile('research/geography/pace-osm.xml','utf8');
const attrs=s=>Object.fromEntries([...s.matchAll(/([\w:]+)="([^"]*)"/g)].map(m=>[m[1],m[2]]));
const nodes=new Map([...x.matchAll(/<node\b([^>]+)>?/g)].map(m=>{const a=attrs(m[1]);return[a.id,[+a.lon,+a.lat]]}));
const allowed=new Set(['787600201','787600202','805986135','835648461','874865768','874865821','1096500482','1264320546']);
const ways=[];
for(const m of x.matchAll(/<way\b([^>]+)>([\s\S]*?)<\/way>/g)){
 const a=attrs(m[1]);if(!allowed.has(a.id))continue;
 const tags=Object.fromEntries([...m[2].matchAll(/<tag k="([^"]+)" v="([^"]+)"/g)].map(m=>[m[1],m[2]]));
 const ids=[...m[2].matchAll(/<nd ref="(\d+)"/g)].map(m=>m[1]);
 if(tags.highway!=='service')throw Error('Reviewed way changed classification '+a.id);
 ways.push({id:a.id,version:a.version,timestamp:a.timestamp,tags,nodes:ids.map(id=>({id,coordinates:nodes.get(id)}))});
}
await writeFile('research/geography/pace-road-facts.json',JSON.stringify({url:'https://www.openstreetmap.org/api/0.6/map?bbox=-115.2975,36.0849,-115.2951,36.0872',retrievedAt:new Date().toISOString(),license:'OpenStreetMap contributors, Open Database License 1.0',alignment:'Pace public SightMap WGS84 extent; north of Russell Road. OSM node topology retained. No on-site accessibility verification.',ways},null,2)+'\n');
console.log('Reviewed service ways',ways.length);

// Discard unrelated OSM objects and contributor metadata after factual extraction.
await unlink('research/geography/pace-osm.xml');
