// Project-invoked, short-lived Unix socket fixture. Never starts a real Codex
// server, connects to user conversations, or changes system/OS permissions.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {spawn,execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,rm,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const opt=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(opt('build')||'.build/network-stability/release'),out=path.resolve(opt('output')||'.runtime/codex-goal-protocol');
await mkdir(out,{recursive:true});const binary=out+'/GoalProtocolCheck';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/GoalProtocolCheck'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-goal-protocol.swift','-o',binary],{stdio:'inherit',timeout:180000});
const home=await mkdtemp('/private/tmp/aa-goal-'),socketDir=home+'/app-server-control',thread='00000000-0000-4000-8000-000000000209';await mkdir(socketDir);
let mode,goal,reads,writes,errors=[];const sockets=new Set(),server=createServer();
server.on('upgrade',(request,socket)=>{
 sockets.add(socket);socket.on('close',()=>sockets.delete(socket));socket.on('error',()=>{});
 const accept=createHash('sha1').update(request.headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
 socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n');let buffer=Buffer.alloc(0);
 const reply=value=>{const body=Buffer.from(JSON.stringify(value)),head=body.length<126?Buffer.from([0x81,body.length]):Buffer.from([0x81,126,body.length>>8,body.length&255]);socket.write(Buffer.concat([head,body]));};
 socket.on('data',bytes=>{buffer=Buffer.concat([buffer,bytes]);try{while(buffer.length>=2){let size=buffer[1]&127,offset=2;if(size===126){if(buffer.length<4)return;size=buffer.readUInt16BE(2);offset=4;}else if(size===127){if(buffer.length<10)return;size=Number(buffer.readBigUInt64BE(2));offset=10;}assert.ok(size<256000);assert.ok(buffer[1]&128);if(buffer.length<offset+4+size)return;const mask=buffer.subarray(offset,offset+4),body=Buffer.from(buffer.subarray(offset+4,offset+4+size));buffer=buffer.subarray(offset+4+size);for(let i=0;i<body.length;i++)body[i]^=mask[i%4];const value=JSON.parse(body);if(!value.id)continue;let result={};
  if(value.method==='initialize')result={userAgent:'synthetic-goal-fixture'};
  else {assert.equal(value.params.threadId,thread);
   if(value.method==='thread/read')result={thread:{id:thread,cwd:home,source:'cli',status:{type:'idle'}}};
   else if(value.method==='thread/goal/get'){reads++;if(mode==='replaced'&&reads===2)goal={...goal,objective:'Different Goal',createdAt:200};result={goal};}
   else if(value.method==='thread/goal/set'){assert.equal(value.params.origin,'user');assert.equal(value.params.status,'active');assert.deepEqual(Object.keys(value.params).sort(),['origin','status','threadId']);writes++;goal={...goal,status:'active'};result={goal};}
   else if(value.method==='thread/goal/clear'){assert.equal(value.params.origin,'user');writes++;goal=null;result={cleared:true};}
   else throw Error('Unexpected RPC method '+value.method);
  }reply({id:value.id,result});
 }}catch(error){errors.push(error.message);socket.destroy();}});
});
try{
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(socketDir+'/app-server-control.sock',resolve);});
 const results=[];for(mode of ['normal','replaced']){goal={threadId:thread,objective:'Synthetic Goal only · 한글🙂',status:'blocked',createdAt:100,updatedAt:110,tokensUsed:4,timeUsedSeconds:2,tokenBudget:null};reads=0;writes=0;
  const child=spawn(binary,[home,mode],{stdio:['ignore','pipe','pipe']});let stdout='',stderr='';child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);const timer=setTimeout(()=>child.kill(),20000);const code=await new Promise(r=>child.once('exit',r));clearTimeout(timer);assert.equal(code,0,stderr);assert.match(stdout,/Goal protocol passed/);assert.equal(writes,mode==='normal'?2:0);results.push({mode,reads,writes});
 }assert.deepEqual(errors,[]);const report={passed:true,results,realCodexMutations:0,systemChanges:0};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{for(const socket of sockets)socket.destroy();await new Promise(r=>server.close(r));await rm(home,{recursive:true,force:true});}
