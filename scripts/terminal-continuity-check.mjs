// Same-source resume, fresh controls, shared live observation and bounded warm
// history through actual direct/relayed Core HTTP and compressed SSE.
import assert from 'node:assert/strict';
import path from 'node:path';
import {writeFile} from 'node:fs/promises';
import {fixtureSuite,json,until,wait} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const out=path.resolve(option('output')||'dist/qa/terminal-continuity'),baseline=process.argv.includes('--baseline');
const suite=await fixtureSuite(out,path.resolve(option('core-build')||'.build/release')),checks=[],metrics=[];
const query=(id,extra={})=>new URLSearchParams({session:id,delta:'1',copy:'1',compact:'1',...extra});
const isScreen=event=>event.type==='screen';
function restore(update,base){
 if(typeof update.screen==='string')return update.screen;
 if(update.screenPatch){const p=update.screenPatch;assert.equal(p.baseRevision,base.revision);assert.equal(p.baseLength,base.screen.length);return base.screen.slice(0,p.prefix)+p.text+base.screen.slice(p.baseLength-p.suffix);}
 if(update.screenCopy){const c=update.screenCopy;assert.equal(c.baseRevision,base.revision);return c.head+base.screen.slice(c.start,c.start+c.count)+c.tail;}
 assert.equal(update.revision,base.revision);return base.screen;
}
try{
 const owner=await suite.start('owner'),gateway=await suite.start('gateway');
 assert.equal((await json(gateway.url+'/api/peers',{address:owner.url})).status,200);
 const state=(await json(owner.url+'/api/state')).value,id=state.sessions[0].session.id;
 const stats=async()=>(await json(owner.url+'/api/terminal/timings')).value;
 for(const [label,node,extra]of [['direct',owner,{}],['relayed',gateway,{node:owner.id}]]){
  const url=node.url+'/api/terminal/stream?';
  const live=suite.stream(url+query(id,extra));const first=await live.event(isScreen),initial=first.value;
  assert.ok(initial.screen.length>40000);assert.ok(initial.cursor);assert.equal(live.encoding,'gzip');
  const firstBytes=live.wireBytes,quietStart=live.events.length;
  await live.event(e=>baseline?e.type==='screen':e.type==='alive',quietStart);
  const quietBytes=live.wireBytes-firstBytes;
  if(!baseline){
   const pulse=live.events.find(e=>e.type==='alive');assert.deepEqual(Object.keys(pulse.value).sort(),['observedAt','revision','sequence','streamID']);
   assert.equal(pulse.value.streamID,initial.streamID);assert.equal(pulse.value.revision,initial.revision);assert.ok(pulse.value.sequence>initial.sequence);
   checks.push(label+': negotiated compact liveness confirms a newly checked source without resending controls');
  }
  const mark='\nCONTINUITY-'+label+'-🙂';await suite.control(owner,{append:mark});
  const changed=(await live.event(e=>isScreen(e)&&e.value.revision!==initial.revision,quietStart)).value;
  const current={...changed,screen:restore(changed,initial)};assert.equal(current.screen,initial.screen+mark);
  assert.ok(changed.screenPatch||changed.screenCopy);assert.ok(changed.cursor);assert.equal(changed.appearanceUnchanged,true);
  live.close();await wait(150);
  const resumed=suite.stream(url+query(id,{...extra,revision:initial.revision,stream:initial.streamID}));const resumedFirst=await resumed.event(isScreen);
  assert.equal(restore(resumedFirst.value,initial),current.screen);
  if(!baseline){assert.equal(resumedFirst.value.screen,undefined);assert.ok(resumedFirst.value.screenPatch||resumedFirst.value.screenCopy);checks.push(label+': fresh same-source reopening sends only the change since the last acknowledged revision');}
  metrics.push({label,firstWireBytes:firstBytes,quietWireBytes:quietBytes,resumeWireBytes:resumed.wireBytes,firstDecodedBytes:first.bytes,resumeDecodedBytes:resumedFirst.bytes});
  resumed.close();await wait(100);
  if(baseline)continue;
  for(const bad of [{revision:'unknown-revision',stream:current.streamID},{revision:current.revision,stream:'different-original'}]){
   const full=suite.stream(url+query(id,{...extra,...bad}));const event=await full.event(isScreen);assert.equal(event.value.screen,current.screen);full.close();await wait(70);
  }
  checks.push(label+': missing revision or changed original falls back to a verified full snapshot');
  const same=suite.stream(url+query(id,{...extra,revision:current.revision,stream:current.streamID}));
  const unchanged=(await same.event(isScreen)).value;assert.equal(unchanged.screen,undefined);assert.equal(unchanged.revision,current.revision);assert.deepEqual(unchanged.keys,current.keys);
  await suite.control(owner,{allowed:false});const blocked=(await same.event(e=>isScreen(e)&&e.value.keys.length===0)).value;
  assert.equal(blocked.screen,'');assert.ok(blocked.outputReason);assert.equal(blocked.streamID,undefined);
  const denied=suite.stream(url+query(id,{...extra,revision:current.revision,stream:current.streamID}));
  const deniedFirst=(await denied.event(isScreen)).value;assert.equal(deniedFirst.screen,'');assert.equal(deniedFirst.keys.length,0);assert.equal(deniedFirst.streamID,undefined);denied.close();
  checks.push(label+': revoking permission updates active controls immediately and a warm reconnect cannot reveal cached text or authorize input');
  const restoring=same.events.length;
  await suite.control(owner,{allowed:true});const granted=(await same.event(e=>isScreen(e)&&e.value.keys.length>0&&e.value.streamID,restoring)).value;
  assert.ok(granted.streamID!==current.streamID);assert.equal(granted.screen,current.screen);same.close();await wait(200);
  const old=suite.stream(url+query(id,{...extra,revision:current.revision,stream:current.streamID}));assert.equal((await old.event(isScreen)).value.screen,current.screen);old.close();
  checks.push(label+': restored permission rotates its original presentation binding and retires the old resume basis');
 }
 if(!baseline){
  await wait(300);const before=await stats();
  const streams=Array.from({length:8},()=>suite.stream(owner.url+'/api/terminal/stream?'+query(id)));
  const connecting=performance.now();
  const firsts=await Promise.all(streams.map(stream=>stream.event(isScreen)));
  const connected=performance.now(),liveStart=await stats();await wait(1800);
  const after=await stats();assert.equal(after.counters.liveProducers-before.counters.liveProducers,1);
  assert.ok(after.counters.sharedSubscribers-before.counters.sharedSubscribers>=7);
  assert.ok(after.counters.liveReads>before.counters.liveReads,'The shared producer must actually read the original');
  metrics.push({label:'eight-viewers',producerStarts:after.counters.liveProducers-before.counters.liveProducers,
   liveReadCalls:after.counters.liveReads-before.counters.liveReads,sharedSubscribers:after.counters.sharedSubscribers-before.counters.sharedSubscribers,
   connectMS:connected-connecting,windowReads:after.counters.liveReads-liveStart.counters.liveReads});
  await suite.control(owner,{storm:true});await wait(150);
  const noiseStart=await stats(),noiseTime=performance.now();await wait(1000);const noiseEnd=await stats();
  assert.ok(noiseEnd.counters.liveReads-noiseStart.counters.liveReads<=Math.ceil((performance.now()-noiseTime)/50)+3,'Unchanged notification bursts must coalesce to at most 20 reads/s');
  await suite.control(owner,{storm:false});checks.push('Bursts of unchanged native/monitor signals are coalesced without queuing frames or repeating permission queries unboundedly');
  streams[0].close();await suite.control(owner,{append:'\nSEVEN-VIEWERS-🙂'});
  for(let i=1;i<streams.length;i++){const event=await streams[i].event(e=>isScreen(e)&&e.value.revision!==firsts[i].value.revision);assert.ok(restore(event.value,firsts[i].value).endsWith('SEVEN-VIEWERS-🙂'));}
  checks.push('Eight simultaneous viewers share one source producer; cancelling one leaves seven live');
  streams.forEach(stream=>stream.close());await wait(350);const idle=await stats();await wait(1200);const still=await stats();
  assert.equal(still.counters.liveReads,idle.counters.liveReads);checks.push('The last subscriber cancels source polling; warm history performs no background reads');
  await wait(2100);await suite.control(owner,{delayMS:600});
  const pendingReads=(await suite.observe(owner)).reads;
  const cancelled=suite.stream(owner.url+'/api/terminal/stream?'+query(id));
  const survivor=suite.stream(owner.url+'/api/terminal/stream?'+query(id));
  await until(async()=>(await suite.observe(owner)).reads>pendingReads,'A shared first read must be in progress');
  assert.equal(survivor.events.length,0);cancelled.close();
  assert.ok((await survivor.event(isScreen)).value.screen.length);survivor.close();
  checks.push('Cancelling a subscriber during the shared first read does not cancel its surviving viewer');
  await wait(2100);const abandonedReads=(await suite.observe(owner)).reads;
  const abandoned=[suite.stream(owner.url+'/api/terminal/stream?'+query(id)),suite.stream(owner.url+'/api/terminal/stream?'+query(id))];
  await until(async()=>(await suite.observe(owner)).reads>abandonedReads,'A second first read must be pending');
  abandoned.forEach(stream=>stream.close());await wait(100);
  await suite.control(owner,{delayMS:0,append:'\nAFTER-CANCELLED-FIRST-READ'});
  const replacement=suite.stream(owner.url+'/api/terminal/stream?'+query(id));
  assert.ok((await replacement.event(isScreen)).value.screen.endsWith('AFTER-CANCELLED-FIRST-READ'));replacement.close();
  checks.push('A new viewer cannot join or publish the stale result of a first read abandoned by all viewers');
  // Only a bounded number of bases survive rapid output. A cache miss must
  // recover by full snapshot, rather than guessing or chaining stale deltas.
  const history=suite.stream(owner.url+'/api/terminal/stream?'+query(id));const base=(await history.event(isScreen)).value;
  let previous=base;
  for(let i=0;i<7;i++){
   const offset=history.events.length;await suite.control(owner,{append:'\nHISTORY-'+i});
   const event=(await history.event(e=>isScreen(e)&&e.value.revision!==previous.revision,offset)).value;
   previous={...event,screen:restore(event,previous)};
  }
  history.close();await wait(100);
  const evicted=suite.stream(owner.url+'/api/terminal/stream?'+query(id,{revision:base.revision,stream:base.streamID}));
  assert.equal((await evicted.event(isScreen)).value.screen,previous.screen);evicted.close();checks.push('A basis beyond six retained revisions is evicted and falls back to a full verified frame');
  const warm=suite.stream(owner.url+'/api/terminal/stream?'+query(id));const expiring=(await warm.event(isScreen)).value;warm.close();
  await wait(31000);await suite.control(owner,{append:'\nAFTER-WARM-EXPIRY'});
  const expired=suite.stream(owner.url+'/api/terminal/stream?'+query(id,{revision:expiring.revision,stream:expiring.streamID}));
  const fresh=(await expired.event(isScreen)).value;assert.equal(fresh.screen,expiring.screen+'\nAFTER-WARM-EXPIRY');expired.close();
  checks.push('A 30-second expired basis is never reused, even when its original stream identity still matches');
  const final=await stats();assert.ok(final.counters.resumeHits>=4);assert.ok(final.counters.resumeMisses>=6);assert.ok(final.counters.compactPulses>=2);
  assert.deepEqual((await suite.observe(owner)).inputs,[]);
 }
 const report={baseline,checks,metrics,inputPosts:0,scope:'Actual Core direct/relayed HTTP + gzip SSE, synthetic originals, permission changes and elapsed TTL; no user input or physical phone'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{await suite.stop();}
