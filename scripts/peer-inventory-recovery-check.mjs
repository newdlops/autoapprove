// Real Core gateway, controlled HTTP peer. Never touches installed/user terminals.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {randomUUID,createHash} from 'node:crypto';
import {writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fixtureSuite,json,wait,until} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const out=path.resolve(option('output')||'.runtime/lan-stability-197/inventory'),baseline=process.argv.includes('--baseline');
const suite=await fixtureSuite(out,path.resolve(option('build')||'.build/network-stability/release'));
const sockets=new Set(),held=new Set(),reads=[],checks=[],id=randomUUID();let state,mode='healthy',watchFailures=0;
const server=createServer((req,res)=>{
 const p=new URL(req.url,'http://localhost').pathname;
 res.setHeader('X-AutoApprove-Node',id);
 if(p==='/api/discovery'){res.end(JSON.stringify({service:'autoapprove',version:1,id,name:'Inventory recovery QA',urls:[],port:server.address().port,release:state.release}));return;}
 if(!['/api/state','/api/inventory'].includes(p)){res.writeHead(404);res.end('{}');return;}
 const watch=!!req.headers.prefer,entry={watch,mode,at:performance.now(),node:req.headers['x-autoapprove-node']};reads.push(entry);
 if(watch&&mode!=='healthy'){
  watchFailures++;state.snapshot.paused=true;
  if(mode==='drop'){req.socket.destroy();return;}
  if(mode==='stall'){held.add(res);res.once('close',()=>held.delete(res));return;}
  if(mode==='wrong-node'){res.setHeader('X-AutoApprove-Node',randomUUID());res.end('{}');return;}
  if(mode==='denied'){const body='{"error":"denied"}';res.writeHead(403,{'Content-Length':Buffer.byteLength(body)});res.end(body);return;}
  if(mode==='unavailable'){res.writeHead(503,{'Content-Length':2});res.end('{}');return;}
  if(mode==='protocol'){res.writeHead(200,{'Content-Length':3});res.end('bad');return;}
 }
 if(mode==='outage'){req.socket.destroy();return;}
 const body=JSON.stringify(state),tag='"'+createHash('sha256').update(body).digest('hex')+'"';res.setHeader('ETag',tag);
 const respond=()=>{if(res.destroyed)return;const same=req.headers['if-none-match']===tag;res.setHeader('Content-Length',same?0:Buffer.byteLength(body));res.writeHead(same?304:200);res.end(same?undefined:body);};
 if(watch){res.setHeader('Preference-Applied','wait');const timer=setTimeout(respond,250);res.once('close',()=>clearTimeout(timer));}else respond();
});
server.on('connection',s=>{sockets.add(s);s.once('close',()=>sockets.delete(s));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let gateway;
async function network(tag){const at=performance.now(),r=await fetch(gateway.url+'/api/network',{headers:tag?{'If-None-Match':tag,Prefer:'wait=1'}:{},signal:AbortSignal.timeout(15000)});return {status:r.status,tag:r.headers.get('etag'),body:r.status===304?null:await r.json(),ms:Math.round(performance.now()-at)};}
async function prime(){
 mode='healthy';state.snapshot.paused=false;
 let value;
 await until(async()=>{value=await network();return value.body?.nodes.find(n=>n.id===id)?.online;},'Healthy finite inventory',12000);
 return value;
}
try{
 gateway=await suite.start('gateway');state=(await json(gateway.url+'/api/state')).value;
 state={...state,id,name:'Inventory recovery QA',sessions:[],screenShares:[],webURLs:[],webPort:server.address().port,snapshot:{...state.snapshot,sessions:[],events:[],paused:false}};
 const added=await json(gateway.url+'/api/peers',{address:'http://127.0.0.1:'+server.address().port});assert.equal(added.status,200,JSON.stringify(added.value));
 let first=await prime();mode='drop';let failuresBefore=watchFailures,result=first,offline=0,fresh=false;
 for(let i=0;i<8;i++){
  result=await network(result.tag);const peer=result.body?.nodes.find(n=>n.id===id);
  if(peer&&!peer.online)offline++;
  if(peer?.online&&peer.state.snapshot.paused)fresh=true;
  if(watchFailures>failuresBefore&&(baseline||fresh))break;
 }
 assert.ok(watchFailures>failuresBefore,'The real gateway started a conditional peer watch');
 if(baseline){assert.ok(offline>0,'Old Core must reproduce a false offline state');const report={baseline:true,reproduced:true,offline,watchFailures};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));process.exitCode=0;}
 else {
  assert.equal(offline,0,'A dropped watch must be confirmed by a fresh finite read before declaring offline');assert.ok(fresh,'Recovery uses new state, never the retained success');checks.push({case:'Dropped watch recovers fresh inventory without an offline transition',ms:result.ms});
  await wait(3300);first=await prime();mode='unavailable';failuresBefore=watchFailures;fresh=false;offline=0;result=first;
  for(let i=0;i<10&&!fresh;i++){result=await network(result.tag);const peer=result.body?.nodes.find(n=>n.id===id);if(peer&&!peer.online)offline++;if(peer?.online&&peer.state.snapshot.paused)fresh=true;}
  assert.ok(watchFailures>failuresBefore);assert.equal(offline,0);assert.ok(fresh);checks.push({case:'HTTP 503 from a watch is confirmed by a fresh finite read'});
  await wait(3300);first=await prime();mode='stall';failuresBefore=watchFailures;fresh=false;offline=0;const began=performance.now();result=first;
  for(let i=0;i<14&&!fresh;i++){result=await network(result.tag);const peer=result.body?.nodes.find(n=>n.id===id);if(peer&&!peer.online)offline++;if(peer?.online&&peer.state.snapshot.paused)fresh=true;}
  assert.ok(watchFailures>failuresBefore);assert.equal(offline,0);assert.ok(fresh);assert.ok(performance.now()-began<12000);checks.push({case:'A silent six-second watch times out and a finite read recovers new state',ms:Math.round(performance.now()-began)});
  for(const value of held)value.destroy();held.clear();
  for(const failure of ['wrong-node','denied','protocol']){
   await wait(3300);first=await prime();mode=failure;failuresBefore=watchFailures;result=first;let rejected=false;
   for(let i=0;i<10&&!rejected;i++){result=await network(result.tag);rejected=result.body?.nodes.some(n=>n.id===id&&!n.online);}
   assert.ok(rejected,failure+' must remain an error');assert.ok(watchFailures>failuresBefore);
   const at=reads.findIndex(r=>r.mode===failure&&r.watch),next=reads[at+1];assert.ok(!next||next.watch||next.mode!==failure,'No automatic finite retry after '+failure);
   checks.push({case:failure+' is not recovered as a successful connection'});
  }
  await wait(3300);first=await prime();mode='outage';result=first;let unavailable=false;
  for(let i=0;i<10&&!unavailable;i++){result=await network(result.tag);unavailable=result.body?.nodes.some(n=>n.id===id&&!n.online);}
  assert.ok(unavailable,'Both failed paths must still become offline');await wait(2500);await prime();checks.push({case:'A real outage is reported and finite reads recover when the peer returns'});
  assert.equal(reads[0].node,undefined,'Manual setup first discovers the unknown peer identity');assert.ok(reads.slice(1).every(r=>r.node===id));const report={passed:true,checks,watchFailures,scope:'Actual compiled Core conditional watches/finite HTTP recovery with synthetic peer; no original CLI or input'};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
 }
}finally{for(const res of held)res.destroy();for(const s of sockets)s.destroy();await new Promise(resolve=>server.close(resolve));await suite.stop();}
