import assert from 'node:assert/strict';
import {mkdtemp,rm} from 'node:fs/promises';
import {execFileSync,spawnSync} from 'node:child_process';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const build=path.resolve('.build/debug'),workspace=await mkdtemp('/private/tmp/aa-rollout-return-crash-helper-'),binary=workspace+'/check',results=[];
try {
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/RolloutReturnCrash'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-rollout-return-crash.swift','-o',binary],{stdio:'inherit',timeout:120000});
 const run=(root,mode)=>spawnSync(binary,[root,mode],{encoding:'utf8',timeout:20000});
 for(const [boundary,code,inspect] of [['no-stage',70,'no-stage'],['staged',71,'staged'],['before-rename',72,'attempted'],['after-rename',73,'attempted'],['verified',74,'verified']]) {
  const root=await mkdtemp('/private/tmp/aa-rollout-return-crash-case-');
  try {
   const created=run(root,'create');assert.equal(created.status,0,created.stderr);
   const crashed=run(root,'crash-'+boundary);assert.equal(crashed.status,code,crashed.stderr);
   const recovered=run(root,'inspect-'+inspect);assert.equal(recovered.status,0,recovered.stderr);
   const report=JSON.parse(recovered.stdout);assert.equal(report.goalTokens,73);assert.equal(report.ownerRemainsSource,true);
   if(boundary==='no-stage')assert.equal(report.missingStageNotReplayed,true);
   else if(boundary==='staged')assert.equal(report.completeStageAdoptedWithoutCopy,true);
   else {assert.equal(report.applyRejected,true);assert.equal(report.observed,boundary==='before-rename'?'notApplied':'applied');assert.equal(report.stage,boundary==='verified'?'verified':'attempted');}
   results.push({boundary,abruptProcessExit:true,...report});
  } finally {await rm(root,{recursive:true,force:true});}
 }
 console.log(JSON.stringify({verified:true,ownedProcessBoundaries:5,nativeCodexProcesses:0,userSessionsTouched:false,results}));
} finally {await rm(workspace,{recursive:true,force:true});}
