import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,realpath,rm} from 'node:fs/promises';
import {once} from 'node:events';
const root=await mkdtemp('/private/tmp/aa-group-claude-'),home=path.join(root,'home'),bridge=path.join(root,'bridge');
const subagent=process.argv.includes('--subagent');
const args=process.argv.slice(2).filter(arg=>arg!=='--subagent');
const relay=await realpath(args[0]||'.build/debug/autoapprove');
const claude=await realpath(args[1]||execFileSync('/usr/bin/which',['claude'],{encoding:'utf8'}).trim());
const calls=[];let count=0,found=false,child,registrationKeys=[],usablePeerName=false,validConversationID=false;
const socket=net.createServer(peer=>{let data='';peer.setEncoding('utf8');peer.on('data',async chunk=>{data+=chunk;const n=data.indexOf('\n');if(n<0)return;const message=JSON.parse(data.slice(0,n));calls.push(message.params);
 const match=/^process:(\d+):/.exec(message.params.sessionID||'');
 if(match)try {const registration=JSON.parse(await readFile(path.join(home,'sessions',match[1]+'.json'),'utf8'));registrationKeys=Object.keys(registration).sort();usablePeerName=typeof registration.name==='string'&&registration.name.length>0;validConversationID=/^[a-f0-9-]{36}$/i.test(registration.sessionId||'');}catch{}
 peer.end(JSON.stringify({result:{groups:[],agent:'claude'}})+'\n');});});
const api=http.createServer(async(req,res)=>{
 try {
  let body='';for await(const chunk of req)body+=chunk;
  const request=JSON.parse(body);count++;
  const input=JSON.stringify(request.messages||[]);
  const worker=subagent&&input.includes('OWNED_GROUP_MESSAGE')&&!input.includes('toolu_spawn');
  const spawning=subagent&&!worker&&input.includes('OWNED_GROUP_PARENT')&&!input.includes('toolu_spawn');
  const sending=worker&&!input.includes('toolu_send');
  const toolName=spawning?'Agent':sending?'mcp__autoapprove__send_group_message':!subagent&&count===1?'mcp__autoapprove__get_session_groups':null;
  const tool=(request.tools||[]).find(x=>x.name===toolName);
  if(toolName)assert.ok(tool,'Claude must advertise '+toolName);
  if(tool&&!spawning)found=true;
  const toolInput=spawning?{description:'Verify group message',prompt:'OWNED_GROUP_MESSAGE',subagent_type:'fixtureworker'}:
    sending?{groupID:'00000000-0000-4000-8000-000000000001',memberID:'00000000-0000-4000-8000-000000000002',text:'Owned Claude fixture'}:{};
  const block=tool?{type:'tool_use',id:spawning?'toolu_spawn':sending?'toolu_send':'toolu_fixture',name:tool.name,input:{}}:{type:'text',text:'fixture complete'};
  const events=[
   {type:'message_start',message:{id:'msg_fixture',type:'message',role:'assistant',model:'claude-sonnet-4-5',content:[],stop_reason:null,stop_sequence:null,usage:{input_tokens:1,output_tokens:1}}},
   {type:'content_block_start',index:0,content_block:block},
   ...(tool?[{type:'content_block_delta',index:0,delta:{type:'input_json_delta',partial_json:JSON.stringify(toolInput)}}]:[]),
   {type:'content_block_stop',index:0},
   {type:'message_delta',delta:{stop_reason:tool?'tool_use':'end_turn',stop_sequence:null},usage:{output_tokens:1}},
   {type:'message_stop'}
  ];
  res.writeHead(200,{'Content-Type':'text/event-stream'});for(const event of events)res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);res.end();
 } catch(error){res.writeHead(500);res.end(String(error));}
});
try {
 await mkdir(home,{recursive:true});await mkdir(bridge,{recursive:true});
 await new Promise((resolve,reject)=>{socket.once('error',reject);socket.listen(path.join(bridge,'bridge.sock'),resolve);});
 await new Promise(resolve=>api.listen(0,'127.0.0.1',resolve));
 const config=path.join(root,'mcp.json');await writeFile(config,JSON.stringify({mcpServers:{autoapprove:{command:relay,args:['mcp','--home',bridge]}}}));
 const env={...process.env,HOME:root,CLAUDE_CONFIG_DIR:home,ANTHROPIC_API_KEY:'fixture-key',ANTHROPIC_BASE_URL:`http://127.0.0.1:${api.address().port}`,NO_PROXY:'127.0.0.1,localhost',DISABLE_TELEMETRY:'1',CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:'1'};
 const mode=subagent?['--tools','default','--agents',JSON.stringify({fixtureworker:{description:'Owned fixture messenger',prompt:'Carry out the fixture action.',tools:['mcp__autoapprove__send_group_message']}}),'--allowedTools','Agent','mcp__autoapprove__send_group_message']:['--bare','--allowedTools','mcp__autoapprove__get_session_groups'];
 child=spawn(claude,['--strict-mcp-config','--mcp-config',config,...mode,'--model','claude-sonnet-4-5','--print',subagent?'OWNED_GROUP_PARENT':'Query group fixture'],{cwd:root,env,stdio:['ignore','pipe','pipe']});
 const rootPID=child.pid;
 let stderr='';child.stderr.on('data',x=>stderr=(stderr+x).slice(-3000));child.stdout.resume();
 const closed=once(child,'close'),timer=setTimeout(()=>child.kill('SIGTERM'),30000);const [status]=await closed;clearTimeout(timer);child=null;
 assert.equal(status,0,'Claude fixture failed: '+stderr);assert.ok(found);assert.ok(count>=2);
 const call=calls.find(x=>x.tool===(subagent?'send_group_message':'get_session_groups'));assert.ok(call);assert.match(call.sessionID??'',/^process:\d+:/);assert.equal(call.agentKind,'claude');
 if(subagent){assert.equal(call.sessionID.split(':')[1],String(rootPID));assert.equal(call.text,'Owned Claude fixture');}
 console.log(JSON.stringify({passed:true,realClaudeMCP:true,callerAttributed:true,subagentMessage:subagent,registrationKeys,usablePeerName,validConversationID}));
} finally {
 if(child&&child.exitCode===null)child.kill('SIGTERM');api.closeAllConnections();api.close();await new Promise(resolve=>socket.close(resolve));await rm(root,{recursive:true,force:true,maxRetries:3,retryDelay:100});
}
