// Actual Core servers with saved synthetic identities and loopback-only stalls.
// No physical LAN scan, original user terminal, input, or system setting changes.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {createServer,get,request as upstreamRequest} from 'node:http';
import {mkdir,mkdtemp,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
import {fixtureSuite,json,until,wait} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const out=path.resolve(option('output')||'dist/qa/discovery-reopen'),build=path.resolve(option('core-build')||'.build/release'),baseline=process.argv.includes('--baseline');
await mkdir(out,{recursive:true});const suite=await fixtureSuite(path.join(out,'owner'),build);
const binary=path.join(out,'DiscoveryPreview'),cache=path.resolve('.build/cache/DiscoveryReopen');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(n=>n.endsWith('.swift.o')).map(n=>path.join(build,'AutoApproveCore.build',n)),
 'Tests/fixtures/discovery-preview.swift','-o',binary],{stdio:'inherit',timeout:300000});
const root=await mkdtemp('/private/tmp/aa-reopen-'),children=[],servers=[],sockets=new Set(),checks=[],metrics=[];
async function start(label,known,{manual=[],hints=[],candidates=[]}={}){
 const directory=path.join(root,label);await mkdir(directory);
 for(const [file,value]of [['web-known-peers.json',known],['web-peers.json',manual],['hints.json',hints],['candidates.json',candidates]])await writeFile(path.join(directory,file),JSON.stringify(value));
 const began=performance.now(),child=spawn(binary,[directory],{stdio:['ignore','ignore','pipe']});children.push(child);let ready,error='';child.stderr.on('data',v=>error+=v);
 await until(async()=>{try{ready=JSON.parse(await readFile(path.join(directory,'ready.json'),'utf8'));return true;}catch{return child.exitCode!==null;}},'Gateway start',15000);assert.ok(ready,error);
 return {...ready,began};
}
async function server(handler){const s=createServer(handler);servers.push(s);s.on('connection',socket=>{sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});await new Promise(resolve=>s.listen(0,'127.0.0.1',resolve));return 'http://127.0.0.1:'+s.address().port;}
function stream(url){return new Promise((resolve,reject)=>{
 let buffer='',done=false;const began=performance.now(),req=get(url,{agent:false},res=>{
  if(res.statusCode!==200){finish(null,{status:res.statusCode,ms:performance.now()-began});return;}
  res.setEncoding('utf8');res.on('data',part=>{buffer+=part;const line=buffer.split('\n').find(v=>v.startsWith('data: '));if(buffer.includes('\n\n')&&line)try{finish(null,{status:res.statusCode,ms:performance.now()-began,frame:JSON.parse(line.slice(6))});}catch(error){finish(error);}});
  res.on('error',error=>{if(!done)finish(error);});
 });
 const timer=setTimeout(()=>finish(Error('Stream opening timeout')),6000);
 function finish(error,value){if(done)return;done=true;clearTimeout(timer);req.destroy();error?reject(error):resolve(value);}req.on('error',error=>{if(!done)finish(error);});
});}
const known=(id,url,release,age=0)=>({id,name:'Synthetic saved Mac',address:url,urls:[url],port:Number(new URL(url).port),release,lastSeen:new Date(Date.now()-age).toISOString().replace(/\.\d+Z$/,'Z')});
try{
 const owner=await suite.start('owner'),state=(await json(owner.url+'/api/state')).value,id=state.sessions[0].session.id;
 let active=0,peak=0;const requests=[];
 const dead=await server((req,res)=>{requests.push({at:performance.now(),pinned:!!req.headers['x-autoapprove-node']});active++;peak=Math.max(peak,active);res.once('close',()=>active--);});
 const stale=Array.from({length:32},(_,index)=>({...known(randomUUID(),dead,state.release,(index+1)*60000),name:'Old '+index}));
 const target=known(owner.id,owner.url,state.release),records=[...stale,target];
 for(const mode of ['frame','stream']){
  const gateway=await start(mode,records,{hints:[dead,owner.url]});
  const blocked=await json(gateway.url+'/api/input?node='+owner.id,{requestID:randomUUID(),sessionID:id,kind:'enter'});assert.ok(blocked.status>=400);assert.equal((await suite.observe(owner)).inputs.length,0);
  const began=performance.now(),route=new URLSearchParams({node:owner.id,session:id,initial:'1'});
  const result=mode==='stream'?await stream(gateway.url+'/api/terminal/stream?'+route):await json(gateway.url+'/api/terminal?'+route);
  const frame=mode==='stream'?result.frame:result.value;
  metrics.push({case:mode,status:result.status,ms:performance.now()-began,screenReceived:typeof frame?.screen==='string'&&frame.screen.length>40000});
  if(!baseline){assert.equal(result.status,200);assert.equal(frame.sessionID,id);assert.ok(frame.screen.length>40000);}
 }
 checks.push('Saved/offline frame and SSE routes attempt the exact original immediately; pre-read POST does not deliver input');
 const bookmark=await start('bookmark',records,{manual:stale.slice(0,6),hints:[dead,owner.url]});
 // Occupy background inventory slots before the selected bookmark arrives.
 await json(bookmark.url+'/api/network');const startSelected=performance.now();
 let selected=(await json(bookmark.url+'/api/network?'+new URLSearchParams({initial:'1',node:owner.id}))).value;
 const ready=selected.nodes.find(n=>n.id===owner.id&&n.online&&n.state);
 metrics.push({case:'selected-bookmark',ms:performance.now()-startSelected,ready:!!ready});
 if(!baseline){assert.ok(ready,'Selected bookmark bypasses queued dead inventories');assert.ok(performance.now()-startSelected<1200);}
 checks.push('A selected bookmark has its own bounded inventory slot and replaces only its queued/negative GET');
 const batchTimes=[];
 for(let trial=0;trial<3;trial++){
  const gateway=await start('batch-'+trial,[stale[0],target]);
  let found=false;await until(async()=>{found=(await json(gateway.url+'/api/network')).value.nodes.some(n=>n.id===owner.id&&n.online);return found;},'Two-peer discovery',5000);
  batchTimes.push(performance.now()-gateway.began);
 }
 metrics.push({case:'one-stalled-neighbour',samplesMS:batchTimes});checks.push('A healthy metadata result is published independently of its stalled batch neighbour');
 const crowded=await start('crowded',records,{hints:[dead,owner.url]});const discoveryStart=performance.now();let found=false;
 while(performance.now()-discoveryStart<6000&&!found){found=(await json(crowded.url+'/api/network')).value.nodes.some(n=>n.id===owner.id&&n.online);if(!found)await wait(80);}
 metrics.push({case:'32-stale-known',found,ms:performance.now()-discoveryStart});
 if(!baseline){assert.ok(found,'The recently used Mac is checked before 32 stale identities');assert.ok(performance.now()-discoveryStart<2000);}
 checks.push('Recent saved identities precede stale peers while known URLs are excluded from passive blind probes');
 if(!baseline){
  assert.ok(requests.filter(v=>!v.pinned).length<=children.length,'A repeatedly failed saved address may be re-identified once per gateway, within its discovery cooldown');
  let metadataStarted=false;
  const slowMetadata=await server((req,res)=>{
   if(req.url==='/api/discovery'){metadataStarted=true;return;}
   const upstream=upstreamRequest(owner.url+req.url,{method:req.method,headers:{...req.headers,host:new URL(owner.url).host}},reply=>{res.useChunkedEncodingByDefault=false;res.writeHead(reply.statusCode,reply.headers);reply.on('error',()=>res.destroy());reply.pipe(res);});
   upstream.on('error',()=>res.destroy());res.on('close',()=>upstream.destroy());req.pipe(upstream);
  });
  const recent=await start('late-metadata-failure',[known(owner.id,slowMetadata,state.release)]);
  assert.equal((await stream(recent.url+'/api/terminal/stream?'+new URLSearchParams({node:owner.id,session:id}))).status,200);
  await until(()=>metadataStarted,'Metadata probe starts after the original read');await wait(1400);
  assert.ok((await json(recent.url+'/api/network')).value.nodes.some(n=>n.id===owner.id&&n.online),'A metadata timeout must not erase a recent verified original read');
  checks.push('A later metadata timeout cannot erase the recent exact-original read while normal inventories remain reachable');
  const wrongID=randomUUID();
  const wrong=await server((req,res)=>{const body=JSON.stringify({...state,id:wrongID});res.writeHead(200,{'Content-Length':Buffer.byteLength(body),'Content-Type':'application/json','X-AutoApprove-Node':wrongID,Connection:'close'});res.end(body);});
  const mismatch=await start('mismatch',[known(owner.id,wrong,state.release)]);
  assert.ok((await json(mismatch.url+'/api/terminal?'+new URLSearchParams({node:owner.id,session:id}))).status>=400);
  assert.ok((await stream(mismatch.url+'/api/terminal/stream?'+new URLSearchParams({node:owner.id,session:id}))).status>=400);
  const denied=(await json(mismatch.url+'/api/network?'+new URLSearchParams({initial:'1',node:owner.id}))).value;
  assert.ok(!denied.nodes.find(n=>n.id===owner.id)?.online);checks.push('A moved address with a different node cannot restore GET, SSE or selected inventory');
  const legacyID=randomUUID(),legacyRelease={version:'0.2.40',build:46,api:1};
  const legacy=await server((req,res)=>{const body=JSON.stringify({...state,id:legacyID,release:legacyRelease});res.writeHead(200,{'Content-Length':Buffer.byteLength(body),'Content-Type':'application/json',Connection:'close'});res.end(body);});
  const old=await start('legacy',[known(legacyID,legacy,legacyRelease)]);
  const response=(await json(old.url+'/api/network?'+new URLSearchParams({initial:'1',node:legacyID}))).value;
  assert.ok(response.nodes.some(n=>n.id===legacyID&&n.online));checks.push('Legacy selected inventory still requires its exact decoded node identity without a header');
  const tooEarly=await start('legacy-frame',[known(legacyID,legacy,legacyRelease)]);
  assert.ok((await json(tooEarly.url+'/api/terminal?'+new URLSearchParams({node:legacyID,session:id}))).status>=400);
  checks.push('An unverified legacy terminal without an identity header waits for normal discovery instead of exposing a guessed screen');
 }
 assert.equal((await suite.observe(owner)).inputs.length,0);
 const report={result:'PASS',baseline,metrics,checks:baseline?checks.map(v=>'Baseline measurement: '+v):checks,inputPostsToOriginal:0,knownAddressesBlindRequests:requests.filter(v=>!v.pinned).length,observedStalledPeerPeak:peak,
  scope:'Actual Swift Core on loopback with synthetic source, saved identities and stalls. No physical phone, VPN, full subnet or total app CPU measurement.'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();for(const socket of sockets)socket.destroy();for(const server of servers)await new Promise(resolve=>server.close(resolve));await suite.stop();await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));await rm(root,{recursive:true,force:true});}
