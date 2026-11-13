// Owned loopback provider + real Codex child + production Swift approval client.
// Optional TUI is copied under a non-agent basename and run in an isolated PTY.
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import {mkdtemp,mkdir,writeFile,readFile,rm,copyFile,chmod,stat} from 'node:fs/promises';
import {spawn,execFileSync} from 'node:child_process';
import {createRequire} from 'node:module';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('codex'),'Provide --codex=/absolute/native/codex');
const require=createRequire(import.meta.url);
const {ws:WS}=require(path.join(path.dirname(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright')),'../playwright-core/lib/utilsBundle.js'));
const {Terminal}=require(process.env.AUTOAPPROVE_XTERM_HEADLESS_MODULE||'../extensions/vscode/node_modules/@xterm/headless');
const root=await mkdtemp('/private/tmp/aa-live-approval-'),home=root+'/home',sock=home+'/app-server-control/app-server-control.sock';
const terminal=new Terminal({cols:120,rows:40,allowProposedApi:true});
let serverProcess,tui,ws,stderr='',sequence=0,posts=0,approval,completed=false,commandOutput='',releaseChild,childHeld=false;
const pending=new Map(),baseline=process.argv.includes('--expect-stale-tui'),withTUI=Boolean(option('tui'));
assert.ok(!baseline||withTUI,'Baseline comparison requires --tui');
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const running=p=>p&&p.exitCode===null&&p.signalCode===null;
const screen=()=>Array.from({length:terminal.rows},(_,i)=>terminal.buffer.active.getLine(terminal.buffer.active.viewportY+i)?.translateToString(true)||'').join('\n');
const keys=value=>tui.stdin.write(JSON.stringify({keys:value})+'\n');
terminal.onData(value=>{if(running(tui))keys(value);});
async function until(check,label){for(let i=0;i<600;i++){if(await check())return;await delay(100);}if(withTUI&&option('screen'))await writeFile(option('screen'),screen());throw Error('Timed out '+label+' '+stderr.slice(-600));}
async function stop(p){if(!running(p))return;const closed=new Promise(r=>p.once('exit',r));p.kill('SIGTERM');const timer=setTimeout(()=>p.kill('SIGKILL'),3000);await closed;clearTimeout(timer);}
function rpc(method,params){return new Promise((resolve,reject)=>{const id=++sequence;pending.set(id,{resolve,reject});ws.send(JSON.stringify({id,method,params}));});}
const api=http.createServer(async(req,res)=>{
 let body='';for await(const c of req)body+=c;const data=JSON.parse(body),input=JSON.stringify(data.input);posts++;
 const isChild=input.includes('CHILD_APPROVAL_FIX_ONLY')&&!input.includes('fixture-spawn');
 const isDone=input.includes('fixture-command'),isSpawned=input.includes('fixture-spawn');
 if(withTUI&&isChild&&!isDone){childHeld=true;await new Promise(r=>releaseChild=r);if(res.destroyed)return;}
 const functions=(data.tools||[]).flatMap(t=>t.type==='namespace'?(t.tools||[]).map(f=>({...f,namespace:t.name})):[t]);
 const spec=functions.find(t=>t.name===(isChild?'exec_command':'spawn_agent'));
 let item;
 if(isChild&&!isDone)item={type:'function_call',id:'fixture-tool',call_id:'fixture-command',name:'exec_command',...(spec?.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({cmd:'printf APPROVAL_FIX_OK',sandbox_permissions:'require_escalated',justification:'Owned harmless child approval regression'})};
 else if(!isChild&&!isSpawned)item={type:'function_call',id:'fixture-spawn-item',call_id:'fixture-spawn',name:'spawn_agent',...(spec?.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({task_name:'approval_fixture',message:'CHILD_APPROVAL_FIX_ONLY',fork_turns:'none'})};
 else item={id:'fixture-done-'+posts,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'done'}]};
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 for(const event of [{type:'response.created',response:{id:'fixture-'+posts,status:'in_progress',output:[]}},{type:'response.output_item.added',output_index:0,item},{type:'response.output_item.done',output_index:0,item},{type:'response.completed',response:{id:'fixture-'+posts,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}}])res.write('data: '+JSON.stringify(event)+'\n\n');res.end();
});
try {
 await mkdir(home+'/app-server-control',{recursive:true});await new Promise(r=>api.listen(0,'127.0.0.1',r));
 await writeFile(home+'/config.toml',`model="fixture-model"\nmodel_provider="fixture"\napproval_policy="on-request"\nsandbox_mode="read-only"\ncheck_for_update_on_startup=false\n[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:${api.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[features]\nmulti_agent_v2=true\n[analytics]\nenabled=false\n`);
 const build=path.resolve('.build/debug'),map=JSON.parse(await readFile(build+'/AutoApproveCore.build/output-file-map.json','utf8'));
 const objects=Object.values(map).filter(v=>typeof v.object==='string').map(v=>path.join(build,'AutoApproveCore.build',path.basename(v.object)));
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/SubagentApprovals'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),...objects,'Tests/fixtures/codex-subagent-live-approval.swift',...await coreLinkArguments(build),'-lsqlite3','-o',root+'/observer'],{stdio:'inherit'});
 await copyFile(option('codex'),root+'/owned-approval-server');await chmod(root+'/owned-approval-server',0o700);
 serverProcess=spawn(root+'/owned-approval-server',['app-server','--listen','unix://'+sock],{cwd:root,env:{...process.env,CODEX_HOME:home},stdio:['ignore','ignore','pipe']});serverProcess.stderr.on('data',c=>stderr=(stderr+c).slice(-5000));
 await until(async()=>{try{return(await stat(sock)).isSocket();}catch{return false;}},'socket');
 ws=new WS('ws://localhost/',{createConnection:()=>net.connect(sock)});await new Promise((r,j)=>{ws.once('open',r);ws.once('error',j);});
 ws.on('message',bytes=>{
  const m=JSON.parse(bytes);
  if(m.method&&m.id!==undefined){if(m.method==='item/commandExecution/requestApproval')approval=m;return;}
  if(m.id!==undefined){const p=pending.get(m.id);pending.delete(m.id);if(p)m.error?p.reject(Error(JSON.stringify(m.error))):p.resolve(m.result);return;}
  if(m.method==='serverRequest/resolved'&&approval&&m.params.requestId===approval.id)approval.resolved=true;
  if(m.method==='item/completed'&&m.params?.item?.type==='commandExecution')commandOutput+=JSON.stringify(m.params.item);
  if(m.method==='turn/completed'&&approval&&m.params.threadId===approval.params.threadId)completed=true;
 });
 await rpc('initialize',{clientInfo:{name:'approval-fixture',version:'1'},capabilities:{experimentalApi:true}});ws.send(JSON.stringify({method:'initialized'}));
 const {thread:{id:thread}}=await rpc('thread/start',{cwd:root,approvalPolicy:'on-request',sandbox:'read-only'});
 if(withTUI){
  await copyFile(option('tui'),root+'/owned-approval-tui');await chmod(root+'/owned-approval-tui',0o700);
  tui=spawn('/usr/bin/python3',[path.resolve('Tests/fixtures/codex-approval-pty.py'),root+'/owned-approval-tui','--remote','unix://'+sock,'--no-alt-screen','resume',thread],{cwd:root,env:{...process.env,CODEX_HOME:home,TERM:'xterm-256color'},stdio:['pipe','pipe','inherit']});
  let partial='';tui.stdout.on('data',chunk=>{partial+=chunk;let n;while((n=partial.indexOf('\n'))>=0){const line=partial.slice(0,n);partial=partial.slice(n+1);terminal.write(Buffer.from(JSON.parse(line).bytes,'base64'));}});
  await until(()=>screen().includes('Ask Codex'),'TUI readiness');
 }
 await rpc('turn/start',{threadId:thread,input:[{type:'text',text:'Perform the owned harmless fixture command.'}]});
 if(withTUI){
  await until(()=>childHeld,'child model hold');
  const children=[];
  for(const id of (await rpc('thread/loaded/list',{})).data){if(id!==thread){const row=(await rpc('thread/read',{threadId:id,includeTurns:false})).thread;if(row.parentThreadId===thread)children.push(id);}}
  assert.equal(children.length,1,'Fixture must own exactly one child');
  // The explicit picker refreshes remote child metadata. An Alt+Right press
  // can otherwise consult the empty navigation cache established at startup.
  await until(()=>screen().includes('Ask Codex'),'parent ready for picker');
  keys('/subagents');await delay(350);keys('\r');await until(()=>screen().includes('Subagents'),'child picker');
  await until(()=>screen().includes(children[0])&&screen().includes(thread),'picker thread identities');
  const pickerRows=screen().split('\n'),childRow=pickerRows.findIndex(line=>line.includes(children[0])),parentRow=pickerRows.findIndex(line=>line.includes(thread));
  assert.notEqual(childRow,parentRow);
  // This native picker is not searchable; select the adjacent child row from
  // the initially selected parent instead of typing an ID into the terminal.
  keys(childRow>parentRow?'\u001b[B':'\u001b[A');await delay(300);keys('\r');
  await until(()=>screen().includes('Viewing sub-agent'),'child navigation');keys('\u001b[1;3D');
  await until(()=>screen().includes('Main [default]'),'parent navigation');releaseChild();
 }
 await until(()=>approval,'child approval');assert.notEqual(approval.params.threadId,thread);
 const metadata=await rpc('thread/read',{threadId:approval.params.threadId,includeTurns:false});assert.equal(metadata.thread.parentThreadId,thread);
 await rpc('thread/resume',{threadId:approval.params.threadId,excludeTurns:true});
 async function swift(...args){await new Promise((resolve,reject)=>{const p=spawn(root+'/observer',[home,...args],{stdio:'inherit'});p.once('exit',c=>c===0?resolve():reject(Error('Swift approval fixture failed')));});}
 await swift(approval.params.threadId);await delay(300);assert.equal(approval.resolved,undefined,'Observer consumed the approval');
 if(withTUI)await until(()=>screen().includes('Would you like'),'visible child approval on parent');
 await swift(thread,root);await until(()=>completed,'child command/turn completion');assert.ok(commandOutput.includes('APPROVAL_FIX_OK'));
 if(withTUI){
  await delay(500);
  if(baseline){assert.ok(screen().includes('Would you like'));keys('y');await until(()=>screen().includes('Not available in TUI yet for thread'),'original defect');}
  else {await until(()=>!screen().includes('Would you like')&&screen().includes('Ask Codex'),'resolved dialog cleanup');assert.ok(!screen().includes('Not available in TUI yet for thread'));}
  if(option('screen'))await writeFile(option('screen'),screen());
 }
 console.log(JSON.stringify({passed:true,realSpawnedChild:true,observerPreservedRequest:true,swiftAccepted:true,commandCompleted:true,childTurnCompleted:true,tui:withTUI?(baseline?'original-error-reproduced':'dialog-cleared-without-error'):'not-run'}));
} finally {
 releaseChild?.();if(running(tui)){tui.stdin.end();await stop(tui);}ws?.terminate();await stop(serverProcess);api.closeAllConnections();api.close();terminal.dispose();await rm(root,{recursive:true,force:true,maxRetries:3,retryDelay:100});
}
