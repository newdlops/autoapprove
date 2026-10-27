// Actual isolated Core; completed keep-alives must not starve a fresh request.
import assert from 'node:assert/strict';
import net from 'node:net';
import {writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fixtureSuite,wait,until} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3),out=path.resolve(option('output')||'.runtime/lan-reliability-199/capacity'),baseline=process.argv.includes('--baseline');
const suite=await fixtureSuite(out,path.resolve(option('build')||'.build/network-stability/release')),clients=[],checks=[];let base,socket,headers='Host: localhost\r\n';
function open(){return new Promise((resolve,reject)=>{const u=new URL(base),s=net.connect(Number(u.port),u.hostname);s.once('connect',()=>{clients.push(s);resolve(s);});s.once('error',reject);});}
function read(socket,keep=true){return new Promise(resolve=>{
 let data=Buffer.alloc(0),done=false;const began=performance.now(),timer=setTimeout(()=>finish({error:'deadline'}),1000);
 function finish(value){if(done)return;done=true;clearTimeout(timer);socket.off('data',onData);socket.off('error',onError);socket.off('close',onClose);resolve({...value,ms:Math.round(performance.now()-began)});}
 function onError(e){finish({error:e.code||'socket'});}function onClose(){finish({error:'closed'});}
 function onData(part){data=Buffer.concat([data,part]);const at=data.indexOf('\r\n\r\n');if(at<0)return;const h=data.subarray(0,at).toString(),length=Number(h.match(/content-length:\s*(\d+)/i)?.[1]);if(Number.isFinite(length)&&data.length>=at+4+length)finish({status:Number(h.split(' ')[1])});}
 socket.on('data',onData);socket.once('error',onError);socket.once('close',onClose);
 socket.write('GET /api/discovery HTTP/1.1\r\n'+headers+'Connection: '+(keep?'keep-alive':'close')+'\r\n\r\n');
 });}
async function release(){for(const s of clients.splice(0))s.destroy();await wait(100);}
try{
 const node=await suite.start('owner',baseline?[]:['--capacity-gateway']);base=node.url;
 for(const target of baseline?['LAN']:['LAN','authenticated gateway']){
 if(target==='authenticated gateway'){
  base=node.gateway;const login=await fetch(base+'/auth/login',{method:'POST',headers:{Host:'capacity.tunnel-qa.invalid',Origin:'https://capacity.tunnel-qa.invalid','Content-Type':'application/json',Connection:'close'},body:JSON.stringify({key:'001234'})});
  assert.equal(login.status,200);await login.text();headers='Host: capacity.tunnel-qa.invalid\r\nCookie: '+login.headers.get('set-cookie').split(';')[0]+'\r\n';await wait(100);
 }
 const idle=await Promise.all(Array.from({length:32},async()=>{const s=await open();assert.equal((await read(s)).status,200);return s;}));
 const fresh=await open(),result=await read(fresh,false);fresh.destroy();
 if(baseline){assert.ok(result.error,'Old listener must reject a new read while 32 idle sockets remain');const report={baseline:true,reproduced:true,idle:32,fresh:result};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
 else{
  assert.equal(result.status,200);assert.ok(result.ms<700);await until(()=>idle.some(s=>s.destroyed),'An idle connection was actually released');checks.push({target,case:'32 completed keep-alives leave room for a fresh request by retiring idle work',ms:result.ms});
  const burst=await Promise.all(Array.from({length:4},async()=>{const s=await open(),r=await read(s);assert.equal(r.status,200);return r;}));checks.push({target,case:'Four concurrent fresh reads preserve bounded admission',maxMS:Math.max(...burst.map(r=>r.ms))});
  await release();const partial=await Promise.all(Array.from({length:32},async()=>{const s=await open();s.write('POST /api/action HTTP/1.1\r\n'+headers+'Content-Length: 100\r\n');return s;}));await wait(75);
  const rejected=await open(),busy=await read(rejected,false);rejected.destroy();assert.ok(busy.error);assert.ok(partial.every(s=>!s.destroyed),'Never evict an in-progress request');checks.push({target,case:'The 32-request bound remains; incomplete active requests are preserved'});
  await release();
  if(target==='authenticated gateway')continue;
  socket=await open();let socketClosed=false;socket.on('close',()=>socketClosed=true);
  await new Promise((resolve,reject)=>{
   let text='';const timer=setTimeout(()=>reject(Error('Upgrade deadline')),2000),data=part=>{text+=part.toString();if(!text.includes('\r\n\r\n'))return;clearTimeout(timer);socket.off('data',data);try{assert.match(text,/^HTTP\/1.1 101 /);resolve();}catch(e){reject(e);}};
   socket.on('data',data);socket.once('error',reject);socket.write('GET /api/input/socket HTTP/1.1\r\nHost: '+new URL(base).host+'\r\nOrigin: '+base+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: MDEyMzQ1Njc4OWFiY2RlZg==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: autoapprove-input.v1\r\n\r\n');
  });
  const state=await(await fetch(base+'/api/state',{headers:{Connection:'close'}})).json(),session=state.sessions[0].session;
  const stream=suite.stream(base+'/api/terminal/stream?'+new URLSearchParams({session:session.id}));await stream.event(e=>e.type==='screen');
  const keep=await Promise.all(Array.from({length:30},async()=>{const s=await open();assert.equal((await read(s)).status,200);return s;}));
  const extra=await open(),live=await read(extra,false);extra.destroy();assert.equal(live.status,200);assert.equal(socketClosed,false);assert.equal(socket.destroyed,false);
  await stream.event(e=>e.type==='screen'||e.type==='alive',1,5000);assert.equal(socketClosed,false);stream.close();socket.destroy();assert.ok(keep.some(s=>s.destroyed));checks.push({case:'Active original output and WebSocket upgrade survive idle eviction; no input binding or application frames sent'});
 }
 }
 if(!baseline){const report={passed:true,checks,scope:'Actual compiled LAN Core and PIN-authenticated gateway, synthetic original, 32-slot pressure on loopback only; no user CLI or original input'};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
}finally{socket?.destroy();await release();await suite.stop();}
