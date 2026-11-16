// Owned stdio and fake Unix bridge only; no user terminal or real group calls.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {createServer} from 'node:net';
import {mkdtemp,rm,realpath} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import path from 'node:path';
import readline from 'node:readline';
const binary=path.resolve(process.argv[2]||'.build/debug/autoapprove');
const home=await mkdtemp('/private/tmp/aa-mcp-conversation-'), calls=[];
const a=randomUUID(),b=randomUUID(),pending=new Map();
let child,closed,reader,sequence=0;
const server=createServer(socket=>{let buffer='';socket.setEncoding('utf8');socket.on('data',chunk=>{
 buffer+=chunk;const end=buffer.indexOf('\n');if(end<0)return;
 const message=JSON.parse(buffer.slice(0,end));calls.push(message.params);
 socket.end(JSON.stringify({result:{synthetic:true}})+'\n');
});});
try {
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(path.join(home,'bridge.sock'),resolve);});
 child=spawn(binary,['mcp','--home',home],{env:{...process.env,CODEX_HOME:home,CODEX_THREAD_ID:a,LANG:'C',LC_ALL:'C'},stdio:['pipe','pipe','pipe']});
 closed=once(child,'close');child.stderr.resume();
 reader=readline.createInterface({input:child.stdout});reader.on('line',line=>{const reply=JSON.parse(line);pending.get(reply.id)?.(reply);});
 async function call(meta,args={}) {
  const id=++sequence;let timer;
  const response=new Promise((resolve,reject)=>{pending.set(id,resolve);timer=setTimeout(()=>reject(Error('MCP deadline')),10000);});
  child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method:'tools/call',params:{name:'get_session_groups',arguments:args,...(meta?{_meta:meta}:{})}})+'\n');
  try{return (await response).result;}finally{clearTimeout(timer);pending.delete(id);}
 }
 assert.equal((await call({threadId:b},{sessionID:'forged-process',agentKind:'claude',codexCallerHome:'/forged'})).isError,false);
 assert.equal(calls[0].conversationID,b);assert.equal(calls[0].codexCallerConversationID,b);
 assert.equal(await realpath(calls[0].codexCallerHome),await realpath(home));assert.equal(calls[0].agentKind,'codex');
 assert.equal(calls[0].sessionID,undefined);assert.equal(calls[0].codexCallerSource,'codex_mcp_metadata');
 assert.equal((await call({threadId:a})).isError,false);assert.equal(calls[1].conversationID,a);
 assert.equal((await call(null)).isError,false);assert.equal(calls[2].conversationID,a);
 assert.equal(calls[2].codexCallerSource,'codex_exec_context');
 assert.equal((await call({threadId:b},{conversationID:a})).isError,true);
 assert.equal((await call({threadId:a,'x-codex-turn-metadata':{thread_id:b}})).isError,true);
 assert.equal(calls.length,3,'Mismatched evidence must not reach the bridge');
 child.stdin.end();assert.equal((await closed)[0],0);child=null;
 console.log(JSON.stringify({passed:5,perCallConversation:true,processIdentityIgnored:true,claimedIdentityRejected:true,transport:'owned_unix_socket'}));
} finally {
 reader?.close();if(child&&child.exitCode===null){child.kill();await closed;}
 await new Promise(resolve=>server.close(resolve));await rm(home,{recursive:true,force:true});
}
