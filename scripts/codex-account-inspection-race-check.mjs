import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,chmod,rm} from 'node:fs/promises';
import http from 'node:http';import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const require=createRequire(import.meta.url),module=process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright');
const ws=require(path.join(path.dirname(module),'../playwright-core/lib/utilsBundle.js'));
const root=await mkdtemp('/private/tmp/aa-inspection-race-'),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD||'.build/debug'),clients=new Set();
const server=http.createServer(),websocket=new ws.wsServer({noServer:true});let mode='race',account='a',calls=[];
const session=account=>({activeSessionId:'session-'+account,sessions:[{sessionId:'session-'+account,isActive:true,userId:'user-'+account,selectedWorkspaceAccountId:'workspace'}]});
try {
 await mkdir(root+'/app-server-control');const cli=root+'/codex';
 await writeFile(cli,`#!${process.execPath}\nimport readline from 'node:readline';for await(const line of readline.createInterface({input:process.stdin})){const m=JSON.parse(line);if(m.method==='initialized')continue;const result=m.method==='initialize'?{userAgent:'fixture'}:${JSON.stringify(session('b'))};console.log(JSON.stringify({id:m.id,result}));}\n`);await chmod(cli,0o700);
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/InspectionRace'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-account-inspection-race.swift','-o',root+'/check'],{stdio:'inherit',timeout:120000});
 server.on('upgrade',(request,socket,head)=>websocket.handleUpgrade(request,socket,head,connection=>websocket.emit('connection',connection)));
 websocket.on('connection',socket=>{clients.add(socket);socket.on('close',()=>clients.delete(socket));socket.on('message',bytes=>{
  const m=JSON.parse(bytes);if(m.method==='initialized')return;calls.push(m.method);let result;
  if(m.method==='initialize')result={userAgent:'fixture'};
  else if(m.method==='accountSession/list')result=session(account);
  else if(m.method==='account/read'){result={account:{type:'chatgpt',email:account+'@example.test',planType:'pro'},requiresOpenaiAuth:true};if(mode==='race')account='b';}
  else throw Error('Observer sent unexpected '+m.method);
  socket.send(JSON.stringify({id:m.id,result}));
 });});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(root+'/app-server-control/app-server-control.sock',resolve)});
 async function run(expected){const child=spawn(root+'/check',[root,cli,expected],{stdio:['ignore','pipe','pipe']});let output='',error='';child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>error+=b);const status=await new Promise(r=>child.once('exit',r));assert.equal(status,0,error);return JSON.parse(output);}
 await run('unverified');mode='stable';account='b';await run('same');
 assert.ok(calls.every(m=>['initialize','account/read','accountSession/list'].includes(m)));
 console.log(JSON.stringify({verified:true,racingIdentityRejected:true,stableIdentityAccepted:true,mutationCalls:0}));
}finally{for(const socket of clients)socket.terminate();websocket.close();server.close();await rm(root,{recursive:true,force:true});}
