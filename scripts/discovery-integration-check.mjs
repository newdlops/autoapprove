// Real Swift HTTP + isolated synthetic peers on loopback. No physical LAN scan or broadcast.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {createServer} from 'node:http';
import {randomUUID} from 'node:crypto';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';

const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const root=await mkdtemp('/private/tmp/aa-discovery-'),children=[],servers=[],checks=[];
const output=path.resolve('dist/qa/discovery');await mkdir(output,{recursive:true});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const read=async file=>{try{return JSON.parse(await readFile(file,'utf8'));}catch{return null;}};
const binary=path.join(root,'DiscoveryPreview');
const cache=path.resolve('.build/cache/DiscoveryPreview');await mkdir(cache,{recursive:true});
const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/discovery-preview.swift','-o',binary],{stdio:'inherit'});
const policy=path.join(root,'DiscoveryPolicy');
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/AutoApproveCoreTests/DiscoveryTests.swift','Tests/fixtures/discovery-policy-check.swift','-o',policy],{stdio:'inherit'});
execFileSync(policy,[],{stdio:'inherit'});
async function fixture(label,{candidates=[],hints=[],known=[]}={}) {
  const directory=path.join(root,label);await mkdir(directory,{recursive:true});
  for(const [file,value] of [['candidates.json',candidates],['hints.json',hints],['web-known-peers.json',known]])await writeFile(path.join(directory,file),JSON.stringify(value));
  const started=performance.now(),child=spawn(binary,[directory],{stdio:['ignore','ignore','pipe']});children.push(child);let error='';child.stderr.on('data',data=>error+=data);
  let ready;for(let i=0;i<200&&!ready;i++){ready=await read(path.join(directory,'ready.json'));if(child.exitCode!==null)throw Error(error);if(!ready)await wait(50);}
  assert.ok(ready,'Discovery fixture startup: '+error);return {...ready,directory,child,started};
}
async function get(gateway,route){const response=await fetch(gateway.url+route,{signal:AbortSignal.timeout(10000)});return {status:response.status,data:await response.json()};}
async function online(gateway,id,timeout=5000){const deadline=performance.now()+timeout;while(performance.now()<deadline){const result=await get(gateway,'/api/network');if(result.data.nodes.some(node=>node.id===id&&node.online))return performance.now()-gateway.started;await wait(50);}throw Error('Peer not found within '+timeout+' ms');}
async function fake(template,{unrelated=false,delay=0,traffic=null}={}) {
  const id=randomUUID(),stats={requests:[],active:0,peak:0,stateReads:0,posts:0},sockets=new Set();let url,advertised=[],failState=false,dropPost=false;
  const server=createServer(async(req,res)=>{
    stats.requests.push({at:performance.now(),method:req.method,path:req.url});stats.active++;stats.peak=Math.max(stats.peak,stats.active);let ended=false;
    if(traffic){traffic.times.push(performance.now());traffic.active++;traffic.peak=Math.max(traffic.peak,traffic.active);}
    const finish=()=>{if(!ended){ended=true;stats.active--;if(traffic)traffic.active--;}};res.on('close',finish);res.on('finish',finish);
    if(req.method==='POST'){stats.posts++;if(dropPost){req.socket.destroy();return;}}
    if(req.url==='/api/state'){stats.stateReads++;if(failState){req.socket.destroy();return;}}
    if(delay)await wait(delay);
    const body=JSON.stringify(unrelated?{service:'unrelated',version:1}:req.url==='/api/discovery'?{service:'autoapprove',version:1,id,name:'Synthetic peer',urls:advertised.length?advertised:[url],port:new URL(url).port*1,release:template.release}:{...template,id,name:'Synthetic peer',webURLs:advertised.length?advertised:[url],webPort:new URL(url).port*1});
    res.writeHead(200,{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body),Connection:'close'});res.end(body);
  });
  server.on('connection',socket=>{sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});
  await new Promise(resolve=>server.listen(0,unrelated?'0.0.0.0':'127.0.0.1',resolve));servers.push({server,sockets});url='http://127.0.0.1:'+server.address().port;
  return {id,url,stats,setURLs:value=>{advertised=value;},failState:()=>{failState=true;},dropPost:()=>{dropPost=true;}};
}
try {
  const bootstrap=await fixture('bootstrap'),template=(await get(bootstrap,'/api/state')).data;
  const peer=await fake(template,{delay:150});
  const known=[{id:peer.id,name:'Known synthetic peer',address:peer.url,urls:[peer.url],port:new URL(peer.url).port*1,release:template.release,lastSeen:new Date().toISOString().replace(/\.\d+Z$/,'Z')}];
  const warm=await fixture('warm',{known,candidates:Array.from({length:512},(_,i)=>'http://127.2.'+Math.floor(i/250)+'.'+(i%250+1)+':65530')});
  const foundMs=await online(warm,peer.id);console.log('Cached peer discovery: '+Math.round(foundMs)+' ms');assert.ok(foundMs<2000,'A cached peer must bypass the subnet cursor and old 2-second startup delay: '+Math.round(foundMs)+' ms');
  checks.push({check:'Verified cached peer reconnects before scanning 512 unrelated candidates',foundMs:Math.round(foundMs)});
  // Let the three-second successful inventory cache expire before checking
  // that concurrent browsers coalesce into one fresh upstream request.
  await wait(3200);const before=peer.stats.stateReads;
  const dashboards=await Promise.all(Array.from({length:16},()=>get(warm,'/api/network')));
  assert.ok(dashboards.every(result=>result.data.nodes.some(node=>node.id===peer.id&&node.online)));assert.equal(peer.stats.stateReads-before,1);
  checks.push({check:'16 simultaneous browsers share one exact peer state request',upstreamReads:peer.stats.stateReads-before});
  const persisted=await read(path.join(warm.directory,'web-known-peers.json'));assert.ok(persisted.some(row=>row.id===peer.id));assert.ok(persisted.every(row=>!('snapshot'in row)&&!('sessions'in row)));
  warm.child.kill();await wait(300);
  await rm(path.join(warm.directory,'ready.json'));const restartStarted=performance.now();
  const restarted=spawn(binary,[warm.directory],{stdio:['ignore','ignore','pipe']});children.push(restarted);restarted.stderr.resume();
  let ready;for(let i=0;i<200&&!ready;i++){ready=await read(path.join(warm.directory,'ready.json'));if(!ready)await wait(50);}
  assert.ok(ready);const restartMs=await online({...ready,started:restartStarted},peer.id);console.log('Cached peer restart: '+Math.round(restartMs)+' ms');assert.ok(restartMs<2000,'Cached restart: '+Math.round(restartMs)+' ms');
  checks.push({check:'Automatically saved identity/address survives restart; no terminal content is persisted',restartMs:Math.round(restartMs)});
  const traffic={times:[],active:0,peak:0},wire=await Promise.all(Array.from({length:16},()=>fake(template,{unrelated:true,delay:350,traffic})));
  const addresses=[...wire.map(peer=>peer.url),...Array.from({length:496},(_,i)=>'http://127.2.'+Math.floor(i/250)+'.'+(i%250+1)+':65530')];
  const limited=await fixture('limited',{candidates:addresses,hints:wire.map(peer=>peer.url)});await wait(6500);
  const times=traffic.times.sort((a,b)=>a-b);let peakRate=0;
  for(const at of times)peakRate=Math.max(peakRate,times.filter(time=>time>=at&&time<at+1000).length);
  console.log(JSON.stringify({trafficRequests:times.length,peakRate,peakConcurrent:traffic.peak}));
  assert.ok(times.length>4&&times.length<30);assert.ok(peakRate<=4,'Discovery wire rate must stay bounded');assert.ok(traffic.peak<=2,'Discovery must use at most two sockets');
  assert.ok((await get(limited,'/api/network')).data.nodes.length===1,'Unrelated HTTP replies must not be enrolled');
  checks.push({check:'512-address fallback and passive hints stay bounded without broadcast',requests:times.length,peakPerSecond:peakRate,peakConcurrent:traffic.peak});
  const backup=await fake(template),primary=await fake(template);primary.setURLs([backup.url]);
  // Both routes below intentionally identify the same synthetic node.
  const routeID=primary.id;
  const proxy=createServer(async(req,res)=>{const data=await get({url:backup.url},req.url);data.data.id=routeID;const body=JSON.stringify(data.data);res.writeHead(200,{'Content-Length':Buffer.byteLength(body),Connection:'close'});res.end(body);});
  const proxySockets=new Set();proxy.on('connection',socket=>{proxySockets.add(socket);socket.on('close',()=>proxySockets.delete(socket));});await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));servers.push({server:proxy,sockets:proxySockets});const backupURL='http://127.0.0.1:'+proxy.address().port;primary.setURLs([backupURL]);
  const routed=await fixture('routes',{known:[{...known[0],id:routeID,address:primary.url,urls:[primary.url,backupURL],port:new URL(primary.url).port*1}]});await online(routed,routeID);await wait(900);primary.failState();
  const recovered=await get(routed,'/api/network');assert.ok(recovered.data.nodes.some(node=>node.id===routeID&&node.online));
  checks.push({check:'Read-only state request recovers over a second exact-identity route',recovered:true});
  const uncertain=await fake(template);uncertain.dropPost();const once=await fixture('once',{known:[{...known[0],id:uncertain.id,address:uncertain.url,urls:[uncertain.url],port:new URL(uncertain.url).port*1}]});await online(once,uncertain.id);
  const response=await fetch(once.url+'/api/action?node='+uncertain.id,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'pause',paused:true,requestID:randomUUID()})});assert.ok(response.status>=400);assert.equal(uncertain.stats.posts,1);
  checks.push({check:'An ambiguous POST is transmitted once and is never replayed during route recovery',posts:uncertain.stats.posts});
  // Distinct address namespaces exercise the same lane scheduler on loopback.
  // Physical Wi-Fi/Ethernet enumeration and interface binding are covered by the policy checks.
  const stalledLane=await fake(template,{unrelated:true,delay:5000}),wifiFound=await fake(template),ethernetFound=await fake(template);
  const wifiAddress=address=>address.replace('127.0.0.1','localhost');
  const both=await fixture('two-lanes',{candidates:[wifiAddress(stalledLane.url),wifiAddress(wifiFound.url),...Array.from({length:250},(_,i)=>'http://localhost:'+(64000+i)),ethernetFound.url]});
  const ethernetMs=await online(both,ethernetFound.id,2500);
  assert.ok(ethernetMs<2000,'A stalled first lane and 252 queued candidates cannot block the other LAN: '+ethernetMs);
  const wifiMs=await online(both,wifiFound.id,3500);
  assert.ok(wifiMs<3500,'Finding Ethernet cannot slow the still-unresolved Wi-Fi lane to five-second blind probes: '+wifiMs);
  checks.push({check:'Two search lanes discover both peers despite a stalled first address and a long first-lane queue',ethernetMs:Math.round(ethernetMs),wifiMs:Math.round(wifiMs)});
  const selected=(await get(both,'/api/network?initial=1&node='+wifiFound.id)).data;
  assert.ok(selected.nodes.some(node=>node.id===wifiFound.id&&node.online));
  const page=await fetch(both.url+'/?webNode='+both.id);assert.equal(page.status,200);assert.match(await page.text(),/AutoApprove/);
  checks.push({check:'Both discovered nodes remain in one gateway and the selected peer page keeps the original origin',pageStatus:page.status});
  await writeFile(path.join(output,'report.json'),JSON.stringify({result:'PASS',checks},null,2));console.log(JSON.stringify({result:'PASS',checks},null,2));
} finally {
  for(const child of children)if(child.exitCode===null)child.kill();
  for(const {server,sockets} of servers){for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));}
  await wait(150);await rm(root,{recursive:true,force:true});
}
