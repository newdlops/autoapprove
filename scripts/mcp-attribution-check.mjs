// Actual stdio forwarding into an owned fake Unix bridge. Never calls a real
// manager, posts a real question, captures a screen or sends terminal input.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {createServer} from 'node:net';
import {mkdir,mkdtemp,rm,realpath,writeFile} from 'node:fs/promises';
import readline from 'node:readline';
import path from 'node:path';
const binary=await realpath(process.argv[2]||'.build/release/autoapprove');
const directory=path.resolve('.runtime/mcp-attribution-check');await mkdir(directory,{recursive:true,mode:0o700});
const reference=JSON.parse(execFileSync('.runtime/process-ancestry-check/check',['--parent='+process.pid],{encoding:'utf8',timeout:30000}));
assert.equal(reference.liveParentVerified,true);const expected=reference.referenceSessionID;
const home=await mkdtemp('/private/tmp/aa-mcp-forward-'),calls=[],pending=new Map();
let child,reader,closed,failure,sequence=0;
const server=createServer(socket=>{let buffer='';socket.setEncoding('utf8');socket.on('data',chunk=>{
 buffer+=chunk;let end;while((end=buffer.indexOf('\n'))>=0){
  const raw=buffer.slice(0,end);buffer=buffer.slice(end+1);
  try{const message=JSON.parse(raw);assert.equal(message.method,'mcp');calls.push(message.params);socket.end(JSON.stringify({result:{synthetic:true}})+'\n');}
  catch(error){failure=error;socket.destroy();}
 }
});});
try{
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(path.join(home,'bridge.sock'),resolve);});
 child=spawn(binary,['mcp','--home',home],{stdio:['pipe','pipe','pipe']});closed=once(child,'close');void closed.catch(error=>{failure=error;});child.stderr.resume();
 reader=readline.createInterface({input:child.stdout});reader.on('line',line=>{try{const value=JSON.parse(line),item=pending.get(value.id);assert.ok(item);pending.delete(value.id);item.resolve(value);}catch(error){failure=error;for(const item of pending.values())item.reject(error);pending.clear();}});
 async function call(name,args){if(failure)throw failure;const id=++sequence;let timer;
  const response=new Promise((resolve,reject)=>{pending.set(id,{resolve,reject});timer=setTimeout(()=>{pending.delete(id);reject(Error('MCP forwarding deadline'));},20000);});
  child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method:'tools/call',params:{name,arguments:args}})+'\n');
  try{const value=await response;assert.equal(value.error,undefined);assert.equal(value.result.isError,false);}finally{clearTimeout(timer);}
 }
 await call('ask_user',{title:'synthetic',questions:[{question:'synthetic',options:[{label:'one'},{label:'two'}]}]});
 await call('get_user_answers',{requestID:'synthetic'});await call('list_screens',{});
 await call('start_screen_share',{title:'synthetic',scope:'display'});await call('stop_screen_share',{shareID:'synthetic'});
 child.stdin.end();const [code]=await closed;assert.equal(code,0);child=null;assert.equal(failure,undefined);
 assert.deepEqual(calls.map(c=>c.tool),['ask_user','get_user_answers','list_screens','start_screen_share','stop_screen_share','disconnect']);
 assert.ok(calls.every(c=>c.owner===calls[0].owner));assert.match(calls[0].owner,/^[a-f0-9-]{36}$/i);
 for(const request of calls){
  if(request.tool==='ask_user'||request.tool==='start_screen_share')assert.equal(request.sessionID??null,expected);
  else assert.equal(request.sessionID,undefined);
 }
 const report={passed:8,liveParentReferenceMatched:true,parentAgentFound:expected!==null,ownerPreserved:true,attributionOnlyWhereUsed:true,tools:calls.map(c=>c.tool),inputPosts:0,
  scope:'Actual CLI into an isolated fake bridge; no real question, screen or original terminal actions'};
 await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report));
}finally{reader?.close();if(child&&child.exitCode===null&&child.signalCode===null){child.kill();await closed;}await new Promise(resolve=>server.close(resolve));await rm(home,{recursive:true,force:true});}
