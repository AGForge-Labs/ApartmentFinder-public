import {mkdir,writeFile} from 'node:fs/promises';
const root=new URL('../../research/geography/',import.meta.url);await mkdir(root,{recursive:true});
const requests={
 'county-zips': 'https://maps.clarkcountynv.gov/arcgis/rest/services/OpenData/zip_p/MapServer/0/query?f=geojson&where=ZIP%20IN%20(89113%2C89148)&outFields=ZIP&outSR=4326&returnGeometry=true',
 'county-gilis20': 'https://maps.clarkcountynv.gov/arcgis/rest/services/CompPlanning/GILIS/MapServer/0/query?f=json&where=ZIP%20IN%20(89113%2C89148)%20AND%20AOCAP%20%3E%3D%208&outFields=APN,COMMUNITY,ZIP,AOCAP,RES_TYPE&returnGeometry=false&resultRecordCount=1000',
 'pace-osm': 'https://www.openstreetmap.org/api/0.6/map?bbox=-115.2975,36.0849,-115.2951,36.0872'
};
for(const [name,url] of Object.entries(requests)){
 try {
  const response=await fetch(url,{signal:AbortSignal.timeout(45000),headers:{'User-Agent':'ApartmentFinderPrivateMapResearch/1.0'}});
  if(!response.ok)throw Error('HTTP '+response.status);
  if(name==='pace-osm'){await writeFile(new URL(name+'.xml',root),await response.text());console.log(name,'public OSM XML retrieved; run extract-pace-roads.mjs');continue;}
  const data=await response.json();if(data.error)throw Error(JSON.stringify(data.error));if(data.exceededTransferLimit)throw Error('County response truncated; pagination required');
  await writeFile(new URL(name+'.json',root),JSON.stringify({url,retrievedAt:new Date().toISOString(),data},null,2)+'\n');console.log(name,data.features?.length);
 }catch(e){console.error(name,e.message);process.exitCode=1;}
}
