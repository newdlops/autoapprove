// The real Core gateway talks to a controllable HTTP peer on loopback. Only
// transport responses are synthetic; no installed app or original terminal is used.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {randomUUID} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fixtureSuite,json,wait,until} from './terminal-continuity-fixture.mjs';
const option=(name,fallback)=>process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const out=path.resolve(option('output','.runtime/peer-http-reuse/current')),baseline=process.argv.includes('--baseline');
await mkdir(out,{recursive:true,mode:0o700});
const suite=await fixtureSuite(out),sockets=new Set(),terminalRequests=[],checks=[],metrics=[];
let peerState,mode='normal',serial=0,held=[];
const peerID=randomUUID();
const server=createServer((request,response)=>{
 const url=new URL(request.url,'http://localhost');
 if(url.pathname==='/api/discovery'){
  response.setHeader('X-AutoApprove-Node',peerID);
  response.end(JSON.stringify({service:'autoapprove',version:1,id:peerID,name:'HTTP reuse QA',urls:[],port:server.address().port,release:peerState.release}));return;
 }
 if(['/api/state','/api/inventory'].includes(url.pathname)){
  response.setHeader('X-AutoApprove-Node',peerID);response.end(JSON.stringify(peerState));return;
 }
 if(url.pathname!=='/api/terminal'&&url.pathname!=='/api/input'){response.writeHead(404);response.end('{}');return;}
 terminalRequests.push({port:request.socket.remotePort,method:request.method,node:request.headers['x-autoapprove-node'],target:request.url});
 const body=JSON.stringify({marker:++serial,unicode:'한글 👩🏽‍💻 é',query:url.searchParams.get('session')});
 response.setHeader('Content-Type','application/json');
 if(mode!=='missing-node')response.setHeader('X-AutoApprove-Node',mode==='wrong-node'?randomUUID():peerID);
 if(mode==='reject'){response.writeHead(403,{'Connection':'close'});response.end('{"error":"Denied"}');return;}
 if(mode==='post-drop'&&request.method==='POST'){request.socket.destroy();return;}
 if(mode==='stall'){held.push({response,body});return;}
 if(mode==='unchanged'){response.writeHead(304,{'ETag':'"same"'});response.end();return;}
 if(mode==='gzip'){
  const compressed=gzipSync(body);response.writeHead(200,{'Content-Encoding':'gzip','Content-Length':compressed.length});response.end(compressed);return;
 }
 if(mode==='truncate'||mode==='truncate-once'){
  if(mode==='truncate-once')mode='normal';
  response.writeHead(200,{'Content-Length':Buffer.byteLength(body)+50,'Connection':'keep-alive'});
  response.write(body.slice(0,10));setTimeout(()=>request.socket.destroy(),10);return;
 }
 if(mode==='bad-gzip'){
  response.writeHead(200,{'Content-Encoding':'gzip','Content-Length':3});response.end('bad');return;
 }
 if(mode==='close')response.setHeader('Connection','close');
 if(mode==='fragment'){
  response.writeHead(200,{'Content-Length':Buffer.byteLength(body)});
  const bytes=Buffer.from(body);response.write(bytes.subarray(0,17));setTimeout(()=>response.end(bytes.subarray(17)),5);return;
 }
 response.end(body);
});
server.keepAliveTimeout=5000;
server.on('connection',socket=>{sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let node;
const finite=async(query='literal + & 한글')=>{
 const begin=performance.now(),reply=await json(node.url+'/api/terminal?'+new URLSearchParams({node:peerID,session:query}));
 return {...reply,ms:performance.now()-begin};
};
try{
 node=await suite.start('gateway');peerState=(await json(node.url+'/api/state')).value;
 peerState={...peerState,id:peerID,name:'HTTP reuse QA',webURLs:[],webPort:server.address().port,sessions:[],snapshot:{...peerState.snapshot,sessions:[],events:[]}};
 assert.equal((await json(node.url+'/api/peers',{address:'http://127.0.0.1:'+server.address().port})).status,200);
 for(let run=0;run<3;run++){
  const start=terminalRequests.length,times=[];let previous=serial;
  for(let index=0;index<40;index++){
   const result=await finite();assert.equal(result.status,200);assert.ok(result.value.marker>previous);previous=result.value.marker;
   assert.equal(result.value.query,'literal + & 한글');assert.equal(result.value.unicode,'한글 👩🏽‍💻 é');times.push(result.ms);
  }
  const rows=terminalRequests.slice(start),connections=new Set(rows.map(row=>row.port)).size;
  assert.ok(rows.every(row=>row.method==='GET'&&row.node===peerID));times.sort((a,b)=>a-b);
  metrics.push({reads:40,connections,medianMS:times[20],p95MS:times[37]});
  if(baseline)assert.equal(connections,40);else assert.ok(connections>=2&&connections<=3,'Mac read-only relay must reuse verified finite HTTP connections and retire them after bounded reads');
 }
 checks.push('Fresh exact Unicode/query response and node identity on every sequential read; connection retirement remains bounded');
 if(!baseline){
  mode='fragment';const fragmented=await finite();assert.equal(fragmented.status,200);assert.equal(fragmented.value.unicode,'한글 👩🏽‍💻 é');
  mode='normal';assert.equal((await finite()).status,200);
  checks.push('Fragmented UTF-8 finite bodies do not leak into the next response');
  mode='gzip';assert.equal((await finite()).value.unicode,'한글 👩🏽‍💻 é');
  mode='unchanged';const unchanged=await fetch(node.url+'/api/terminal?'+new URLSearchParams({node:peerID,session:'conditional'}));
  assert.equal(unchanged.status,304);assert.equal((await unchanged.arrayBuffer()).byteLength,0);
  mode='normal';assert.equal((await finite()).status,200);
  checks.push('Complete gzip and body-free 304 preserve the next response boundary');
  for(const next of ['wrong-node','reject','bad-gzip']){
   mode=next;const before=terminalRequests.length,result=await finite();assert.ok(result.status>=400);assert.equal(terminalRequests.length,before+1,'Identity/permission/protocol failures are never retried');
   mode='normal';assert.equal((await finite()).status,200);
  }
  checks.push('Wrong node, permission denial and corrupt gzip retire the transport without retrying the rejected read');
  mode='close';const closeStart=terminalRequests.length;await finite();await finite();
  assert.notEqual(terminalRequests[closeStart].port,terminalRequests[closeStart+1].port);
  mode='missing-node';const legacyStart=terminalRequests.length;await finite();await finite();
  assert.notEqual(terminalRequests[legacyStart].port,terminalRequests[legacyStart+1].port);
  mode='normal';await finite();
  checks.push('Connection: close and legacy responses without exact node identity are never retained');
  const oldPort=terminalRequests.at(-1).port;
  for(const socket of sockets)socket.destroy();await wait(30);
  assert.equal((await finite()).status,200);assert.notEqual(terminalRequests.at(-1).port,oldPort);
  checks.push('An idle peer disconnect is discarded before the next read');
  mode='truncate-once';const retryStart=terminalRequests.length,retried=await finite('retry + 한글');
  assert.equal(retried.status,200);assert.equal(retried.value.query,'retry + 한글');
  assert.equal(terminalRequests.length,retryStart+2,'Only one fresh GET fallback after a truncated reused response');
  assert.ok(terminalRequests.slice(retryStart).every(row=>row.node===peerID&&row.method==='GET'&&row.target.includes('retry')));
  assert.notEqual(terminalRequests[retryStart].port,terminalRequests[retryStart+1].port);
  assert.equal((await finite()).status,200);
  checks.push('A truncated reused GET makes exactly one fresh fallback with the exact node and query');
  const lastPort=terminalRequests.at(-1).port;await wait(4300);assert.equal((await finite()).status,200);
  assert.notEqual(terminalRequests.at(-1).port,lastPort);
  checks.push('Idle transports expire before the peer five-second keepalive deadline');
  mode='stall';const heldStart=terminalRequests.length;
  const controller=new AbortController();const pending=fetch(node.url+'/api/terminal?'+new URLSearchParams({node:peerID,session:'cancelled'}),{signal:controller.signal}).catch(()=>null);
  await until(()=>terminalRequests.length>heldStart,'A real forwarded read is pending');const cancelledPort=terminalRequests.at(-1).port;
  controller.abort();await pending;
  await until(()=>![...sockets].some(socket=>socket.remotePort===cancelledPort),'Cancellation releases its upstream before the peer replies');
  mode='normal';for(const {response} of held)response.destroy();held=[];
  assert.equal((await finite()).status,200);
  checks.push('Cancelling a downstream read closes its busy upstream without poisoning the next caller');
  mode='stall';const concurrentStart=held.length;
  const concurrent=Array.from({length:10},(_,index)=>finite('concurrent-'+index));
  await until(()=>held.length===concurrentStart+10,'Ten independent reads are actually pending');
  mode='normal';const waiting=held.splice(0);for(const {response,body}of waiting)response.end(body);
  const delivered=await Promise.all(concurrent);
  for(let index=0;index<delivered.length;index++){assert.equal(delivered[index].status,200);assert.equal(delivered[index].value.query,'concurrent-'+index);}
  await until(()=>sockets.size<=4,'Retain no more than four idle upstream sockets after a burst');
  checks.push('Concurrent reads retain exact caller responses and at most four idle transports');
  mode='post-drop';const postStart=terminalRequests.length;
  const post=await json(node.url+'/api/input?node='+peerID,{requestID:randomUUID(),sessionID:'synthetic',kind:'text',text:'never-replay'});
  assert.ok(post.status>=400);assert.equal(terminalRequests.length,postStart+1);assert.equal(terminalRequests.at(-1).method,'POST');
  mode='normal';assert.equal((await finite()).status,200);
  checks.push('A dropped POST is sent exactly once on a separate connection');
  await suite.control(node,{stopWeb:true});await until(()=>sockets.size===0,'Listener stop releases idle upstream transports');
  checks.push('Service stop releases retained upstream connections');
 }
 const report={result:'PASS',baseline,metrics,checks,scope:'Actual release Core gateway and real loopback HTTP sockets; synthetic peer responses. Not physical phone/VPN or whole-program CPU.'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report,null,2));
}finally{
 for(const {response} of held)response.destroy();for(const socket of sockets)socket.destroy();
 await new Promise(resolve=>server.close(resolve));await suite.stop();
}
