// Real Core listener, synthetic originals only. Compare --baseline before
// rebuilding; no installed app, user input, screen capture or system changes.
import assert from 'node:assert/strict';
import {Agent,request} from 'node:http';
import {connect} from 'node:net';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {fixtureSuite,wait,until} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const out=path.resolve(option('output')||'dist/qa/http-reuse'),baseline=process.argv.includes('--baseline');
await mkdir(out,{recursive:true});
const suite=await fixtureSuite(out),checks=[],metrics=[];
const agents=[],rawSockets=[];
function agent(){const a=new Agent({keepAlive:true,maxSockets:1,maxFreeSockets:1});agents.push(a);return a;}
function read(url,a,headers={},method='GET',body){
 return new Promise((resolve,reject)=>{
  const start=performance.now();let port;
  const req=request(url,{agent:a,method,headers},res=>{
   const chunks=[];res.on('data',v=>chunks.push(v));res.on('error',reject);res.on('end',()=>resolve({status:res.statusCode,headers:res.headers,body:Buffer.concat(chunks),port,ms:performance.now()-start}));
  });
  req.on('socket',socket=>{const capture=()=>port=socket.localPort;if(socket.connecting)socket.once('connect',capture);else capture();});
  req.on('error',reject);req.setTimeout(12000,()=>req.destroy(new Error('Read deadline')));req.end(body);
 });
}
async function raw(node){
 const socket=connect(Number(new URL(node.url).port),'127.0.0.1');rawSockets.push(socket);
 await new Promise((resolve,reject)=>{socket.once('connect',resolve);socket.once('error',reject);});
 const value={socket,buffer:Buffer.alloc(0),ended:false};socket.on('data',part=>value.buffer=Buffer.concat([value.buffer,part]));socket.on('close',()=>value.ended=true);socket.on('error',()=>{});
 value.send=text=>socket.write(text);
 value.response=async()=>{
  let response;
  await until(()=>{
   const boundary=value.buffer.indexOf('\r\n\r\n');if(boundary<0)return value.ended;
   const head=value.buffer.subarray(0,boundary).toString(),status=Number(head.split(' ')[1]),length=status===304?0:Number(head.match(/\r\nContent-Length: (\d+)/i)?.[1]||0);
   if(value.buffer.length<boundary+4+length)return value.ended;
   response={status,head,body:value.buffer.subarray(boundary+4,boundary+4+length)};value.buffer=value.buffer.subarray(boundary+4+length);return true;
  },'Complete finite response');
  assert.ok(response,'Connection ended before a complete response');return response;
 };
 return value;
}
const wire=(node,path='/' ,extra='',version='1.1')=>`GET ${path} HTTP/${version}\r\nHost: ${new URL(node.url).host}\r\n${extra}\r\n`;
try{
 const node=await suite.start('http-reuse');
 // Three independent batches also cross the bounded request retirement point.
 for(let run=0;run<3;run++){
  const a=agent(),ports=new Set(),times=[];let bytes=0;
  for(let i=0;i<96;i++){
   const reply=await read(node.url+'/api/discovery',a);assert.equal(reply.status,200);assert.equal(JSON.parse(reply.body).id,node.id);assert.equal(reply.headers['x-autoapprove-node'],node.id);
   ports.add(reply.port);times.push(reply.ms);bytes+=reply.body.length;
  }
  a.destroy();times.sort((a,b)=>a-b);metrics.push({requests:96,connections:ports.size,medianMS:times[48],p95MS:times[91],bodyBytes:bytes});
  if(baseline)assert.equal(ports.size,96);else assert.equal(ports.size,3,'Retire each connection after exactly 32 complete requests');
 }
 checks.push(baseline?'96 sequential read-only requests each open a new connection':'96 sequential read-only requests retain fresh identity; bounded connections retire after 32 requests');
 if(!baseline){
  const a=agent(),first=await read(node.url+'/api/inventory',a,{'Accept-Encoding':'gzip'});
  assert.equal(first.headers['content-encoding'],'gzip');
  const same=await read(node.url+'/api/inventory',a,{'Accept-Encoding':'gzip','If-None-Match':first.headers.etag});
  assert.equal(same.status,304);assert.equal(same.body.length,0);assert.equal(first.port,same.port);
  const changed=await read(node.url+'/api/discovery',a);assert.equal(changed.port,first.port);assert.equal(JSON.parse(changed.body).id,node.id);
  checks.push('gzip Content-Length and body-free 304 preserve the next response boundary on one socket');
  const denied=await read(node.url+'/api/discovery',a,{Origin:'http://foreign.example'});assert.equal(denied.port,first.port);assert.equal(denied.status,403);assert.equal(denied.headers.connection,'close');
  const recovered=await read(node.url+'/api/discovery',a);assert.equal(recovered.status,200);assert.notEqual(recovered.port,first.port);
  checks.push('Origin is checked again on reuse; a rejected request closes its socket and a new read succeeds');
  const pinned=agent();await read(node.url+'/api/discovery',pinned);
  const wrong=await read(node.url+'/api/discovery',pinned,{'X-AutoApprove-Node':'wrong-node'});assert.equal(wrong.status,409);assert.equal(wrong.headers.connection,'close');
  checks.push('Reusing TCP never reuses the previous request original-node authorization');
  for(const [extra,version]of [['Connection: close\r\n','1.1'],['Connection: keep-alive, CLOSE\r\n','1.1'],['Connection: keep-alive\r\n','1.0']]){
   const c=await raw(node);c.send(wire(node,'/api/discovery',extra,version));const reply=await c.response();assert.match(reply.head,/Connection: close\r?$/im);await until(()=>c.ended,'Legacy close');
  }
  checks.push('HTTP/1.0 and case-insensitive close tokens retain single-response FIN semantics');
  const fragmented=await raw(node),packet=wire(node,'/api/discovery');
  for(const part of [packet.slice(0,5),packet.slice(5,-3),packet.slice(-3)]){fragmented.send(part);await wait(10);}assert.equal((await fragmented.response()).status,200);
  fragmented.send(wire(node,'/api/discovery'));assert.equal((await fragmented.response()).status,200);fragmented.socket.destroy();
  checks.push('Fragmented headers and sequential reads share exactly one pending receive');
  for(const request of [wire(node,'/api/discovery')+wire(node,'/api/discovery'),wire(node,'/api/discovery','Content-Length: 0\r\nContent-Length: 0\r\n'),wire(node,'/api/discovery','Transfer-Encoding: chunked\r\n')]){
   const c=await raw(node);c.send(request);assert.ok((await c.response()).status>=400);await until(()=>c.ended,'Malformed request retires');
  }
  checks.push('Pipelining, duplicate lengths and unsupported transfer codings never become a second dispatched request');
  const idle=await raw(node);idle.send(wire(node,'/api/discovery'));assert.equal((await idle.response()).status,200);const idleStart=performance.now();await until(()=>idle.ended,'Idle reuse deadline',7000);assert.ok(performance.now()-idleStart>=4500);
  checks.push('Unused keep-alive releases its connection slot after five seconds');
  const beforeInput=(await suite.observe(node)).inputs.length;
  const inputAgent=agent(),ready=await read(node.url+'/api/discovery',inputAgent),payload=Buffer.from(JSON.stringify({sessionID:'absent',kind:'enter'}));
  const input=await read(node.url+'/api/input',inputAgent,{'Content-Type':'application/json','Content-Length':payload.length},'POST',payload);
  assert.equal(input.port,ready.port);assert.ok(input.status>=400);assert.equal(input.headers.connection,'close');assert.equal((await suite.observe(node)).inputs.length,beforeInput);
  checks.push('A POST on a reused socket is handled once and closes; no input is retried');
  const state=JSON.parse((await read(node.url+'/api/state',inputAgent)).body),id=state.sessions[0].session.id;
  const frame=JSON.parse((await read(node.url+'/api/terminal?session='+encodeURIComponent(id),inputAgent)).body);
  const valid=Buffer.from(JSON.stringify({requestID:randomUUID(),sessionID:id,revision:frame.revision,kind:'text',text:'REUSE-ONE-SYNTHETIC-INPUT'}));
  const sent=await read(node.url+'/api/input',inputAgent,{'Content-Type':'application/json','Content-Length':valid.length},'POST',valid);
  assert.equal(sent.status,200);assert.equal(sent.headers.connection,'close');await until(async()=>(await suite.observe(node)).inputs.length===beforeInput+1,'One synthetic input');
  await read(node.url+'/api/discovery',inputAgent);await wait(150);assert.equal((await suite.observe(node)).inputs.length,beforeInput+1);
  checks.push('One explicit synthetic input on a warm socket reaches its exact original once; later reads never replay it');
  const stateAgent=agent(),oldState=await read(node.url+'/api/state',stateAgent);
  const pause=Buffer.from(JSON.stringify({requestID:randomUUID(),action:'pause',paused:true}));
  assert.equal((await read(node.url+'/api/action',agent(),{'Content-Type':'application/json','Content-Length':pause.length},'POST',pause)).status,200);
  const newState=await read(node.url+'/api/state',stateAgent);assert.equal(newState.port,oldState.port);assert.equal(JSON.parse(oldState.body).snapshot.paused,false);assert.equal(JSON.parse(newState.body).snapshot.paused,true);
  checks.push('A reused read reflects a real intervening state change instead of caching the prior result');
  const stopped=await raw(node);stopped.send(wire(node,'/api/discovery'));await stopped.response();await suite.control(node,{stopWeb:true});await until(()=>stopped.ended,'Listener stop releases reused sockets');
  checks.push('Stopping the web listener closes idle persistent connections');
 }
 const report={result:'PASS',baseline,metrics,checks,scope:'Actual Core over loopback with synthetic originals. Connection counts and finite response timings, not physical phone/VPN or total app CPU.'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{for(const a of agents)a.destroy();for(const s of rawSockets)s.destroy();await suite.stop();}
