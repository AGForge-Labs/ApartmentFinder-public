import {readFile,writeFile} from 'node:fs/promises';
const saved=JSON.parse(await readFile('research/geography/county-gilis20.json'));const out=[];
for(let start=0;start<saved.data.features.length;start+=6){await Promise.all(saved.data.features.slice(start,start+6).map(async f=>{
 const apn=f.attributes.APN,record={candidateAPN:apn,retrievedAt:new Date().toISOString(),lookups:[]};
 const probes=apn.endsWith('000')?[apn,apn.slice(0,-3)+'001',apn.slice(0,-3)+'002']:[apn];
 for(const parcel of probes){const url='https://maps.clarkcountynv.gov/assessor/assessorparceldetail/parceldetail.aspx?hdninstance=pcl7&hdnparcel='+parcel;try{const r=await fetch(url,{signal:AbortSignal.timeout(20000)});const text=await r.text();const field=id=>text.match(new RegExp('<span id="'+id+'">([\\s\\S]*?)</span>'))?.[1].replace(/<[^>]*>/g,'').replaceAll('&nbsp;',' ').trim()??'';const entry={parcel,url,status:r.status,address:field('lblLocation'),description:field('lblDesc1'),landUse:field('lblLandUse'),units:field('lblUnits')};record.lookups.push(entry);if(entry.address)break;}catch(e){record.lookups.push({parcel,url,error:e.message});}}
 out.push(record);console.log(apn,JSON.stringify(record.lookups.at(-1)));}));}
out.sort((a,b)=>a.candidateAPN.localeCompare(b.candidateAPN));await writeFile('research/geography/county-parcel-identities.json',JSON.stringify(out,null,2)+'\n');
