// Real isolated child + Goal; a loopback model only, no production sessions/auth.
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import {mkdtemp,mkdir,writeFile,copyFile,chmod,stat,rm} from 'node:fs/promises';
import {spawn,execFileSync} from 'node:child_process';
import {createRequire} from 'node:module';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
assert.ok(option('codex'),'Provide --codex=/absolute/native/codex');
const require=createRequire(import.meta.url),{ws:WS}=require(path.join(path.dirname(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright')),'../playwright-core/lib/utilsBundle.js'));
const root=await mkdtemp('/private/tmp/aa-child-goal-'),home=root+'/home',socket=home+'/app-server-control/app-server-control.sock';
const pending=new Map(),streams=new Set();let processChild,ws,seq=0,childID,rootID,childTurnID,posts=0,stderr='';
const wait=ms=>new Promise(r=>setTimeout(r,ms));
async function until(test,label){for(let i=0;i<200;i++){if(await test())return;await wait(100);}throw Error('Owned fixture timeout: '+label+' '+stderr.slice(-300));}
function rpc(method,params){return new Promise((resolve,reject)=>{const id=++seq;pending.set(id,{resolve,reject});ws.send(JSON.stringify({id,method,params}));});}
const api=http.createServer(async(req,res)=>{
 let raw='';for await(const chunk of req)raw+=chunk;
 const data=JSON.parse(raw),input=JSON.stringify(data.input),isChild=input.includes('OWNED_GOAL_CHILD')&&!input.includes('owned-spawn-call');
 const all=(data.tools||[]).flatMap(t=>t.type==='namespace'?(t.tools||[]).map(f=>({...f,namespace:t.name})):[t]);
 res.writeHead(200,{'Content-Type':'text/event-stream'});streams.add(res);res.on('close',()=>streams.delete(res));
 const rid='owned-goal-'+(++posts),emit=v=>res.write('data: '+JSON.stringify(v)+'\n\n');
 emit({type:'response.created',response:{id:rid,status:'in_progress',output:[]}});
 if(isChild&&input.includes('owned-goal-call')){const timer=setInterval(()=>{if(!res.destroyed)res.write(': owned heartbeat\n\n');},200);res.on('close',()=>clearInterval(timer));return;}
 const name=isChild?'create_goal':'spawn_agent',spec=all.find(t=>t.name===name);
 let item;
 if(isChild)item={type:'function_call',id:'owned-goal-item',call_id:'owned-goal-call',name,...(spec?.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({objective:'Owned child account transition Goal',token_budget:1234})};
 else if(!input.includes('owned-spawn-call'))item={type:'function_call',id:'owned-spawn-item',call_id:'owned-spawn-call',name,...(spec?.namespace?{namespace:spec.namespace}:{}),arguments:JSON.stringify({task_name:'goal_fixture',message:'OWNED_GOAL_CHILD',fork_turns:'none'})};
 else item={id:'owned-done-'+posts,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'Owned parent is waiting.'}]};
 emit({type:'response.output_item.added',output_index:0,item});emit({type:'response.output_item.done',output_index:0,item});emit({type:'response.completed',response:{id:rid,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}});res.end();
});
try {
 await mkdir(home+'/app-server-control',{recursive:true});await new Promise(r=>api.listen(0,'127.0.0.1',r));
 await writeFile(home+'/config.toml',`model="fixture-model"\nmodel_provider="fixture"\napproval_policy="never"\nsandbox_mode="read-only"\ncheck_for_update_on_startup=false\ncli_auth_credentials_store="file"\n[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:${api.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[features]\nmulti_agent_v2=true\ngoals=true\n[analytics]\nenabled=false\n`);
 const binary=root+'/owned-goal-server';await copyFile(option('codex'),binary);await chmod(binary,0o700);
 const env={HOME:root,CODEX_HOME:home,PATH:'/usr/bin:/bin',NO_COLOR:'1',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'127.0.0.1,localhost'};
 processChild=spawn(binary,['app-server','--listen','unix://'+socket],{cwd:root,env,stdio:['ignore','ignore','pipe']});processChild.stderr.on('data',c=>stderr=(stderr+c).slice(-2000));
 await until(async()=>{try{return(await stat(socket)).isSocket();}catch{return false;}},'socket');
 ws=new WS('ws://localhost/',{createConnection:()=>net.connect(socket)});await new Promise((r,j)=>{ws.once('open',r);ws.once('error',j);});
 ws.on('message',bytes=>{const m=JSON.parse(bytes);if(m.id!==undefined&&!m.method){const p=pending.get(m.id);pending.delete(m.id);if(p)m.error?p.reject(Object.assign(Error(m.error.message),m.error)):p.resolve(m.result);return;}if(m.method==='thread/started'&&m.params.thread.parentThreadId){childID=m.params.thread.id;}if(m.method==='turn/started'&&m.params.threadId===childID)childTurnID=m.params.turn.id;});
 await rpc('initialize',{clientInfo:{name:'owned-child-goal',version:'1'},capabilities:{experimentalApi:true}});ws.send(JSON.stringify({method:'initialized'}));
 rootID=(await rpc('thread/start',{cwd:root,approvalPolicy:'never',sandbox:'read-only'})).thread.id;
 await rpc('turn/start',{threadId:rootID,input:[{type:'text',text:'Create the owned child task and its Goal for this isolated test.'}]});
 await until(async()=>{
  const ids=(await rpc('thread/loaded/list',{})).data;
  for(const id of ids){if(id===rootID)continue;const row=(await rpc('thread/read',{threadId:id,includeTurns:false})).thread;if(row.parentThreadId===rootID){childID=id;const turns=(await rpc('thread/turns/list',{threadId:id,limit:1,itemsView:'notLoaded',sortDirection:'desc'})).data;childTurnID=turns[0]?.id;}}
  return Boolean(childID&&childTurnID);
 },'child');
 let before;await until(async()=>{before=(await rpc('thread/goal/get',{threadId:childID})).goal;return before?.status==='active';},'active child Goal');
 assert.match(childID,/^[0-9a-f-]{36}$/);
 const goalIdentity=()=>execFileSync('/usr/bin/sqlite3',[home+'/goals_1.sqlite',"SELECT goal_id FROM thread_goals WHERE thread_id='"+childID+"';"],{encoding:'utf8'}).trim();
 const originalGoalID=goalIdentity();assert.ok(originalGoalID);
 const meta=(await rpc('thread/read',{threadId:childID,includeTurns:false})).thread;assert.equal(meta.canAcceptDirectInput,false);
 let rejected;
 try{const paused=(await rpc('thread/goal/set',{threadId:childID,status:'paused',origin:'automatic'})).goal;assert.equal(paused.status,'paused');assert.equal(paused.objective,before.objective);assert.equal(paused.tokenBudget,before.tokenBudget);assert.ok(paused.tokensUsed>=before.tokensUsed);}
 catch(error){rejected=error;}
 if(process.argv.includes('--expect-rejection')){assert.equal(rejected?.code,-32600);assert.match(rejected.message,/direct app-server input is not allowed/);console.log(JSON.stringify({verified:true,originalDefectReproduced:true,realV2Child:true,activeGoal:true,existingSessionsTouched:false}));}
 else {assert.equal(rejected,undefined,rejected?.message);assert.equal(goalIdentity(),originalGoalID);console.log(JSON.stringify({verified:true,realV2Child:true,pausedWithoutDirectTurnInput:true,goalIdentityAndBudgetRetained:true,existingSessionsTouched:false}));}
} finally {
 for(const res of streams)res.destroy();ws?.terminate();
 if(processChild&&processChild.exitCode===null){const done=new Promise(r=>processChild.once('exit',r));processChild.kill('SIGTERM');const timer=setTimeout(()=>processChild.kill('SIGKILL'),3000);await done;clearTimeout(timer);}
 api.closeAllConnections();api.close();await rm(root,{recursive:true,force:true});
}
