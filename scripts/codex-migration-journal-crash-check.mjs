import assert from'node:assert/strict';import{mkdtemp,mkdir,chmod,readFile,rm}from'node:fs/promises';
import{execFileSync,spawnSync}from'node:child_process';import{randomUUID}from'node:crypto';import path from'node:path';
import{coreLinkArguments,coreSwiftObjects}from'./swift-core-link.mjs';
const build=path.resolve('.build/debug'),workspace=await mkdtemp('/private/tmp/aa-migration-crash-helper-'),binary=workspace+'/check',results=[];
try{
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/MigrationCrash'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-migration-journal-crash.swift','-o',binary],{stdio:'inherit',timeout:120000});
 const run=(root,id,mode)=>spawnSync(binary,[root,id,mode],{encoding:'utf8',timeout:20000});
 for(const mode of['crash-central','crash-first-mirror','crash-synced']){
  const root=await mkdtemp('/private/tmp/aa-migration-crash-case-'),id=randomUUID();
  try{
   await Promise.all(['a','b'].map(n=>mkdir(root+'/'+n,{mode:0o700})));
   const created=run(root,id,'create');assert.equal(created.status,0,created.stderr);const homes=JSON.parse(created.stdout).homes;
   const crashed=run(root,id,mode);assert.equal(crashed.status,mode==='crash-synced'?71:70,crashed.stderr);
   for(const home of homes)await chmod(home.path+'/.autoapprove-migrations',0o700);
   const inspected=run(root,id,'inspect');assert.equal(inspected.status,0,inspected.stderr);const before=JSON.parse(inspected.stdout);
   assert.equal(before.revision,2);assert.equal(before.payload,'attempted');assert.equal(before.consistent,mode==='crash-synced');
   const revisions=await Promise.all(homes.map(async h=>JSON.parse(await readFile(h.path+'/.autoapprove-migrations/'+id+'.json','utf8')).revision));
   assert.deepEqual(revisions.sort(),mode==='crash-central'?[1,1]:mode==='crash-first-mirror'?[1,2]:[2,2]);
   const foreign=run(root,randomUUID(),'foreign');assert.notEqual(foreign.status,0,'A crashed owner must still block a different request');
   const repaired=run(root,id,'repair');assert.equal(repaired.status,0,repaired.stderr);assert.deepEqual(JSON.parse(repaired.stdout),{revision:2,consistent:true});
   const after=run(root,id,'inspect');assert.equal(after.status,0,after.stderr);assert.deepEqual(JSON.parse(after.stdout),{revision:2,consistent:true,payload:'attempted'});
   assert.equal(run(root,id,'complete').status,0);const next=run(root,randomUUID(),'foreign');assert.equal(next.status,0,next.stderr);
   results.push({mode,abruptProcessExit:true,mirroredRevisions:revisions,pendingOwnerBlockedForeignRequest:true,sameAttemptedIntentRecovered:true,terminalRelease:true});
  }finally{for(const name of['a','b'])try{await chmod(root+'/'+name+'/.autoapprove-migrations',0o700)}catch{}await rm(root,{recursive:true,force:true});}
 }
 console.log(JSON.stringify({verified:true,nativeEffectsPerformed:0,existingSessionsTouched:false,results}));
}finally{await rm(workspace,{recursive:true,force:true});}
