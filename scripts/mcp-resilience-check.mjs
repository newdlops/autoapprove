// Real stdio relay, owned Unix listener only. No app, user session or input.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdtemp,rm,realpath} from 'node:fs/promises';
import {once} from 'node:events';
import readline from 'node:readline';
const binary=await realpath(process.argv[2]||'.build/debug/autoapprove');
const home=await mkdtemp('/private/tmp/aa-mcp-resilience-');
let child,closed,reader,release,started,failure;
const first=new Promise(resolve=>started=resolve),responses=new Map(),calls=[];
const server=createServer(socket=>{
 let buffer='';socket.setEncoding('utf8');socket.on('error',()=>{});
 socket.on('data',bytes=>{
  buffer+=bytes;const end=buffer.indexOf('\n');if(end<0)return;
  try {
   const message=JSON.parse(buffer.slice(0,end)),params=message.params;calls.push(params);
   const requestID=params.questions?.[0]?.question??params.requestID;
   const respond=()=>socket.end(JSON.stringify({result:{synthetic:true}})+'\n');
   if(requestID==='hold'){release=respond;started();}
   else if(requestID==='lost'){socket.destroy();}
   else respond();
  }catch(error){failure=error;socket.destroy();}
 });
});
const listen=()=>new Promise((resolve,reject)=>{server.once('error',reject);server.listen(home+'/bridge.sock',resolve);});
async function until(check,label){const end=performance.now()+15000;while(!check()){if(failure)throw failure;assert.ok(performance.now()<end,label);await new Promise(r=>setTimeout(r,10));}}
function send(id,method,params){child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,...(params?{params}:{})})+'\n');}
const tool=(id,requestID)=>send(id,'tools/call',{name:'ask_user',arguments:{title:'synthetic',questions:[{question:requestID}]}});
try {
 await listen();
 child=spawn(binary,['mcp','--home',home],{env:{...process.env,HOME:home,CODEX_HOME:home},stdio:['pipe','pipe','pipe']});
 closed=once(child,'close');child.stderr.resume();
 reader=readline.createInterface({input:child.stdout});reader.on('line',line=>{
  try{const value=JSON.parse(line);assert.ok(!responses.has(value.id),'Duplicate response ID');responses.set(value.id,value);}
  catch(error){failure=error;}
 });
 tool(1,'hold');await first;
 const began=performance.now();send(2,'ping');send(3,'tools/list');child.stdin.write('{broken\n');
 await until(()=>responses.has(2)&&responses.has(3)&&responses.has(null),'Protocol health must bypass a held tool');
 const pingMS=Math.round(performance.now()-began);assert.ok(pingMS<2000,`Protocol stalled ${pingMS}ms`);
 assert.equal(responses.get(2).error,undefined);assert.ok(responses.get(3).result.tools.length>0);assert.equal(responses.get(null).error.code,-32700);
 send(5,'tools/call',{name:'get_user_answers',arguments:{requestID:'independent-read'}});
 await until(()=>responses.has(5),'A read must not wait behind the held mutation');
 assert.equal(responses.get(5).result.isError,false);
 tool(4,'short');for(let id=10;id<30;id++)tool(id,'queued-'+id);
 await until(()=>[...responses.values()].filter(v=>v.error?.code===-32000).length===6,'Tool queue must reject excess work without buffering it');
 release();
 const ids=[1,4,...Array.from({length:20},(_,i)=>i+10)];
 await until(()=>ids.every(id=>responses.has(id)),'Accepted tools must drain');
 assert.equal(calls.filter(c=>c.tool==='ask_user').length,16);assert.equal(ids.filter(id=>responses.get(id).result?.isError===false).length,16);
 await new Promise(resolve=>server.close(resolve));
 tool(50,'reconnect');await new Promise(resolve=>setTimeout(resolve,250));await listen();
 await until(()=>responses.has(50),'A temporarily missing listener must reconnect before sending');
 assert.equal(responses.get(50).result.isError,false);assert.equal(calls.filter(c=>c.questions?.[0]?.question==='reconnect').length,1);
 tool(51,'lost');await until(()=>responses.has(51),'A lost response must return an error');
 assert.equal(responses.get(51).result.isError,true);
 await new Promise(resolve=>setTimeout(resolve,200));assert.equal(calls.filter(c=>c.questions?.[0]?.question==='lost').length,1,'Never replay a possibly accepted request');
 send(52,'ping');await until(()=>responses.has(52),'Relay must survive response loss');
 child.stdin.end();const [code]=await closed;assert.equal(code,0);child=null;
 assert.equal(calls.at(-1).tool,'disconnect');assert.ok(calls.every(c=>c.owner===calls[0].owner));
 assert.equal(failure,undefined);
 console.log(JSON.stringify({verified:true,pingMS,protocolResponsiveDuringHeldTool:true,readBypassesHeldMutation:true,boundedTools:16,overloadRejected:6,listenerRestartRecovered:true,lostResponseNotReplayed:true,ownerPreserved:true,userTerminalTouched:false}));
}finally{
 release?.();reader?.close();if(child&&child.exitCode===null){child.kill();await closed;}
 await new Promise(resolve=>server.close(resolve));await rm(home,{recursive:true,force:true});
}
