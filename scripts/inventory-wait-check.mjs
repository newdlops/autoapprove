// Actual Core conditional-wait lifecycle, synthetic inventory only.
import assert from 'node:assert/strict';
import path from 'node:path';
import {writeFile} from 'node:fs/promises';
import {fixtureSuite,wait} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3),out=path.resolve(option('output')||'.runtime/inventory-wait-check'),suite=await fixtureSuite(out,path.resolve(option('build')||'.build/release')),checks=[];
try{
 const node=await suite.start('owner'),url=node.url+'/api/inventory';
 const get=async(tag,seconds=0,signal)=>{const at=performance.now(),r=await fetch(url,{headers:{...(tag?{'If-None-Match':tag}:{}),...(seconds?{Prefer:'wait='+seconds}:{})},signal});const body=await r.text();return {status:r.status,tag:r.headers.get('etag'),applied:r.headers.get('preference-applied'),ms:Math.round(performance.now()-at),body};};
 let initial=await get();assert.equal(initial.status,200);assert.equal(JSON.parse(initial.body).networkWaitVersion,1);
 const idle=await get(initial.tag,1);assert.equal(idle.status,304);assert.equal(idle.body,'');assert.equal(idle.applied,'wait');assert.ok(idle.ms>=900&&idle.ms<2000);checks.push({case:'Idle waits for its deadline then returns empty 304',ms:idle.ms});
 const changed=get(initial.tag,6);await wait(120);const at=performance.now();await suite.control(node,{paused:true});const result=await changed;
 assert.equal(result.status,200);assert.equal(JSON.parse(result.body).snapshot.paused,true);assert.ok(performance.now()-at<700);checks.push({case:'Mutation wakes a held conditional GET',ms:Math.round(performance.now()-at)});
 const unchanged=get(result.tag,1);await wait(120);await suite.control(node,{paused:true});const same=await unchanged;
 assert.equal(same.status,304);assert.equal(same.tag,result.tag);assert.equal(same.body,'');assert.ok(same.ms>=900);checks.push({case:'An internal revision without a content change does not send a body',ms:same.ms});
 const tag=result.tag,controllers=Array.from({length:12},()=>new AbortController()),pending=controllers.map(c=>get(tag,2,c.signal).catch(e=>({aborted:e.name==='AbortError'})));
 await wait(200);const plain=await fetch(node.url+'/api/state');assert.equal(plain.status,200);const values=await Promise.all(pending);
 assert.equal(values.filter(v=>v.applied==='wait').length,8);assert.equal(values.filter(v=>v.applied===null).length,4);assert.ok(values.filter(v=>v.applied===null).every(v=>v.ms<700));checks.push({case:'Eight holds leave ordinary reads and excess clients responsive',held:8,fallback:4});
 const cancellation=Array.from({length:8},()=>new AbortController()),jobs=cancellation.map(c=>get(tag,6,c.signal).catch(e=>({aborted:e.name==='AbortError'})));await wait(150);cancellation.forEach(c=>c.abort());assert.ok((await Promise.all(jobs)).every(v=>v.aborted));await wait(200);
 const next=await Promise.all(Array.from({length:8},()=>get(tag,1)));assert.ok(next.every(v=>v.applied==='wait'));checks.push({case:'Disconnected clients promptly release every hold slot'});
 const noTag=await get(null,15);assert.equal(noTag.status,200);assert.equal(noTag.applied,null);assert.ok(noTag.ms<700);checks.push({case:'Unconditional first inventory is never held'});
 const report={passed:true,checks,scope:'Actual Core loopback, synthetic source; no user CLI/input'};await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{await suite.stop();}
