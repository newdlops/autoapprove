// An owned Codex exec, fake local model and fake bridge; no user session or network provider.
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,realpath,rm} from 'node:fs/promises';
import {once} from 'node:events';
import readline from 'node:readline';
const option=name=>process.argv.find(x=>x.startsWith('--'+name+'='))?.slice(name.length+3);
const codex=await realpath(option('codex')||execFileSync('/usr/bin/which',['codex'],{encoding:'utf8'}).trim());
const relay=await realpath(option('relay')||'.build/debug/autoapprove');
const root=await mkdtemp('/private/tmp/aa-group-codex-'),home=path.join(root,'home'),bridge=path.join(root,'bridge');
const calls=[];let requests=0,toolSeen=false,child,ownThread;
const socket=net.createServer(peer=>{let data='';peer.setEncoding('utf8');peer.on('data',chunk=>{data+=chunk;const n=data.indexOf('\n');if(n<0)return;const message=JSON.parse(data.slice(0,n));calls.push(message.params);peer.end(JSON.stringify({result:{groups:[],agent:'codex'}})+'\n');});});
const api=http.createServer(async(req,res)=>{
 try {
  let body='';for await(const chunk of req)body+=chunk;
  const request=JSON.parse(body);requests++;
  const tools=(request.tools||[]).flatMap(t=>t.type==='namespace'?(t.tools||[]).map(x=>({...x,namespace:t.name})):[t]);
  const spec=tools.find(x=>x.name?.includes('get_session_groups'));
  let item;
  if(requests===1) {
   assert.ok(spec,'Codex model must receive the actual MCP tool');toolSeen=true;
   item={type:'function_call',id:'fixture-item',call_id:'fixture-call',name:spec.name,...(spec.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify(ownThread?{conversationID:ownThread}:{})};
  } else item={id:'fixture-done',type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'fixture complete'}]};
  res.writeHead(200,{'Content-Type':'text/event-stream'});
  for(const event of [{type:'response.created',response:{id:'fixture-'+requests,status:'in_progress',output:[]}},{type:'response.output_item.added',output_index:0,item},{type:'response.output_item.done',output_index:0,item},{type:'response.completed',response:{id:'fixture-'+requests,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:1}}}])res.write('data: '+JSON.stringify(event)+'\n\n');res.end();
 } catch(error){res.writeHead(500);res.end(String(error));}
});
try {
 await mkdir(home,{recursive:true});await mkdir(bridge,{recursive:true});
 await new Promise((resolve,reject)=>{socket.once('error',reject);socket.listen(path.join(bridge,'bridge.sock'),resolve);});
 await new Promise(resolve=>api.listen(0,'127.0.0.1',resolve));
 const config=`model="fixture-model"\nmodel_provider="fixture"\napproval_policy="never"\nsandbox_mode="read-only"\ncheck_for_update_on_startup=false\n[analytics]\nenabled=false\n[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:${api.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[mcp_servers.autoapprove]\ncommand=${JSON.stringify(relay)}\nargs=["mcp","--home",${JSON.stringify(bridge)}]\n`;
 await writeFile(path.join(home,'config.toml'),config,{mode:0o600});
 const env={...process.env,HOME:root,CODEX_HOME:home,OTEL_SDK_DISABLED:'true',NO_PROXY:'127.0.0.1,localhost'};
 const serverMode=process.argv.includes('--server');
 child=spawn(codex,serverMode?['app-server']:['--no-daemon','exec','--skip-git-repo-check','-C',root,'Query group fixture'],{cwd:root,env,stdio:[serverMode?'pipe':'ignore','pipe','pipe']});
 let stderr='';child.stderr.on('data',x=>stderr=(stderr+x).slice(-6000));child.stdout.resume();
 const closed=once(child,'close');const timer=setTimeout(()=>child.kill('SIGTERM'),45000);let serverPID=child.pid;
 if(serverMode){
  const reader=readline.createInterface({input:child.stdout}),pending=new Map();let sequence=0,finish;
  const complete=new Promise(resolve=>finish=resolve);
  reader.on('line',line=>{const value=JSON.parse(line);if(value.id!==undefined&&pending.has(value.id)){const p=pending.get(value.id);pending.delete(value.id);value.error?p.reject(Error(JSON.stringify(value.error))):p.resolve(value.result);}if(value.method==='turn/completed')finish(value.params);});
  const rpc=(method,params)=>new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});child.stdin.write(JSON.stringify({id,method,params})+'\n');});
  await rpc('initialize',{clientInfo:{name:'session-groups-fixture',version:'1'},capabilities:{experimentalApi:true}});
  child.stdin.write(JSON.stringify({method:'initialized'})+'\n');
  const {thread}=await rpc('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'});ownThread=thread.id;
  await rpc('turn/start',{threadId:thread.id,input:[{type:'text',text:'Query group fixture'}]});
  let deadline;try {await Promise.race([complete,new Promise((_,reject)=>{deadline=setTimeout(()=>reject(Error('server turn timed out')),30000);})]);} finally {clearTimeout(deadline);}
  reader.close();child.kill('SIGTERM');await closed;clearTimeout(timer);child=null;
 }else{
  const [status]=await closed;clearTimeout(timer);child=null;
  assert.equal(status,0,'Codex fixture failed: '+stderr);
 }
 assert.ok(toolSeen);assert.ok(requests>=2);
 const call=calls.find(x=>x.tool==='get_session_groups');assert.ok(call);assert.match(call.sessionID??'',/^process:\d+:/);
 if(serverMode) {
  assert.equal(call.conversationID,ownThread);assert.equal(call.agentKind,'codex');
  console.log(JSON.stringify({mode:'app-server',attributedToServer:call.sessionID.startsWith(`process:${serverPID}:`),scope:'owned app-server, no attached TUI'}));
 }else console.log('PASS owned real Codex exec: discovered MCP group tool and attributed its caller');
} finally {
 if(child&&child.exitCode===null)child.kill('SIGTERM');api.closeAllConnections();api.close();
 await new Promise(resolve=>socket.close(resolve));await rm(root,{recursive:true,force:true,maxRetries:3,retryDelay:100});
}
