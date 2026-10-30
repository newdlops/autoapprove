import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,rm,symlink} from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const require=createRequire(import.meta.url),module=process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright');
const ws=require(path.join(path.dirname(module),'../playwright-core/lib/utilsBundle.js'));
const build=path.resolve('.build/release'),directory=await mkdtemp('/private/tmp/aa-conversation-rpc-');
const server=http.createServer(),websocket=new ws.wsServer({noServer:true}),clients=new Set(),methods=[];
const thread='00000000-0000-4000-8000-000000000219';let mode='normal',child,refusals=0;
const entry=(id,type,fields)=>({turnId:'turn',item:{id,type,...fields}});
try{
 await mkdir(directory+'/app-server-control');
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ConversationTransport'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-conversation-transport.swift','-o',directory+'/check'],{stdio:'inherit',timeout:120000});
 server.on('upgrade',(request,socket,head)=>websocket.handleUpgrade(request,socket,head,connection=>websocket.emit('connection',connection)));
 websocket.on('connection',socket=>{
  clients.add(socket);socket.on('close',()=>clients.delete(socket));
  socket.on('message',bytes=>{
   const message=JSON.parse(bytes.toString());
   if(message.id==='approval'){assert.equal(message.error?.code,-32601);refusals++;return;}
   methods.push(message.method);if(message.method==='initialized')return;
   let result;
   if(message.method==='initialize'){
    socket.send(JSON.stringify({id:message.id,result:{userAgent:'isolated'}}));socket.send(JSON.stringify({id:'approval',method:'item/commandExecution/requestApproval',params:{}}));return;
   }
   assert.equal(message.params.threadId,thread);
   if(message.method==='thread/read')result={thread:{id:thread,cwd:mode==='wrong-folder'?'/other':'/fixture',source:'cli',status:{type:'idle'}}};
   else{
    assert.equal(message.method,'thread/items/list');assert.equal(message.params.sortDirection,'desc');assert.equal(message.params.limit,32);
    if(mode==='unsupported'){socket.send(JSON.stringify({id:message.id,error:{code:-32601,message:'Unavailable'}}));return;}
    if(mode==='repeat')result={data:[],nextCursor:'repeat'};
    else if(message.params.cursor==='older')result={data:[entry('earliest','userMessage',{content:[{type:'text',text:'最初 · earliest'}]})],nextCursor:null};
    else if(message.params.cursor==='tools')result={data:[entry('answer','agentMessage',{text:'한글🙂 <img src=x onerror=alert(1)>',phase:'final_answer'}),entry('reason','reasoning',{content:['HIDDEN']}),entry('progress','agentMessage',{text:'진행',phase:'commentary'}),entry('user','userMessage',{content:[{type:'text',text:'요청'}]})],nextCursor:'older'};
    else result={data:[entry('tool','commandExecution',{aggregatedOutput:'SHELL PROMPT'})],nextCursor:'tools'};
   }
   socket.send(JSON.stringify({id:message.id,result}));
  });
 });
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(directory+'/daemon.sock',resolve);});
 await symlink(directory+'/daemon.sock',directory+'/app-server-control/app-server-control.sock');
 async function run(...args){child=spawn(directory+'/check',[directory,thread,...args],{stdio:['ignore','pipe','pipe']});let output='',error='';child.stdout.on('data',chunk=>output+=chunk);child.stderr.on('data',chunk=>error+=chunk);const status=await new Promise(resolve=>child.once('exit',resolve));assert.equal(status,0,error);return JSON.parse(output);}
 assert.equal((await run()).verified,true);
 for(const value of ['wrong-folder','repeat','unsupported']){mode=value;assert.equal((await run('--expect-error')).rejected,true);}
 assert.ok(refusals>=1);assert.ok(methods.every(method=>['initialize','initialized','thread/read','thread/items/list'].includes(method)));
 console.log(JSON.stringify({verified:true,checks:['production Unix client: display-only history and older pages','bounded tool-only page skipping','metadata checked before and after reads','wrong folder, repeating cursor and unsupported API rejected','server approval request refused; no turn, resume, queue or terminal writes'],methods}));
}finally{if(child&&child.exitCode===null)child.kill();for(const socket of clients)socket.terminate();websocket.close();server.close();await rm(directory,{recursive:true,force:true});}
