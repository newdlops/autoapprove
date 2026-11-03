// Owned-only feasibility probe. Never reads a user's CODEX_HOME or credentials.
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,copyFile,rm,stat} from 'node:fs/promises';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {createInterface} from 'node:readline';
import path from 'node:path';
const cli=process.env.AUTOAPPROVE_CODEX_BIN;
assert.ok(cli&&path.isAbsolute(cli),'Set AUTOAPPROVE_CODEX_BIN to a native installed CLI');
const version=execFileSync(cli,['--version'],{encoding:'utf8'}).trim();assert.match(version,/^codex-cli 0\.166\./);
const root=await mkdtemp('/private/tmp/aa-cross-home-'),children=[];
const env={...process.env};for(const k of Object.keys(env))if(/TOKEN|API_KEY|CODEX_HOME|NODE_OPTIONS/.test(k))delete env[k];
let requests=0;
const provider=createServer(async(req,res)=>{
 let data='';for await(const chunk of req)data+=chunk;
 if(!req.url.endsWith('/responses')){res.writeHead(404);res.end();return;}
 requests++;const id='resp_owned_'+requests,item={id:'msg_owned_'+requests,type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:'Owned preservation fixture response.',annotations:[]}]};
 res.writeHead(200,{'Content-Type':'text/event-stream','Connection':'close'});
 const emit=(type,body)=>res.write('data: '+JSON.stringify({type,...body})+'\n\n');
 emit('response.created',{response:{id,status:'in_progress',output:[]}});
 emit('response.output_item.added',{output_index:0,item:{...item,status:'in_progress',content:[]}});
 emit('response.output_text.delta',{item_id:item.id,output_index:0,content_index:0,delta:item.content[0].text});
 emit('response.output_item.done',{output_index:0,item});
 emit('response.completed',{response:{id,status:'completed',output:[item],usage:{input_tokens:23,output_tokens:11,total_tokens:34}}});res.end();
});
await new Promise(r=>provider.listen(0,'127.0.0.1',r));
async function server(home){
 await mkdir(home,{recursive:true});
 await writeFile(home+'/config.toml',`cli_auth_credentials_store = "file"\nmodel = "owned-fixture"\nmodel_provider = "owned"\n[features]\nhooks = false\n[model_providers.owned]\nname = "Owned loopback fixture"\nbase_url = "http://127.0.0.1:${provider.address().port}/v1"\nwire_api = "responses"\nrequires_openai_auth = false\n`);
 const child=spawn(cli,['app-server'],{cwd:home,env:{...env,CODEX_HOME:home},detached:true,stdio:['pipe','pipe','pipe']});children.push(child);
 let sequence=0,stderr='',notifications=[];const pending=new Map();
 child.stderr.on('data',b=>{stderr=(stderr+b).slice(-12000)});
 createInterface({input:child.stdout}).on('line',line=>{let m;try{m=JSON.parse(line)}catch{return}if('id'in m&&pending.has(m.id)){const p=pending.get(m.id);pending.delete(m.id);clearTimeout(p.timer);m.error?p.reject(Error(home+" "+p.method+": "+JSON.stringify(m.error))):p.resolve(m.result);}else notifications.push(m);});
 const request=(method,params={})=>new Promise((resolve,reject)=>{const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error(method+' timed out: '+stderr.slice(-1000)))},20000);pending.set(id,{resolve,reject,timer,method});child.stdin.write(JSON.stringify({id,method,params})+'\n');});
 const wait=async(method,predicate=()=>true)=>{const end=Date.now()+25000;while(Date.now()<end){const m=notifications.find(m=>m.method===method&&predicate(m.params));if(m)return m.params;await new Promise(r=>setTimeout(r,20));}throw Error(method+' missing: '+stderr.slice(-1000));};
 const stop=async()=>{if(child.exitCode!==null||child.signalCode!==null)return;process.kill(-child.pid,'SIGTERM');await new Promise(r=>{child.once('close',r);setTimeout(r,1500)});};
 await request('initialize',{clientInfo:{name:'owned_preservation_fixture',version:'1'},capabilities:{experimentalApi:true}});child.stdin.write(JSON.stringify({method:'initialized'})+'\n');
 return {request,wait,stop,home};
}
const sql=(home,q)=>execFileSync('/usr/bin/sqlite3',[home+'/goals_1.sqlite',q],{encoding:'utf8'}).trim();
try{
 let a=await server(root+'/a');
 const start=await a.request('thread/start',{cwd:root,model:'owned-fixture',modelProvider:'owned',approvalPolicy:'never',sandbox:'read-only'}),id=start.thread.id;
 await a.request('turn/start',{threadId:id,input:[{type:'text',text:'Owned synthetic history only. Reply with the fixture response.',text_elements:[]}]});
 const turn=await a.wait('turn/completed',p=>p.threadId===id);assert.equal(turn.turn.status,'completed',JSON.stringify(turn.turn.error));
 await a.request('thread/goal/set',{threadId:id,objective:'Owned preservation objective',status:'paused',tokenBudget:1234,origin:'user'});
 const source=(await a.request('thread/read',{threadId:id,includeTurns:true})).thread;assert.ok(source.turns.length>0);assert.ok(source.turns.some(t=>t.items.some(i=>i.type==='agentMessage')),'Nonempty assistant history required');
 console.error(JSON.stringify({sourcePath:source.path,pathExists:source.path?await stat(source.path).then(s=>s.size).catch(()=>false):false}));await a.stop();
 const columns=sql(a.home,'PRAGMA table_info(thread_goals);');assert.match(columns,/goal_id/);
 sql(a.home,`UPDATE thread_goals SET tokens_used=37,time_used_seconds=19 WHERE thread_id='${id}';`);
 const before=JSON.parse(sql(a.home,`SELECT json_object('thread_id',thread_id,'goal_id',goal_id,'objective',objective,'status',status,'token_budget',token_budget,'tokens_used',tokens_used,'time_used_seconds',time_used_seconds,'created_at_ms',created_at_ms,'updated_at_ms',updated_at_ms) FROM thread_goals WHERE thread_id='${id}';`));
 assert.equal(before.tokens_used,37);assert.equal(before.time_used_seconds,19);
 a=await server(a.home);await a.request('thread/resume',{threadId:id});const sourceGoal=(await a.request('thread/goal/get',{threadId:id})).goal;assert.equal(sourceGoal.tokensUsed,37);assert.equal(sourceGoal.timeUsedSeconds,19);await a.stop();
 const b=await server(root+'/b'),destination=path.join(b.home,path.relative(a.home,source.path));await mkdir(path.dirname(destination),{recursive:true});await copyFile(source.path,destination);assert.notEqual((await stat(source.path)).ino,(await stat(destination)).ino);
 const resumed=await b.request('thread/resume',{threadId:id,path:destination}),target=(await b.request('thread/read',{threadId:resumed.thread.id,includeTurns:true})).thread;
 const goal=(await b.request('thread/goal/get',{threadId:id})).goal;
 const report={verified:true,actualInstalledCodex:version,ownedHomes:2,realCredentialsUsed:false,existingSessionsTouched:false,providerRequests:requests,sameUUID:target.id===id,nonemptyHistoryPreserved:JSON.stringify(source.turns)===JSON.stringify(target.turns),sourceGoal:{tokensUsed:sourceGoal.tokensUsed,timeUsedSeconds:sourceGoal.timeUsedSeconds,tokenBudget:sourceGoal.tokenBudget,status:sourceGoal.status},destinationGoal:goal,goalPreserved:JSON.stringify(goal)===JSON.stringify(sourceGoal),independentRollout:true,settings:{model:resumed.model,modelProvider:resumed.modelProvider,approvalPolicy:resumed.approvalPolicy,sandbox:resumed.sandbox},gap:goal===null?'Public rollout resume does not import the Goal record. Exact goal_id/counters require a separately validated transfer contract.':null};
 console.log(JSON.stringify(report));assert.ok(report.sameUUID);assert.ok(report.nonemptyHistoryPreserved);assert.equal(goal,null,'Reassess preservation contract if public resume starts importing Goals');
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null){try{process.kill(-child.pid,'SIGTERM')}catch{}}
 provider.closeAllConnections();await new Promise(r=>provider.close(r));await rm(root,{recursive:true,force:true});
}
