// Isolated bridge: exercise the real MCP stdio process without using any user's session.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdtemp,realpath,rm} from 'node:fs/promises';
import {once} from 'node:events';
import readline from 'node:readline';
import path from 'node:path';

const binary=await realpath(process.argv[2]||'.build/debug/autoapprove');
const home=await mkdtemp('/private/tmp/aa-group-mcp-');
const calls=[];
const server=createServer(socket=>{
 let buffer='';socket.setEncoding('utf8');socket.on('data',chunk=>{
  buffer+=chunk;const end=buffer.indexOf('\n');if(end<0)return;
  const message=JSON.parse(buffer.slice(0,end));calls.push(message.params);
  socket.end(JSON.stringify({result:{ok:true}})+'\n');
 });
});
let child,closed;
try {
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(path.join(home,'bridge.sock'),resolve);});
 child=spawn(binary,['mcp','--home',home],{stdio:['pipe','pipe','pipe']});closed=once(child,'close');child.stderr.resume();
 const reader=readline.createInterface({input:child.stdout});
 const lines=reader[Symbol.asyncIterator]();
 const request=async(id,name,args)=>{
  child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method:'tools/call',params:{name,arguments:args}})+'\n');
  const line=await lines.next();assert.equal(line.done,false);
  const response=JSON.parse(line.value);assert.equal(response.id,id);assert.equal(response.result.isError,false);
 };
 await request(1,'ask_user',{questions:[{question:'fixture'}]});
 await request(2,'get_session_groups',{sessionID:'spoofed-session',agentKind:'spoofed-agent'});
 child.stdin.end();const [code]=await closed;assert.equal(code,0);child=null;reader.close();
 assert.deepEqual(calls.map(value=>value.tool),['ask_user','get_session_groups','disconnect']);
 assert.equal(calls[1].sessionID??null,calls[0].sessionID??null);
 assert.notEqual(calls[1].sessionID,'spoofed-session');
 assert.notEqual(calls[1].agentKind,'spoofed-agent');
 if(process.env.AA_EXPECT_AGENT==='1') assert.match(calls[1].sessionID??'',/^process:\d+:/);
 assert.ok(calls.every(value=>value.owner===calls[0].owner));
 console.log('PASS MCP stdio: session attribution is shared with existing attribution and caller override is discarded');
} finally {
 if(child&&child.exitCode===null&&child.signalCode===null){child.kill();await closed;}
 await new Promise(resolve=>server.close(resolve));await rm(home,{recursive:true,force:true});
}
