import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const build=path.resolve(option('core-build','.build/release')),output=path.resolve('.runtime/codex-metadata-bench',label);
const root=path.resolve('.runtime/codex-metadata-bench/synthetic-fixture'),binary=output+'/check';
await mkdir(output,{recursive:true,mode:0o700});await mkdir(root,{recursive:true,mode:0o700});
execFileSync('/usr/bin/python3',['-c',`
import sys,sqlite3,json,pathlib
r=pathlib.Path(sys.argv[1]);(r/'sessions/2026/10/20').mkdir(parents=True,exist_ok=True)
p=r/'thread_history_1.sqlite'
if not p.exists():
 d=sqlite3.connect(p)
 d.executescript('CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_ordinal INTEGER); CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,completed_at INTEGER,rollout_ordinal INTEGER,final_agent_item_id TEXT); CREATE TABLE thread_items(thread_id TEXT,item_id TEXT,rollout_ordinal INTEGER,item_type TEXT,updated_at_ordinal INTEGER,item_json TEXT,turn_id TEXT); CREATE INDEX idx_thread_items_page ON thread_items(thread_id,rollout_ordinal); CREATE INDEX idx_thread_items_updated_page ON thread_items(thread_id,updated_at_ordinal);')
 for i in range(16):
  t='root-'+str(i);q={'type':'agentMessage','id':'question','delivery':'async','questions':[{'title':'Synthetic question '+str(i),'options':['First','Second']}]}
  d.execute('INSERT INTO thread_history_projection_state VALUES(?,?)',(t,2))
  d.execute('INSERT INTO thread_items VALUES(?,?,?,?,?,?,?)',(t,'question',1,'agentMessage',1,json.dumps(q),None))
 d.commit();d.close()
`,root],{timeout:20000});
const source=await readFile('Sources/AutoApproveCore/CodexQuestions.swift','utf8');
const start=source.indexOf('private struct CodexRolloutMetadataCache {'),end=source.indexOf('\npublic actor CodexQuestionCollector {',start);
assert.ok(start>=0&&end>start);
await writeFile(output+'/ProductionCache.swift','import Foundation\n'+source.slice(start,end).replaceAll('private ',''));
const fixture=await readFile('Tests/fixtures/codex-metadata-bench.swift');await writeFile(output+'/Fixture.swift',fixture);
const cache=path.resolve('.build/cache/CodexMetadataBench');await mkdir(cache,{recursive:true});
const objects=(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).sort();
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules',
  '-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects.map(n=>build+'/AutoApproveCore.build/'+n),
  output+'/ProductionCache.swift',output+'/Fixture.swift','-o',binary],{stdio:'inherit',timeout:300000});
const sha=p=>readFile(p).then(v=>createHash('sha256').update(v).digest('hex'));
const provenance={label,fixtureSHA256:createHash('sha256').update(fixture).digest('hex'),
  cacheSourceSHA256:createHash('sha256').update(source.slice(start,end)).digest('hex'),binarySHA256:await sha(binary),
  coreModuleSHA256:await sha(build+'/Modules/AutoApproveCore.swiftmodule'),coreObjects:Object.fromEntries(await Promise.all(objects.map(async n=>[n,await sha(build+'/AutoApproveCore.build/'+n)])))};
await writeFile(output+'/provenance.json',JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
if(process.argv.includes('--package-only')){console.log(binary);process.exit(0);}
const databaseSHA256=await sha(root+'/thread_history_1.sqlite');
const report=JSON.parse(execFileSync(binary,process.argv.includes('--check-cache')?['--check-cache']:[root],{encoding:'utf8',timeout:120000,maxBuffer:100000}));
assert.equal(await sha(root+'/thread_history_1.sqlite'),databaseSHA256,'Collector must leave its source database unchanged');
const result={...provenance,databaseSHA256,...report};await writeFile(output+'/report.json',JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(result));
