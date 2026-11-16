// Real official local server, no model turns, auth, external network or user TTY.
import assert from 'node:assert/strict';
import {spawn,execFileSync,execFile} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,rm,access,symlink,unlink,stat,readFile,rename} from 'node:fs/promises';
import {promisify} from 'node:util';
import {createRequire} from 'node:module';
import {createInterface} from 'node:readline';
import {once} from 'node:events';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';

const cli=process.argv.find(value=>value.startsWith('--codex='))?.slice(8);
assert.ok(cli&&path.isAbsolute(cli),'Provide original official native CLI');
const require=createRequire(import.meta.url);
const {WebSocket}=require(process.env.AUTOAPPROVE_WEBSOCKET_MODULE||path.resolve('.runtime/official-codex-probe-deps/node_modules/ws'));
const root=await mkdtemp('/private/tmp/aa-official-writer-'),home=root+'/home',socket=root+'/server.sock';
const build=path.resolve('.build/debug'),helper=root+'/check',run=promisify(execFile);
const env={HOME:root,CODEX_HOME:home,PATH:'/usr/bin:/bin',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'localhost,127.0.0.1'};
let server,ws,cold,seq=0,stderr='';const pending=new Map(),holders=new Set();
async function stop(child){
 if(!child||child.exitCode!==null||child.signalCode!==null)return;
 const done=once(child,'exit');child.kill('SIGTERM');const timer=setTimeout(()=>child.kill('SIGKILL'),5000);
 try{await done;}finally{clearTimeout(timer);}
}
function rpc(method,params){return new Promise((resolve,reject)=>{
 const id=++seq,timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned RPC timeout '+method+' '+stderr));},15000);
 pending.set(id,{resolve:result=>{clearTimeout(timer);resolve(result)},reject:error=>{clearTimeout(timer);reject(error)}});
 ws.send(JSON.stringify({id,method,params}));
});}
async function hold(ids){
 const child=spawn(helper,[home,'hold',...ids],{cwd:root,env,stdio:['pipe','pipe','pipe']});
 let error='';child.stderr.on('data',bytes=>error+=bytes);
 const lines=createInterface({input:child.stdout}),queue=[],waiters=[];
 lines.on('line',line=>waiters.length?waiters.shift().resolve(line):queue.push(line));
 child.on('exit',()=>{for(const waiter of waiters)waiter.reject(Error('Lease helper exited '+error));waiters.length=0;});
 const next=()=>queue.length?Promise.resolve(queue.shift()):new Promise((resolve,reject)=>{
  const waiter={resolve:value=>{clearTimeout(timer);resolve(value)},reject:error=>{clearTimeout(timer);reject(error)}};
  const timer=setTimeout(()=>{waiters.splice(waiters.indexOf(waiter),1);reject(Error('Owned lease response timeout '+error));},15000);
  waiters.push(waiter);
 });
 holders.add(child);assert.equal(await next(),'held');
 return {async verify(){child.stdin.write('verify\n');assert.equal(await next(),'unchanged')},
  async verifyStale(){child.stdin.write('verify-stale\n');assert.equal(await next(),'stale')},
  async release(){const done=once(child,'exit');child.stdin.write('release\n');assert.equal(await next(),'released');await done;holders.delete(child);}};
}
async function coldWriter(){
 cold=spawn(cli,['app-server','--listen','stdio://'],{cwd:root,env,stdio:['pipe','pipe','pipe']});
 let error='';cold.stderr.on('data',bytes=>error=(error+bytes).slice(-1000));
 const replies=new Map();let counter=0;
 createInterface({input:cold.stdout}).on('line',line=>{
  const message=JSON.parse(line);const callback=replies.get(message.id);if(callback){replies.delete(message.id);callback(message);}
 });
 const request=(method,params)=>new Promise((resolve,reject)=>{
  const id=++counter,timer=setTimeout(()=>{replies.delete(id);reject(Error('Cold official process timeout '+error));},15000);
  replies.set(id,message=>{clearTimeout(timer);message.error?reject(Error(message.error.message)):resolve(message.result)});
  cold.stdin.write(JSON.stringify({id,method,params})+'\n');
 });
 await request('initialize',{clientInfo:{name:'owned-cold-writer',version:'1'},capabilities:{experimentalApi:true}});
 cold.stdin.write(JSON.stringify({method:'initialized'})+'\n');
 const id=(await request('thread/start',{cwd:root,ephemeral:false})).thread.id;
 await request('thread/archive',{threadId:id});
 await stop(cold);cold=null;
}
try{
 await mkdir(home);
 await writeFile(home+'/config.toml','check_for_update_on_startup=false\n[analytics]\nenabled=false\n[features]\napps=false\nplugins=false\ngoals=true\ndaemon_auto_start=false\n');
 execFileSync('/usr/bin/codesign',['--verify','--strict','-R=anchor apple generic and identifier "codex" and certificate leaf[subject.OU] = "2DC432GLL2"',cli],{stdio:'inherit'});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialWriterLease'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),...await coreSwiftObjects(build),'Tests/fixtures/codex-official-writer-lease.swift',...await coreLinkArguments(build),'-lsqlite3','-o',helper],{stdio:'inherit',timeout:120000});
 server=spawn(cli,['app-server','--listen','unix://'+socket],{cwd:root,env,stdio:['ignore','ignore','pipe']});
 server.stderr.on('data',bytes=>stderr=(stderr+bytes).slice(-4000));
 for(let i=0;i<200;i++){if(await access(socket).then(()=>true,()=>false))break;assert.equal(server.exitCode,null,stderr);await new Promise(r=>setTimeout(r,50));}
 ws=new WebSocket('ws+unix://'+socket+':/');await once(ws,'open');
 ws.on('message',bytes=>{const message=JSON.parse(bytes);if(message.id===undefined||message.method)return;const p=pending.get(message.id);pending.delete(message.id);if(p)message.error?p.reject(Object.assign(Error(message.error.message),{rpc:message.error})):p.resolve(message.result);});
 await rpc('initialize',{clientInfo:{name:'owned-writer-check',version:'1'},capabilities:{experimentalApi:true}});ws.send(JSON.stringify({method:'initialized'}));
 const start=async()=> (await rpc('thread/start',{cwd:root,ephemeral:false,config:{'thread_unload_delay_secs':3600}})).thread.id;
 const selected=await start(),sibling=await start();
 await rpc('thread/goal/set',{threadId:selected,objective:'Owned preserved goal',status:'paused',tokenBudget:4321});
 assert.equal((await run(helper,[home,'busy',selected],{cwd:root,env,timeout:15000})).stdout.trim(),'rejected','Live official writer must exclude the helper');
 await rpc('thread/archive',{threadId:selected});
 await rpc('thread/unarchive',{threadId:selected});
 const lease=await hold([selected]);
 // A cold official resume needs the selected writer; an unrelated conversation
 // and the current official process stay usable under shared coordination.
 await assert.rejects(rpc('thread/resume',{threadId:selected}),error=>/active writer|writer lock|conflict/i.test(error.message));
 assert.equal((await rpc('thread/read',{threadId:sibling,includeTurns:false})).thread.id,sibling);
 const third=await start();assert.ok(third&&third!==selected);
 // Goal writes use a different store. Prove this limitation rather than
 // mistaking exclusive rollout ownership for a full migration input barrier.
 const goal=(await rpc('thread/goal/set',{threadId:selected,objective:'Owned changed under rollout lock',status:'paused'})).goal;
 assert.equal(goal.objective,'Owned changed under rollout lock');
 // Failed multi-thread acquisition must release the locks it acquired first.
 const absent='00000000-0000-4000-8000-000000000001';
 assert.equal((await run(helper,[home,'busy',absent,sibling],{cwd:root,env,timeout:15000})).stdout.trim(),'rejected');
 const rollback=await hold([absent]);await rollback.release();
 await lease.verify();
 // New official processes attempt lock cleanup. Our held inode must survive.
 await coldWriter();await lease.verify();
 await lease.release();
 assert.equal((await rpc('thread/resume',{threadId:selected})).thread.id,selected);
 const malicious='00000000-0000-4000-8000-000000000002',link=home+'/thread-writer-locks/'+malicious+'.lock';
 const outside=root+'/outside';await writeFile(outside,'retained');await symlink(outside,link);
 const before=await stat(outside);
 assert.equal((await run(helper,[home,'invalid',malicious],{cwd:root,env,timeout:15000})).stdout.trim(),'rejected');
 assert.equal((await stat(outside)).size,before.size);assert.equal(await readFile(outside,'utf8'),'retained');await unlink(link);
 const replacementID='00000000-0000-4000-8000-000000000003',heldPath=home+'/thread-writer-locks/'+replacementID+'.lock';
 const stale=await hold([replacementID]);await rename(heldPath,heldPath+'.owned-old');await writeFile(heldPath,'');
 await stale.verifyStale();await stale.release();
 console.log(JSON.stringify({verified:true,officialVersion:'0.169.0',liveWriterExcluded:true,selectedResumeBlocked:true,
  unrelatedThreadsRemainUsable:true,failedScopeRollsBack:true,releaseRestoresResume:true,symlinkRejected:true,
  coldProcessCleanupSafe:true,replacedLockDetected:true,goalMutationsNotBlocked:true,
  modelTurns:0,userTerminalActions:0,migrationAuthorityClaimed:false}));
}finally{
 for(const p of pending.values())p.reject(Error('Owned fixture closing'));pending.clear();
 ws?.terminate();for(const child of holders)await stop(child);await stop(cold);await stop(server);await rm(root,{recursive:true,force:true});
}
