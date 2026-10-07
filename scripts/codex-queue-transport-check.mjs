// Production Swift WebSocket client -> synthetic user-owned Unix app-server.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,rm,symlink,unlink,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import http from 'node:http';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const require=createRequire(import.meta.url),ws=require(path.join(path.dirname(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright')),'../playwright-core/lib/utilsBundle.js'));
const directory=await mkdtemp('/private/tmp/aa-codex-rpc-'),build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const thread='00000000-0000-4000-8000-000000000001',idleThread='00000000-0000-4000-8000-000000000002',methods=[],connections=new Set();let approvalRefusals=0,addMode='ack',adds=0;
const server=http.createServer(),websocket=new ws.wsServer({noServer:true});
let child;
try {
  await mkdir(path.join(directory,'app-server-control'));
  const cache=path.resolve('.build/cache/CodexQueueTransport');await mkdir(cache,{recursive:true});
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary=path.join(directory,'CodexQueueTransport');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/codex-queue-transport.swift','-o',binary],{stdio:'inherit'});
  server.on('upgrade',(request,socket,head)=>websocket.handleUpgrade(request,socket,head,connection=>websocket.emit('connection',connection)));
  websocket.on('connection',socket=>{
    connections.add(socket);socket.on('close',()=>connections.delete(socket));
    socket.on('message',bytes=>{
      const message=JSON.parse(bytes.toString());
      if(message.id==='approval-probe'){assert.equal(message.error?.code,-32601);approvalRefusals++;return;}
      methods.push(message.method);if(message.method==='initialized')return;
      if(message.method==='initialize'){
        assert.equal(message.params.capabilities.experimentalApi,true);socket.send(JSON.stringify({id:message.id,result:{userAgent:'isolated-fixture'}}));
        socket.send(JSON.stringify({id:'approval-probe',method:'item/commandExecution/requestApproval',params:{}}));return;
      }
      if(message.method==='thread/list'){
        assert.equal(message.params.cwd,'/fixture');assert.equal(message.params.useStateDbOnly,true);
        socket.send(JSON.stringify({id:message.id,result:{data:[{id:thread,name:'실행 중 원본',cwd:'/fixture',source:'vscode',status:{type:'active'}},{id:idleThread,cwd:'/fixture',source:'cli',status:{type:'idle'}},{id:crypto.randomUUID(),cwd:'/other',source:'cli',status:{type:'active'}},{id:crypto.randomUUID(),cwd:'/fixture',source:'cli',status:{type:'notLoaded'}}]}}));return;
      }
      assert.equal(message.params.threadId,thread);
      if(message.method==='thread/queue/add'){
        adds++;assert.match(message.params.clientUserMessageId,/^[a-fA-F0-9-]{36}$/);
        assert.deepEqual(message.params.input,[{type:'text',text:'한글🧪\t\n'.repeat(5000)}]);
        if(addMode==='disconnect'){socket.close();return;}
        socket.send(JSON.stringify({id:message.id,result:{queuedSubmission:{id:crypto.randomUUID(),clientUserMessageId:addMode==='mismatch'?'different':message.params.clientUserMessageId,input:message.params.input}}}));return;
      }
      if(message.method==='thread/read'){
        assert.equal(message.params.includeTurns,false);
        socket.send(JSON.stringify({id:message.id,result:{thread:{id:thread,cwd:'/fixture',source:'vscode',status:{type:'idle'}}}}));return;
      }
      if(message.method==='thread/queue/list'){
        const result=message.params.cursor?{data:[{id:'third',input:[{type:'image',url:'fixture'}]}],nextCursor:null}:{data:[{id:'first',input:[{type:'text',text:'한글🧪 · 첫 번째'}]},{id:'second',input:[{type:'text',text:'두 번째'}]}],nextCursor:'next'};
        const value=JSON.stringify({id:message.id,result}),middle=Math.floor(value.length/2);
        socket.send(value.slice(0,middle),{fin:false});socket.ping('fixture-ping');socket.send(value.slice(middle),{fin:true});return;
      }
      assert.equal(message.method,'thread/queue/delete');
      socket.send(JSON.stringify(message.params.queuedSubmissionId==='first'?{id:message.id,result:{deleted:true}}:{id:message.id,error:{code:-32000,message:'synthetic failure'}}));
    });
  });
  const socketPath=path.join(directory,'daemon.sock'),controlPath=path.join(directory,'app-server-control/app-server-control.sock');
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(socketPath,resolve);});
  async function runFixture(...args){
    child=spawn(binary,[directory,thread,...args],{stdio:['ignore','pipe','pipe']});let output='',error='';child.stdout.on('data',part=>output+=part);child.stderr.on('data',part=>error+=part);
    const status=await new Promise(resolve=>child.on('exit',resolve));assert.equal(status,0,error);return JSON.parse(output);
  }
  const nonSocket=path.join(directory,'not-a-socket');await writeFile(nonSocket,'');await symlink(nonSocket,controlPath);
  assert.equal((await runFixture('--expect-unavailable')).nonSocketRefused,true);assert.equal(methods.length,0);
  await unlink(controlPath);await symlink(socketPath,controlPath);
  assert.equal((await runFixture('--home-socket-proof')).kernelPeerBound,true);assert.equal(methods.length,0);
  const result=await runFixture();assert.deepEqual(result.ids,['first','second','third']);assert.equal(result.text,'한글🧪 · 첫 번째');assert.equal(result.attachments,1);assert.deepEqual(result.removed,['first']);assert.equal(result.partialError,true);
  assert.deepEqual(result.conversations,[thread,idleThread]);assert.equal(result.changedFolderRefused,true);
  const queued=await runFixture('--enqueue');assert.match(queued.queueID,/^[a-fA-F0-9-]{36}$/);assert.equal(queued.bytes,60000);
  for(const mode of ['mismatch','disconnect']){addMode=mode;const before=adds;assert.equal((await runFixture('--expect-unconfirmed')).unconfirmedRefused,true);assert.equal(adds-before,1,'An ambiguous write must not be retried');}
  assert.ok(approvalRefusals>=2);assert.ok(methods.every(method=>['initialize','initialized','thread/list','thread/read','thread/queue/list','thread/queue/delete','thread/queue/add'].includes(method)));
  console.log(JSON.stringify({result:'PASS',checks:['user-owned Unix WebSocket handshake, masked client frames and initialize','user-owned control symlink resolves to a socket; a non-socket link is refused before connection','paginated Unicode queue with fragmented responses and ping/pong','only queue operations and state-only thread lookup; server approval requests refused','partial delete acknowledgement is retained without retry','explicit active root selection uses state-only lookup and rejects changed folder','native queue/add works with a missing executable and a 60000-byte Unicode message','mismatched receipt and disconnect are refused without duplicate writes'],methods},null,2));
}finally{if(child&&child.exitCode===null)child.kill('SIGTERM');for(const socket of connections)socket.terminate();server.close();websocket.close();await rm(directory,{recursive:true,force:true});}
