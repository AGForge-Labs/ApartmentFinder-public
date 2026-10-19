const reply=(body,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}});
const failure=(error,status)=>reply({error},status);
const parts=new Intl.DateTimeFormat('en-CA',{timeZone:'America/Los_Angeles',year:'numeric',month:'2-digit',day:'2-digit'});
function period(now) {
  const p=Object.fromEntries(parts.formatToParts(now).map(item=>[item.type,item.value]));
  const month=p.year+'-'+p.month; return {day:month+'-'+p.day,month};
}
function limits(env) {
  const daily=Number(env.DAILY_LIMIT??100),monthly=Number(env.MONTHLY_LIMIT??3100);
  if(!Number.isInteger(daily)||daily<1||daily>100||!Number.isInteger(monthly)||monthly<1||monthly>3100) return null;
  return {daily,monthly};
}
function configured(env,now) {
  const until=Date.parse(env.QUOTAS_VERIFIED_UNTIL??'');
  return env.APP_TOKEN?.length>=32 && Boolean(env.GOOGLE_GEOCODING_KEY) && Number.isFinite(until) &&
    until>now.getTime() && until-now.getTime()<=32*86400000 && limits(env);
}
async function boundedJSON(request) {
  const reader=request.body?.getReader();
  if(!reader) throw new Error('empty');
  const chunks=[]; let length=0;
  try {
    while(true) {
      const {value,done}=await reader.read(); if(done)break;
      length+=value.byteLength; if(length>4096){await reader.cancel();throw new Error('large');} chunks.push(value);
    }
  } finally {reader.releaseLock();}
  const bytes=new Uint8Array(length); let offset=0;
  for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
  return JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes));
}
export async function reserve(storage,now,dailyLimit,monthlyLimit) {
  const current=period(now);
  return storage.transaction(async transaction=>{
    const saved=await transaction.get('usage');
    if(saved && (!/^\d{4}-\d{2}-\d{2}$/.test(saved.day)||!/^\d{4}-\d{2}$/.test(saved.month)||
      !saved.day.startsWith(saved.month+'-')||!Number.isSafeInteger(saved.dailyUsed)||saved.dailyUsed<0||
      !Number.isSafeInteger(saved.monthlyUsed)||saved.monthlyUsed<saved.dailyUsed||
      current.day<saved.day||current.month<saved.month)) return false;
    const dailyUsed=saved?.day===current.day?saved.dailyUsed:0;
    const monthlyUsed=saved?.month===current.month?saved.monthlyUsed:0;
    if(dailyUsed>=dailyLimit||monthlyUsed>=monthlyLimit)return false;
    await transaction.put('usage',{...current,dailyUsed:dailyUsed+1,monthlyUsed:monthlyUsed+1});
    return true;
  });
}
export async function handle(request,env,dependencies={}) {
  const now=dependencies.now??new Date();
  if(!configured(env,now))return failure('Online lookup is not configured or its quota verification expired.',503);
  if(request.headers.get('Authorization')!=='Bearer '+env.APP_TOKEN)return failure('Unauthorized.',401);
  if(request.method!=='POST'||new URL(request.url).pathname!=='/geocode')return failure('Use POST /geocode.',405);
  let input;
  try {input=await boundedJSON(request);}catch(error){return failure('Invalid or oversized JSON.',error.message==='large'?413:400);}
  if(typeof input?.address!=='string'||input.address.trim().length<5||input.address.length>300)return failure('Supply one street address (5–300 characters).',400);
  try {
    const charge=dependencies.charge??(async()=>{
      const id=env.QUOTA.idFromName('single-private-account');
      const response=await env.QUOTA.get(id).fetch('https://quota/reserve',{method:'POST'});
      return response.status===200;
    });
    if(!await charge())return failure('Free lookup allowance reached. Saved maps still work.',429);
    const url=new URL('https://maps.googleapis.com/maps/api/geocode/json');
    url.searchParams.set('address',input.address.trim());url.searchParams.set('components','country:US');
    url.searchParams.set('bounds','35.95,-115.40|36.15,-115.15');
    url.searchParams.set('key',env.GOOGLE_GEOCODING_KEY);
    const response=await (dependencies.fetch??fetch)(url.toString(),{signal:AbortSignal.timeout(8000),redirect:'error'});
    if(!response.ok)return failure('Address provider is unavailable.',502);
    const data=await response.json();
    if(data.status==='ZERO_RESULTS')return reply({results:[]});
    if(data.status!=='OK')return failure('Address provider declined this lookup.',data.status==='OVER_QUERY_LIMIT'?429:502);
    const results=(data.results??[]).filter(result=>{
      const zip=result.address_components?.find(part=>part.types?.includes('postal_code'))?.short_name;
      const location=result.geometry?.location;
      return ['89113','89148'].includes(zip)&&Number.isFinite(location?.lat)&&Number.isFinite(location?.lng);
    }).slice(0,5).map(result=>({
      name:result.formatted_address,placeID:result.place_id,latitude:result.geometry.location.lat,longitude:result.geometry.location.lng,partialMatch:Boolean(result.partial_match)
    }));
    return reply({results});
  } catch {return failure('Online lookup is unavailable. Saved maps still work.',503);}
}
export default {fetch:handle};
export class GeocodeQuota {
  constructor(ctx,env){this.ctx=ctx;this.env=env;}
  async fetch(request) {
    const now=new Date();
    if(request.method!=='POST'||!configured(this.env,now))return failure('Disabled.',503);
    const {daily,monthly}=limits(this.env);
    const accepted=await reserve(this.ctx.storage,now,daily,monthly);
    return reply({accepted},accepted?200:429);
  }
}
