import {areaReferenceSupported} from './area-reference.mjs';
// Bounded three-community follow-up. Never retain owner names or full page HTML.
import {readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const additions=[
 {id:'springs-spanish-trail',name:'Springs at Spanish Trail',address:'Emerald Springs Ln (area reference)',zip:'89113',parcel:'16327511032',slug:'SPRINGS-AT-SPANISH-TRAIL'},
 {id:'court-yards-spanish-trail',name:'Court Yards at Spanish Trail',address:'Mission Hills Dr (area reference)',zip:'89113',parcel:'16327510006',slug:'COURT-YARDS-AT-SPANISH-TRAIL'},
 {id:'gardens-spanish-trail',name:'Gardens at Spanish Trail',address:'Harbour Towne Ave (area reference)',zip:'89113',parcel:'16328517036',slug:'GARDENS-AT-SPANISH-TRAIL'}
];
const observations=[];
for(const c of additions){
 const countyURL='https://maps.clarkcountynv.gov/assessor/assessorparceldetail/parceldetail.aspx?hdninstance=pcl7&hdnparcel='+c.parcel;
 const brokerURL='https://www.lasvegascondomania.com/condos/'+c.slug+'.php';
 const pages=[];
 for(const url of [countyURL,brokerURL]){
  const response=await fetch(url,{signal:AbortSignal.timeout(25000)});if(!response.ok)throw Error('HTTP '+response.status+' '+url);
  const html=await response.text();const text=html.replace(/<[^>]*>/g,' ').replace(/\s+/g,' ');
  const field=id=>html.match(new RegExp('<span id="'+id+'">([\\s\\S]*?)</span>'))?.[1].replace(/<[^>]*>/g,'').replaceAll('&nbsp;',' ').trim()??'';
  const observation=url===countyURL?{parcel:c.parcel,address:field('lblLocation'),description:field('lblDesc1'),landUse:field('lblLandUse')}:{communityName:c.name,zip:text.match(/LAS VEGAS\s*,?\s+NV\s+(89113)/i)?.[1],areaReference:c.address};
  if(url===countyURL&&!observation.description.includes('SPANISH TRAIL'))throw Error('Missing county identity');
  if(url===brokerURL&&observation.zip!==c.zip)throw Error('Missing broker ZIP');
  pages.push({url,status:response.status,sha256:createHash('sha256').update(html).digest('hex'),links:[],coordinateEvidence:[],observation});
 }
 if(!areaReferenceSupported(c.address,pages.filter(p=>p.observation?.parcel).map(p=>p.observation.address)))throw Error('Unsupported county area-reference street '+c.id);
 observations.push({communityID:c.id,retrievedAt:new Date().toISOString(),pages});
}
await writeFile('research/audits/spanish-trail-followup.json',JSON.stringify(observations,null,2)+'\n');
const audits=JSON.parse(await readFile('research/audits/site-audit.json'));
const ids=new Set(additions.map(c=>c.id));await writeFile('research/audits/site-audit.json',JSON.stringify([...audits.filter(a=>!ids.has(a.communityID)),...observations].sort((a,b)=>a.communityID.localeCompare(b.communityID)),null,2)+'\n');
let tsv=(await readFile('research/communities.tsv','utf8')).trimEnd();
for(const c of additions)if(!tsv.split(/\r?\n/).some(l=>l.startsWith(c.id+'\t')))tsv+='\n'+[c.id,c.name,c.address,c.zip,'https://maps.clarkcountynv.gov/assessor/assessorparceldetail/parceldetail.aspx?hdninstance=pcl7&hdnparcel='+c.parcel,''].join('\t');
await writeFile('research/communities.tsv',tsv+'\n');
console.log('Retained three county identities and independently observed broker ZIPs; no coordinates or owner information.');
