import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile,copyFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import path from 'node:path';

const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const label=option('label')||'current'; assert.match(label,/^[a-z0-9-]+$/);
const build=path.resolve(option('core-build')||'.build/release');
const output=path.resolve('.runtime/dashboard-response-bench',label),binary=path.join(output,'check');
const fixture='Tests/fixtures/dashboard-response-bench.swift';
const sha=value=>createHash('sha256').update(value).digest('hex');
await mkdir(output,{recursive:true,mode:0o700});
let provenance;
const reuse=option('reuse-from');
if(reuse) {
 assert.match(reuse,/^[a-z0-9-]+$/);assert.notEqual(reuse,label);
 const source=path.resolve('.runtime/dashboard-response-bench',reuse);
 provenance=JSON.parse(await readFile(path.join(source,'provenance.json'),'utf8'));
 assert.equal(provenance.fixtureSHA256,sha(await readFile(fixture)));
 assert.equal(provenance.binarySHA256,sha(await readFile(path.join(source,'check'))));
 await copyFile(path.join(source,'check'),binary);
 await writeFile(path.join(output,'provenance.json'),JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
} else if(process.argv.includes('--reuse-binary')) {
 provenance=JSON.parse(await readFile(path.join(output,'provenance.json'),'utf8'));
 assert.equal(provenance.fixtureSHA256,sha(await readFile(fixture)));
 assert.equal(provenance.binarySHA256,sha(await readFile(binary)));
} else {
 const names=(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).sort();
 const objects=Object.fromEntries(await Promise.all(names.map(async n=>[n,sha(await readFile(build+'/AutoApproveCore.build/'+n))])));
 const workspaceSources=Object.fromEntries(await Promise.all(['RemoteDashboardResponse.swift','RemoteNetwork.swift','RemoteHTTP.swift'].map(async n=>[n,sha(await readFile('Sources/AutoApproveCore/'+n))])));
 const cache=path.resolve('.build/cache/DashboardResponseBench');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...names.map(n=>build+'/AutoApproveCore.build/'+n),fixture,'-o',binary],{stdio:'inherit',timeout:120000});
 provenance={fixtureSHA256:sha(await readFile(fixture)),binarySHA256:sha(await readFile(binary)),workspaceSources,sourceScope:'Workspace source snapshot; for --core-build from another revision, establish source correspondence separately. Immutable object/module/binary hashes identify the actual linked artifacts.',coreObjects:objects,coreFingerprint:sha(JSON.stringify(objects)),coreModuleSHA256:sha(await readFile(build+'/Modules/AutoApproveCore.swiftmodule'))};
 await writeFile(path.join(output,'provenance.json'),JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
}
const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
const run=binary=>JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:90000,maxBuffer:2*1024*1024}));
const reference=option('reference');
const reports=[],referenceReports=[];
let before;
if(reference) {
 before=JSON.parse(await readFile(reference,'utf8'));
 assert.equal(before.provenance.fixtureSHA256,provenance.fixtureSHA256);
 const referenceBinary=path.resolve(path.dirname(reference),'check');
 assert.equal(sha(await readFile(referenceBinary)),before.provenance.binarySHA256);
 // Match the machine's current thermal/load conditions: no comparisons with
 // timing numbers measured before a build or in a different process batch.
 for(let pair=0;pair<3;pair++)for(const kind of pair%2?['current','reference']:['reference','current']) {
  if(kind==='current')reports.push(run(binary));else referenceReports.push(run(referenceBinary));
 }
} else reports.push(run(binary));
const report={...reports[0],label,provenance};
report.workloads=report.workloads.map(w=>{
 const trials=reports.flatMap(r=>r.workloads.find(value=>value.name===w.name).trials);
 return {...w,trials,cpuSeconds:median(trials.map(t=>t.cpuSeconds)),wallSeconds:median(trials.map(t=>t.wallSeconds))};
});
if(reference) {
 assert.equal(before.correctnessCases,report.correctnessCases);assert.equal(before.sessions,report.sessions);assert.equal(before.nodes,report.nodes);
 report.comparison=report.workloads.map(w=>{
  const matched=referenceReports.flatMap(r=>{
   assert.equal(r.correctnessCases,report.correctnessCases);assert.equal(r.sessions,report.sessions);assert.equal(r.nodes,report.nodes);
   const old=r.workloads.find(v=>v.name===w.name);assert.ok(old);assert.equal(old.rounds,w.rounds);return old.trials;
  });
  const referenceCPUSeconds=median(matched.map(t=>t.cpuSeconds));
  return {name:w.name,referenceCPUSeconds,cpuReductionPercent:100*(1-w.cpuSeconds/referenceCPUSeconds),cpuDeltaSeconds:w.cpuSeconds-referenceCPUSeconds};
 });
 report.referenceProvenance=before.provenance;report.referenceReports=referenceReports;
}
report.reports=reports;
await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({...report,referenceProvenance:undefined,referenceReports:undefined,reports:undefined,provenance:{...provenance,coreObjects:undefined},workloads:report.workloads.map(({trials,...w})=>w)}));
if(process.argv.includes('--assert-improved')) {
 assert.ok(reference,'An immutable matching reference is required');
 for(const comparison of report.comparison) {
  if(comparison.name==='unchanged')assert.ok(comparison.cpuReductionPercent>=-20||comparison.cpuDeltaSeconds<=0.005,'Unchanged dashboard CPU regressed');
  else assert.ok(comparison.cpuReductionPercent>=20,'Full/changed dashboard CPU must improve by at least 20%; '+JSON.stringify(comparison));
 }
}
