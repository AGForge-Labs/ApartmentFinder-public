import test from 'node:test';
import assert from 'node:assert/strict';
import {handle, reserve} from './worker.mjs';

const now = new Date('2026-09-18T12:00:00Z');
const env = {APP_TOKEN:'a'.repeat(40), GOOGLE_GEOCODING_KEY:'server-secret', QUOTAS_VERIFIED_UNTIL:'2026-09-25T00:00:00Z', DAILY_LIMIT:'100', MONTHLY_LIMIT:'3100'};
const request = (address='9314 W Russell Rd, Las Vegas NV 89148',token=env.APP_TOKEN) => new Request('https://private.example/geocode',{method:'POST',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:JSON.stringify({address})});
test('disabled config and bad credentials cause zero provider calls',async()=>{
  let calls=0; const dependencies={now,charge:async()=>{calls++},fetch:async()=>{calls++}};
  assert.equal((await handle(request(),{},dependencies)).status,503);
  assert.equal((await handle(request('test','bad'),env,dependencies)).status,401);
  assert.equal((await handle(request(),{...env,QUOTAS_VERIFIED_UNTIL:'2026-09-01T00:00:00Z'},dependencies)).status,503);
  assert.equal(calls,0);
});
test('quota rejection happens before provider request and no secrets leak',async()=>{
  let calls=0;
  const response=await handle(request(),env,{now,charge:async()=>false,fetch:async()=>{calls++}});
  assert.equal(response.status,429); assert.equal(calls,0); assert.equal((await response.text()).includes(env.GOOGLE_GEOCODING_KEY),false);
});
test('successful lookup is transient and independently filters postal code',async()=>{
  let charged=0;
  const results=['89148','99999'].map(postal=>({formatted_address:'Result '+postal,place_id:postal,geometry:{location:{lat:36.06,lng:-115.29}},address_components:[{types:['postal_code'],short_name:postal}]}));
  const response=await handle(request(),env,{now,charge:async()=>{charged++;return true},fetch:async url=>{
    assert.equal(new URL(url).origin,'https://maps.googleapis.com');
    return Response.json({status:'OK',results});
  }});
  assert.equal(response.status,200); assert.equal(charged,1);
  assert.equal(response.headers.get('Cache-Control'),'no-store');
  const body=await response.json(); assert.equal(body.results.length,1); assert.equal(body.results[0].placeID,'89148');
});
test('reject oversized and empty payloads without spending quota',async()=>{
  let calls=0; const deps={now,charge:async()=>{calls++;return true}};
  assert.equal((await handle(request('x'.repeat(5000)),env,deps)).status,413);
  assert.equal((await handle(request(''),env,deps)).status,400);
  assert.equal(calls,0);
});
test('atomic reservations cannot exceed daily cap',async()=>{
  let record, queue=Promise.resolve();
  const storage={transaction(callback){
    const job=queue.then(()=>callback({get:async()=>record,put:async(_,value)=>{record=value}}));
    queue=job.catch(()=>{}); return job;
  }};
  const outcomes=await Promise.all(Array.from({length:120},()=>reserve(storage,now,100,3100)));
  assert.equal(outcomes.filter(Boolean).length,100); assert.equal(record.dailyUsed,100);
  assert.equal(await reserve(storage,new Date('2026-09-17T12:00:00Z'),100,3100),false);
  assert.equal(await reserve(storage,new Date('2026-09-19T12:00:00Z'),100,100),false);
});
