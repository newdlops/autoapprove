// Real Core dashboard with loopback-only peers, bounded delayed replies and no original input.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('core-build')||'.build/release'),out=path.resolve(option('output')||'dist/qa/dashboard-latency'),baseline=process.argv.includes('--baseline');
await mkdir(out,{recursive:true});const cache=path.resolve('.build/cache/DashboardLatency');await mkdir(cache,{recursive:true});
const binary=path.join(out,'DiscoveryPreview');
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).map(n=>build+'/AutoApproveCore.build/'+n),'Tests/fixtures/discovery-preview.swift','-o',binary],{stdio:'inherit',timeout:300000});
const root=await mkdtemp('/private/tmp/aa-dashboard-wake-'),children=[],servers=[],sockets=new Set(),held=new Set(),checks=[],metrics=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,timeout=5000){const end=performance.now()+timeout;while(!await test()){assert.ok(performance.now()<end,label);await wait(5);}}
async function read(url,signal){const begin=performance.now(),response=await fetch(url,{signal:signal||AbortSignal.timeout(6000)});return {status:response.status,value:await response.json(),ms:performance.now()-begin};}
async function start(label,manual=[]){
 const directory=path.join(root,label);await mkdir(directory);await writeFile(directory+'/web-peers.json',JSON.stringify(manual));
 const child=spawn(binary,[directory],{stdio:['ignore','ignore','pipe']});children.push(child);child.stderr.resume();let info;
 await until(async()=>{try{info=JSON.parse(await readFile(directory+'/ready.json','utf8'));return true;}catch{return child.exitCode!==null;}},'Fixture startup',15000);assert.ok(info);return {...info,child};
}
const ids=Array.from({length:7},()=>randomUUID()),reads=new Map();let template,mode='fast',url;
function respond(req,res){
 const id=req.headers['x-autoapprove-node'];assert.ok(ids.includes(id));
 const value=req.url==='/api/discovery'?{service:'autoapprove',version:1,id,name:id===ids[0]?'000 Healthy':'ZZZ Delayed',urls:[url],port:Number(new URL(url).port),release:template.release}
  :{...template,id,name:id===ids[0]?'000 Healthy':'ZZZ Delayed'};
 const body=Buffer.from(JSON.stringify(value));res.writeHead(200,{'Content-Type':'application/json','Content-Length':body.length,'X-AutoApprove-Node':mode==='identity'?'wrong-node':id,Connection:'close'});res.end(body);
}
const manual=(id,index)=>({id,name:index===0?'000 Healthy':'ZZZ Delayed '+index,address:url});
try{
 const bootstrap=await start('bootstrap');template=(await read(bootstrap.url+'/api/state')).value;
 const server=createServer((req,res)=>{
  assert.equal(req.method,'GET','The dashboard test never sends original input');
  if(req.url==='/api/discovery'){respond(req,res);return;}
  const id=req.headers['x-autoapprove-node'];reads.set(id,(reads.get(id)||0)+1);
  if((mode==='slow-neighbours'&&id!==ids[0])||mode==='hold-all'){
   const pending={req,res};held.add(pending);res.once('close',()=>held.delete(pending));return;
  }
  respond(req,res);
 });servers.push(server);server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));url='http://127.0.0.1:'+server.address().port;
 const cold=[];
 for(let index=0;index<5;index++){
  const gateway=await start('single-'+index,[manual(ids[0],0)]),result=await read(gateway.url+'/api/network');
  assert.equal(result.status,200);assert.ok(result.value.nodes.some(n=>n.id===ids[0]&&n.online));cold.push(result.ms);gateway.child.kill();
 }
 metrics.push({case:'one-fast-peer',samplesMS:cold});checks.push('A fresh exact peer inventory reaches the dashboard with its current identity');
 mode='slow-neighbours';const crowded=await start('crowded',ids.map(manual)),before=reads.get(ids[0])||0;
 const replies=await Promise.all(Array.from({length:16},()=>read(crowded.url+'/api/network')));
 assert.ok(replies.every(r=>r.status===200&&r.value.nodes.some(n=>n.id===ids[0]&&n.online)&&r.value.partial===true));
 assert.equal((reads.get(ids[0])||0)-before,1,'Concurrent viewers must share the same exact source read');
 metrics.push({case:'six-stalled-neighbours',samplesMS:replies.map(r=>r.ms)});
 if(!baseline)assert.ok(Math.min(...replies.map(r=>r.ms))<200,'The first healthy peer must not wait for the 350ms stalled-peer budget');
 checks.push('Six delayed peers cannot hold the healthy inventory; sixteen viewers share one read');
 const cached=await read(crowded.url+'/api/network');assert.ok(cached.value.nodes.some(n=>n.id===ids[0]&&n.online));metrics.push({case:'healthy-cached-with-stalls',ms:cached.ms});
 if(!baseline)assert.ok(cached.ms<200);checks.push('A current healthy inventory returns without polling pending neighbours');
 mode='fast';for(const {req,res}of [...held])if(!res.destroyed)respond(req,res);
 await until(async()=>{const r=await read(crowded.url+'/api/network');return r.value.nodes.filter(n=>!n.local&&n.online).length===7;},'Delayed inventories must appear after their own completion');
 checks.push('Later peers finish in the background and appear without restarting or hiding the healthy peer');
 crowded.child.kill();await wait(30);
 mode='hold-all';const cancelled=await start('cancelled',[manual(ids[0],0)]),at=reads.get(ids[0])||0,controller=new AbortController();
 const abandoned=read(cancelled.url+'/api/network',controller.signal);abandoned.catch(()=>{});const survivor=read(cancelled.url+'/api/network');
 await until(()=>held.size>0,'Shared source read started');controller.abort();await assert.rejects(abandoned);
 mode='fast';for(const {req,res}of [...held])if(!res.destroyed)respond(req,res);
 const survived=await survivor;assert.ok(survived.value.nodes.some(n=>n.id===ids[0]&&n.online));assert.equal((reads.get(ids[0])||0)-at,1);
 checks.push('One cancelled browser cannot cancel another viewer or replay its shared read');cancelled.child.kill();
 mode='identity';const wrong=await start('wrong-identity',[manual(ids[0],0)]),denied=await read(wrong.url+'/api/network');
 assert.ok(!denied.value.nodes.find(n=>n.id===ids[0])?.online);checks.push('A completion notification never substitutes for fresh exact-node validation');wrong.child.kill();
 mode='hold-all';const unavailable=await start('unavailable',[manual(ids[1],1)]),begin=performance.now();
 const bounded=await read(unavailable.url+'/api/network?'+new URLSearchParams({initial:'1',node:ids[1]}));const elapsed=performance.now()-begin;
 assert.ok(bounded.value.nodes[0].local&&bounded.value.nodes[0].online);assert.ok(bounded.value.nodes.find(n=>n.id===ids[1])?.loading);assert.ok(elapsed<1000);
 metrics.push({case:'unavailable-selected',ms:elapsed});checks.push('An unavailable selected peer retains the bounded wait and returns the local page');
 const report={result:'PASS',baseline,checks,metrics,scope:'Real Swift Core on loopback with synthetic peers. No phone, original input, physical LAN scan or system changes.'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();for(const socket of sockets)socket.destroy();
 await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));await rm(root,{recursive:true,force:true});
}
