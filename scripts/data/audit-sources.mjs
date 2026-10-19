// Read-only public-site audit; stores metadata and link evidence, not artwork or resident data.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const root = new URL('../../', import.meta.url);
const lines=(await readFile(new URL('research/communities.tsv',root),'utf8')).trimEnd().split(/\r?\n/);
const headers=lines.shift().split('\t');
const rows=lines.map(line=>Object.fromEntries(line.split('\t').map((v,i)=>[headers[i],v])));
await mkdir(new URL('research/audits/',root),{recursive:true});
const out=[];
const get=async url=>{
 const r=await fetch(url,{signal:AbortSignal.timeout(20000),headers:{'User-Agent':'ApartmentFinderPublicSourceAudit/1.0'}});
 const text=await r.text(); return {url:r.url,status:r.status,text};
};
const links=(text,url)=>[...text.matchAll(/(?:href|src)\s*=\s*["']([^"']+)["']/gi)].map(m=>{try{return new URL(m[1].replaceAll('&amp;','&'),url).href}catch{return null}}).filter(Boolean);
const interesting=/sightmap|engrain|site.?plan|community.?map|property.?map|floor.?plan|sitemap|\.pdf(?:\?|$)/i;
for(let start=0;start<rows.length;start+=5){
 await Promise.all(rows.slice(start,start+5).map(async c=>{
  const record={communityID:c.id,retrievedAt:new Date().toISOString(),pages:[]};
  const queue=[c.url]; const seen=new Set();
  while(queue.length && seen.size<4){
   const url=queue.shift(); if(seen.has(url))continue;seen.add(url);
   try{
    const r=await get(url); const ll=links(r.text,r.url);const evidence=ll.filter(u=>interesting.test(u));
    const embeds=[...r.text.matchAll(/https?:\/\/sightmap\.com\/(?:embed\/)?[a-z0-9]+(?:[^\s"'<>]*)/gi)].map(m=>m[0]).filter(u=>!u.endsWith('/embed')&&!u.includes('/api.js'));
    // Some official widgets compose the embed URL from a public JSON configuration value.
    for(const m of r.text.matchAll(/"sightmapID"\s*:\s*"([a-z0-9]{11})"/gi))embeds.push('https://sightmap.com/embed/'+m[1]);
    const coordinates=[...r.text.matchAll(/"(?:latitude|longitude)"\s*:\s*"?(-?\d+\.\d+)/gi)].map(m=>m[0]);
    record.pages.push({url:r.url,status:r.status,sha256:createHash('sha256').update(r.text).digest('hex'),links:[...new Set([...evidence,...embeds])],coordinateEvidence:coordinates.slice(0,6)});
    if(r.status===200)for(const u of evidence){if(new URL(u).hostname===new URL(c.url).hostname && !/\.pdf|sitemap\.xml|\?|#|wp-json|apply|login/i.test(u) && !seen.has(u))queue.push(u)}
   }catch(e){record.pages.push({url,error:e.message});}
  }
  out.push(record);console.log(c.id,record.pages.length,record.pages.flatMap(p=>p.links??[]).filter(u=>/sightmap|site.?plan|community.?map|property.?map/i.test(u)).join(' '));
 }));
}
out.sort((a,b)=>a.communityID.localeCompare(b.communityID));
await writeFile(new URL('research/audits/site-audit.json',root),JSON.stringify(out,null,2)+'\n');
