// Clone one synthetic official-cohort SQLite fixture, then kill the actual
// production transfer helper before/after commit. Never touch a user home.
import assert from 'node:assert/strict';
import {execFileSync,execFile,spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,rm} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const seed=option('seed-home');
assert.ok(seed?.startsWith('/private/tmp/aa-managed2-daemon-cohort-')&&seed.endsWith('/home'),'Provide a retained, owned official cohort fixture home');
const root=await mkdtemp('/private/tmp/aa-history-transfer-'),source=root+'/source',target=root+'/target',build=path.resolve('.build/debug'),run=promisify(execFile);
const python=(program,args=[])=>JSON.parse(execFileSync('/usr/bin/python3',['-c',program,...args],{encoding:'utf8',maxBuffer:1024*1024}));
const tables=['thread_turns','thread_items','thread_history_projection_state','thread_realtime_items'];
let success=false,holder;
try {
 const {thread}=python(`import os,sqlite3,json,sys\nseed,source,target=sys.argv[1:]\na=sqlite3.connect('file:'+seed+'/thread_history_1.sqlite?mode=ro',uri=True)\ns=sqlite3.connect('file:'+seed+'/state_5.sqlite?mode=ro',uri=True)\nids=[r[0] for r in s.execute("SELECT id FROM threads WHERE thread_source='subagent'")]\nthread=next(i for i in ids if a.execute('SELECT count(*) FROM thread_turns WHERE thread_id=?',(i,)).fetchone()[0]>0)\nfor home in [source,target]:\n os.mkdir(home,0o700)\n b=sqlite3.connect(home+'/thread_history_1.sqlite');a.backup(b);b.execute('PRAGMA journal_mode=DELETE');b.close()\nprint(json.dumps({'thread':thread}))`,[seed,source,target]);
 function inspect(home){return python(`import sqlite3,json,sys,hashlib\nc=sqlite3.connect('file:'+sys.argv[1]+'/thread_history_1.sqlite?mode=ro',uri=True)\nthread=sys.argv[2];tables=json.loads(sys.argv[3])\ndef rows(selected):\n return [c.execute('SELECT * FROM '+t+' WHERE thread_id'+('= ' if selected else '!= ')+ '? ORDER BY '+','.join(str(i+1) for i in range(len(c.execute('PRAGMA table_info('+t+')').fetchall()))),(thread,)).fetchall() for t in tables]\ndef digest(v):return hashlib.sha256(json.dumps(v,separators=(',',':')).encode()).hexdigest()\nprint(json.dumps({'selected':digest(rows(True)),'others':digest(rows(False)),'count':sum(len(x) for x in rows(True))}))`,[home,thread,JSON.stringify(tables)]);}
 function mutate(home,program){return python(`import sqlite3,json,sys\nc=sqlite3.connect(sys.argv[1]+'/thread_history_1.sqlite');thread=sys.argv[2];tables=json.loads(sys.argv[3])\n${program}\nc.commit();print('{}')`,[home,thread,JSON.stringify(tables)]);}
 // Keep the original production WAL mode and live database owners. SQLite
 // backup initially creates a closed clone; initialize its sidecars exactly as
 // the official source/destination daemons do before read-only inspection.
 holder=spawn('/usr/bin/python3',['-c',`import sqlite3,sys\nconnections=[]\nfor home in sys.argv[1:]:\n c=sqlite3.connect(home+'/thread_history_1.sqlite');c.execute('PRAGMA journal_mode=WAL').fetchall();c.execute('SELECT count(*) FROM thread_turns').fetchall();connections.append(c)\nprint('ready',flush=True)\nsys.stdin.read()\nfor c in connections:c.close()`,source,target],{stdio:['pipe','pipe','pipe']});
 await new Promise((resolve,reject)=>{
  const timer=setTimeout(()=>{holder.kill('SIGTERM');reject(Error('Owned WAL owner startup timed out'));},10000);
  holder.once('error',error=>{clearTimeout(timer);reject(error);});
  holder.once('exit',code=>{clearTimeout(timer);reject(Error('Owned WAL owner exited '+code));});
  holder.stdout.once('data',bytes=>{clearTimeout(timer);assert.equal(bytes.toString().trim(),'ready');resolve();});
 });
 const original=inspect(source);assert.ok(original.count>0);
 function clear(){mutate(target,`for t in tables:c.execute('DELETE FROM '+t+' WHERE thread_id=?',(thread,))`);assert.equal(inspect(target).count,0);assert.equal(inspect(target).others,original.others);}
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/HistoryRecovery'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),...await coreSwiftObjects(build),'Tests/fixtures/codex-thread-history-recovery.swift',...await coreLinkArguments(build),'-lsqlite3','-o',root+'/check'],{timeout:120000});
 async function helper(id,mode,exit){
  const result=await run(root+'/check',[root,source,target,thread,id,mode],{timeout:30000,maxBuffer:16000}).then(value=>({code:0,...value}),error=>error);
  assert.equal(result.code,exit??0,result.stderr??result.message);
  return exit?undefined:JSON.parse(result.stdout);
 }
 clear();const before=randomUUID();await helper(before,'crash-before',87);
 assert.equal(inspect(target).count,0,'SQLite must roll back after process death before commit');
 assert.equal((await helper(before,'recover')).alreadyApplied,false);assert.deepEqual(inspect(target),original);
 clear();const after=randomUUID();await helper(after,'crash-after',86);
 assert.deepEqual(inspect(target),original,'The commit must survive loss of its controller');
 assert.equal((await helper(after,'recover')).alreadyApplied,true);assert.deepEqual(inspect(target),original);
 assert.equal((await helper(after,'recover')).alreadyApplied,true);assert.deepEqual(inspect(target),original);
 mutate(target,"c.execute(\"UPDATE thread_turns SET status='interrupted' WHERE thread_id=?\",(thread,))");
 const changed=inspect(target);assert.notEqual(changed.selected,original.selected);
 assert.equal((await helper(after,'reject')).rejected,true);assert.deepEqual(inspect(target),changed);
 assert.equal((await helper(randomUUID(),'reject')).rejected,true,'Unowned nonempty target must not be replaced');assert.deepEqual(inspect(target),changed);
 await helper(randomUUID(),'return');assert.deepEqual(inspect(target),original,'An authorized retired return must restore all selected index rows');
 clear();const changedSource=randomUUID();await helper(changedSource,'capture',88);
 mutate(source,"c.execute(\"UPDATE thread_turns SET status='interrupted' WHERE thread_id=?\",(thread,))");
 assert.equal((await helper(changedSource,'reject')).rejected,true);assert.equal(inspect(target).count,0);
 assert.equal(inspect(target).others,original.others);
 mutate(target,'c.execute("CREATE TABLE unexpected_history_schema(value TEXT)")');
 assert.equal((await helper(randomUUID(),'reject')).rejected,true);assert.equal(inspect(target).count,0);
 assert.equal(inspect(target).others,original.others);
 console.log(JSON.stringify({verified:true,actualOriginalCohortHistory:true,productionWALMode:true,processDeathBeforeCommitRolledBack:true,processDeathAfterCommitObserved:true,repeatedRecoveryIdempotent:true,changedDestinationRejected:true,changedSourceRejected:true,unknownSchemaRejected:true,unownedReplacementRejected:true,retiredReturnReplacesOnlySelectedIndex:true,unrelatedHistoryPreserved:true,userDataTouched:false}));success=true;
} finally {
 if(holder&&holder.exitCode===null&&holder.signalCode===null)await new Promise(resolve=>{
  const timer=setTimeout(()=>holder.kill('SIGKILL'),2000);holder.once('close',()=>{clearTimeout(timer);resolve();});holder.stdin.end();
 });
 if(success||!process.argv.includes('--keep-on-failure'))await rm(root,{recursive:true,force:true,maxRetries:10,retryDelay:100});
 else console.error('Owned history evidence retained at '+root);
}
