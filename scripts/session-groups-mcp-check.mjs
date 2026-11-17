// Isolated bridge: exercise the real MCP stdio process without using any user's session.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer,connect} from 'node:net';
import {mkdtemp,realpath,rm} from 'node:fs/promises';
import {once} from 'node:events';
import readline from 'node:readline';
import path from 'node:path';

const binary=await realpath(process.argv[2]||'.build/debug/autoapprove');
const home=await mkdtemp('/private/tmp/aa-group-mcp-');
const calls=[];
if(process.argv.includes('--offline')) {
 for(const host of ['127.0.0.1','::1','192.0.2.1']) {
  await new Promise((resolve,reject)=>{
   const socket=connect({host,port:9});
   socket.once('connect',()=>{socket.destroy();reject(new Error('IP networking was not blocked'));});
   socket.once('error',error=>{try {assert.ok(['EPERM','EACCES'].includes(error.code),String(error));resolve();}catch(failure){reject(failure);}});
   socket.setTimeout(2000,()=>{socket.destroy();reject(new Error('Expected immediate sandbox denial'));});
  });
 }
}

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
 if(process.argv.includes('--deny-socket')) {
  child=spawn('/usr/bin/sandbox-exec',['-p','(version 1)(allow default)(deny network*)',binary,'mcp','--home',home],{stdio:['pipe','pipe','pipe']});
  closed=once(child,'close');child.stderr.resume();let output='';child.stdout.on('data',chunk=>output+=chunk);
  child.stdin.end(JSON.stringify({jsonrpc:'2.0',id:1,method:'tools/call',params:{name:'get_session_groups',arguments:{}}})+'\n');
  const [code]=await closed;assert.equal(code,0);child=null;
  const result=JSON.parse(output.trim()).result;assert.equal(result.isError,true);
  assert.match(result.content[0].text,/로컬 소켓.*차단/);assert.equal(calls.length,0);
  console.log('PASS MCP sandbox: blocked Unix socket reports permission failure instead of claiming the app is stopped');
 } else {
 child=spawn(binary,['mcp','--home',home],{stdio:['pipe','pipe','pipe']});closed=once(child,'close');child.stderr.resume();
 const reader=readline.createInterface({input:child.stdout});
 const lines=reader[Symbol.asyncIterator]();
 const request=async(id,name,args,isError=false)=>{
  child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method:'tools/call',params:{name,arguments:args}})+'\n');
  const line=await lines.next();assert.equal(line.done,false);
  const response=JSON.parse(line.value);assert.equal(response.id,id);assert.equal(response.result.isError,isError);
 };
 await request(1,'ask_user',{questions:[{question:'fixture'}]});
 const groupTools=['get_session_groups','get_group_status','reconnect_group_member','send_group_message','assign_group_task','answer_group_question','ask_group_question','reply_group_question','get_group_messages','ack_group_messages','clear_session_group','clear_group_member','set_group_member_title','set_group_member_tab_color','get_group_clear_status'];
 for(const [index,tool] of groupTools.entries()) {
  await request(index+2,tool,{groupID:'fixture',memberID:'fixture',text:'fixture',task:'fixture',choice:1,
   sessionID:'spoofed-session',agentKind:'spoofed-agent',codexCallerHome:'/spoofed',codexCallerConversationID:'spoofed',codexCallerSource:'spoofed'});
 }
 // The stdio connection remains usable after the GUI's Unix listener restarts.
 await new Promise(resolve=>server.close(resolve));
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(path.join(home,'bridge.sock'),resolve);});
 await request(20,'get_session_groups',{});
 if(process.env.AA_EXPECT_AGENT==='1' && process.env.CODEX_THREAD_ID) {
  await request(21,'get_session_groups',{conversationID:'00000000-0000-4000-8000-000000000000'},true);
 }
 child.stdin.end();const [code]=await closed;assert.equal(code,0);child=null;reader.close();
 assert.deepEqual(calls.map(value=>value.tool),['ask_user',...groupTools,'get_session_groups','disconnect']);
 if(calls[1].codexCallerConversationID) {
  assert.equal(calls[1].sessionID,undefined,'Conversation proof must not fall back to a shared process ID');
  assert.equal(calls[1].agentKind,'codex');
  assert.equal(calls[1].codexCallerConversationID,process.env.CODEX_THREAD_ID?.toLowerCase());
  assert.equal(calls[1].codexCallerSource,'codex_exec_context');
 } else assert.equal(calls[1].sessionID??null,calls[0].sessionID??null);
 assert.notEqual(calls[1].sessionID,'spoofed-session');
 for(const call of calls.slice(1,-1)) {
  assert.notEqual(call.sessionID,'spoofed-session');assert.notEqual(call.agentKind,'spoofed-agent');
  assert.notEqual(call.codexCallerHome,'/spoofed');assert.notEqual(call.codexCallerConversationID,'spoofed');
  assert.notEqual(call.codexCallerSource,'spoofed');
 }
 if(process.env.AA_EXPECT_AGENT==='1') {
  if(calls[1].codexCallerConversationID) {
   assert.equal(calls[1].codexCallerConversationID,process.env.CODEX_THREAD_ID.toLowerCase());
   assert.equal(calls[1].codexCallerSource,'codex_exec_context');
  } else assert.match(calls[1].sessionID??'',/^process:\d+:/);
 }
 assert.ok(calls.every(value=>value.owner===calls[0].owner));
 console.log('PASS MCP stdio: all group tools stay on Unix sockets, discard spoofed attribution and reconnect after listener restart');
 }
} finally {
 if(child&&child.exitCode===null&&child.signalCode===null){child.kill();await closed;}
 await new Promise(resolve=>server.close(resolve));await rm(home,{recursive:true,force:true});
}
