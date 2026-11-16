// Real official CLI and persisted history; all model responses are loopback fixtures.
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import {mkdtemp,mkdir,writeFile,rm,readdir,readFile} from 'node:fs/promises';
import {execFileSync,execFile,spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {createInterface} from 'node:readline';
import {once} from 'node:events';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const cli=process.argv.find(value=>value.startsWith('--codex='))?.slice(8);
const recovery=process.argv.includes('--exit-recovery');
const attachment=process.argv.includes('--attachment');
assert.ok(!(recovery&&attachment),'Select one owned lifecycle scenario');
const keepOnFailure=process.argv.includes('--keep-on-failure');let succeeded=false;
assert.ok(cli&&path.isAbsolute(cli),'Provide the original official native CLI');
const root=await mkdtemp('/private/tmp/aa-official-session-'),home=root+'/home',build=path.resolve('.build/debug');
const env={HOME:root,CODEX_HOME:home,ZDOTDIR:root,PATH:'/usr/bin:/bin',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'127.0.0.1,localhost'};
let daemonAttempted=false;
let seed,seq=0,posts=0,modelTurns=0,stderr='';const pending=new Map(),requests=[];
const api=http.createServer(async(req,res)=>{
 const chunks=[];for await(const chunk of req)chunks.push(chunk);
 const body=Buffer.concat(chunks).toString();let packet;try{packet=JSON.parse(body);}catch{}
 const userText=packet?.input?.at(-1)?.content?.filter(item=>item.type==='input_text').map(item=>item.text).join('') ?? '';
 const title=userText.startsWith('Generate a concise, single-line task title')&&userText.includes('\n\nUser prompt:\n');
 requests.push({method:req.method,url:req.url,title,userText:title?'[owned title request]':userText});
 if(!title)modelTurns++;
 const reply=title?JSON.stringify({title:'Verify owned recovery'}):recovery&&modelTurns>1?'OWNED_RECOVERY_REPLY':'OWNED_HISTORY_REPLY';
 const id='owned-history-'+(++posts),item={id:id+'-message',type:'message',role:'assistant',status:'completed',content:[{type:'output_text',text:reply}]};
 res.writeHead(200,{'Content-Type':'text/event-stream'});
 for(const value of [{type:'response.created',response:{id,status:'in_progress',output:[]}},
  {type:'response.output_item.added',output_index:0,item},{type:'response.output_item.done',output_index:0,item},
  {type:'response.completed',response:{id,status:'completed',output:[item],usage:{input_tokens:1,output_tokens:1,total_tokens:2}}}])res.write('data: '+JSON.stringify(value)+'\n\n');
 res.end();
});
function rpc(method,params){return new Promise((resolve,reject)=>{
 const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned seed timeout: '+method+' '+stderr));},15000);
 pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value);},reject:error=>{clearTimeout(timer);reject(error);}});
 seed.stdin.write(JSON.stringify({id,method,params})+'\n');
});}
async function startSeed(env){
 seed=spawn(cli,['app-server','--listen','stdio://'],{cwd:root,env,stdio:['pipe','pipe','pipe']});
 seed.stderr.on('data',bytes=>stderr=(stderr+bytes).slice(-1000));
 createInterface({input:seed.stdout}).on('line',line=>{
  const message=JSON.parse(line);
  if(message.id!==undefined&&!message.method){const p=pending.get(message.id);pending.delete(message.id);if(p)message.error?p.reject(Error(message.error.message)):p.resolve(message.result);}
 });
 await rpc('initialize',{clientInfo:{name:'owned-session-launch',version:'1'},capabilities:{experimentalApi:true}});
 seed.stdin.write(JSON.stringify({method:'initialized'})+'\n');
}
async function stopSeed(){
 if(!seed||seed.exitCode!==null||seed.signalCode!==null)return;
 const done=once(seed,'exit');seed.stdin.end();const timer=setTimeout(()=>seed.kill('SIGKILL'),5000);
 try{await done;}finally{clearTimeout(timer);}
}
async function stopDaemon(){
 if(!daemonAttempted)return;
 const {stdout}=await promisify(execFile)(cli,['app-server','daemon','stop'],{cwd:root,env,timeout:30000});
 assert.ok(['stopped','notRunning'].includes(JSON.parse(stdout).status),'Owned attachment daemon did not stop');
 daemonAttempted=false;
}
try {
 await mkdir(home);await new Promise((resolve,reject)=>{api.once('error',reject);api.listen(0,'127.0.0.1',resolve);});
 await writeFile(home+'/config.toml',`log_dir=${JSON.stringify(home+"/log")}\nmodel="fixture-model"\nmodel_provider="fixture"\napproval_policy="never"\nsandbox_mode="read-only"\ncli_auth_credentials_store="file"\ncheck_for_update_on_startup=false\n[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:${api.address().port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\n[features]\ndaemon_auto_start=false\napps=false\nplugins=false\n[analytics]\nenabled=false\n[projects.${JSON.stringify(root)}]\ntrust_level="trusted"\n`);
 await writeFile(root+'/.zshrc','export AUTOAPPROVE_NATIVE_RUNTIME_ROOT=/owned-stale-root\nexport AUTOAPPROVE_SELECTED_TRANSITION_SOCKET=/owned-stale-socket\nexport CODEX_HOME=/owned-wrong-home\n');
 if(attachment){
  await mkdir(home+'/app-server-daemon',{recursive:true,mode:0o700});
  await writeFile(home+'/app-server-daemon/settings.json',JSON.stringify({shutdownGraceSeconds:0,updater:{autoUpdateEnabled:false}}),{mode:0o600});
 }
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialSessionLaunch'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),...await coreSwiftObjects(build),`Tests/fixtures/codex-official-${attachment?'attachment':recovery?'exit-recovery':'session-launch'}.swift`,...await coreLinkArguments(build),'-lsqlite3','-o',root+'/check'],{stdio:'inherit',timeout:120000});
 let stdout;
 daemonAttempted=attachment;
 try {({stdout}=await promisify(execFile)(root+'/check',[root,cli],{cwd:root,env,encoding:'utf8',timeout:attachment?120000:60000}));}
 catch(error){
  // Keep failure output bounded: libvterm diagnostics otherwise hide the actual
  // failed stage. These logs belong only to this isolated synthetic conversation.
  const tuiLog=await readFile(home+'/log/codex-tui.log','utf8').catch(()=> 'No owned TUI log');
  throw new Error(`Owned CLI check failed (${error.code ?? error.signal}):\n${String(error.stderr ?? error.message).slice(-5000)}\nOwned TUI log:\n${tuiLog.slice(-12000)}`);
 }
 const report=JSON.parse(stdout);assert.equal(report.verified,true);
 await stopDaemon();
 const thread=report.threadID;assert.match(thread,/^[0-9a-f-]{36}$/);
 const metas=[];
 async function rollouts(dir){for(const entry of await readdir(dir,{withFileTypes:true})){const file=path.join(dir,entry.name);if(entry.isDirectory())await rollouts(file);else if(entry.name.endsWith('.jsonl')){const rows=(await readFile(file,'utf8')).trim().split('\n').map(JSON.parse);const meta=rows.find(row=>row.type==='session_meta')?.payload;if(meta)metas.push({meta,rows});}}}
 await rollouts(home+'/sessions');
 assert.ok(metas.some(row=>row.meta.id===thread));
 const forks=metas.filter(row=>row.meta.forked_from_id===thread||row.meta.forkedFromId===thread);
 assert.equal(forks.length,recovery||attachment?0:1,'Only the requested conversation operation may create a fork');
 // Fork rollouts can reference parent history instead of duplicating its bytes.
 // Ask the actual official reader to expand that persisted history after every
 // TUI has closed, so an in-memory preview alone cannot pass this check.
 await startSeed(env);
 const restored=await rpc('thread/read',{threadId:recovery||attachment?thread:forks[0].meta.id,includeTurns:true});
 assert.ok(JSON.stringify(restored).includes('OWNED_HISTORY_USER'));
 assert.ok(JSON.stringify(restored).includes('OWNED_HISTORY_REPLY'));
 assert.ok(!JSON.stringify(restored).includes('OWNED_SOURCE_DRAFT'));
 if(recovery){
  // The official TUI also requests a title in a separate hidden thread. Count
  // actual conversation requests and persisted turns, not metadata generation.
  assert.deepEqual(requests.filter(row=>!row.title).map(row=>row.userText),['OWNED_HISTORY_USER','이어서 진행하자.']);
  assert.equal(modelTurns,2);
  assert.ok(JSON.stringify(restored).includes('OWNED_RECOVERY_REPLY'));
  assert.equal(restored.thread.turns.length,2);
  assert.ok(restored.thread.turns.every(turn=>turn.status==='completed'),'Every owned turn completed before close');
 }
 if(attachment){
  assert.deepEqual(requests.filter(row=>!row.title).map(row=>row.userText),['OWNED_HISTORY_USER']);
  assert.equal(restored.thread.turns.length,1,'Attaching may not replay the original turn');
  assert.equal(restored.thread.turns[0].status,'completed');
 }
 const retained=await rpc('thread/read',{threadId:thread,includeTurns:true});
 assert.ok(!JSON.stringify(retained).includes('OWNED_SOURCE_DRAFT'));
 console.log(JSON.stringify({...report,...(recovery||attachment?{noForkCreated:true}:{persistedForkIdentityVerified:true}),coldHistoryReadVerified:true,loopbackModelOnly:true,realCredentialsUsed:false}));
 succeeded=true;
} finally {
 for(const p of pending.values())p.reject(Error('Owned seed closing'));pending.clear();await stopSeed();
 await stopDaemon();
 api.closeAllConnections();api.close();
 if(keepOnFailure&&!succeeded)console.error('Owned failure artifacts: '+root);
 else await rm(root,{recursive:true,force:true});
}
