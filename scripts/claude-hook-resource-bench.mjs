import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile,copyFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import assert from 'node:assert/strict';
import path from 'node:path';

const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const label=option('label')||'current';assert.match(label,/^[a-z0-9-]+$/);
const root=path.resolve('.runtime/claude-hook-resource-bench'),output=path.join(root,label),binary=path.join(output,'check');
const build=path.resolve(option('core-build')||'.build/release'),fixture='Tests/fixtures/claude-hook-resource-bench.swift';
const sha=data=>createHash('sha256').update(data).digest('hex');
await mkdir(output,{recursive:true,mode:0o700});
let provenance;
const reuse=option('reuse-from');
if(reuse||process.argv.includes('--reuse-binary')) {
 if(reuse){assert.match(reuse,/^[a-z0-9-]+$/);assert.notEqual(reuse,label);}
 const source=reuse?path.join(root,reuse):output;
 provenance=JSON.parse(await readFile(path.join(source,'provenance.json'),'utf8'));
 assert.equal(provenance.fixtureSHA256,sha(await readFile(fixture)));
 assert.equal(provenance.binarySHA256,sha(await readFile(path.join(source,'check'))));
 if(reuse)await copyFile(path.join(source,'check'),binary);
} else {
 const names=(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).sort();
 const objects=Object.fromEntries(await Promise.all(names.map(async n=>[n,sha(await readFile(build+'/AutoApproveCore.build/'+n))])));
 const workspaceSources=Object.fromEntries(await Promise.all(['ClaudeHookRequest.swift','ApprovalEngine.swift','SystemCommandRisk.swift'].map(async n=>[n,sha(await readFile('Sources/AutoApproveCore/'+n))])));
 const cache=path.resolve('.build/cache/ClaudeHookResourceBench');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...names.map(n=>build+'/AutoApproveCore.build/'+n),fixture,'-o',binary],{stdio:'inherit',timeout:120000});
 provenance={fixtureSHA256:sha(await readFile(fixture)),binarySHA256:sha(await readFile(binary)),workspaceSources,sourceScope:'Workspace snapshot; old --core-build source correspondence requires separate evidence. Immutable linked object/module/binary hashes identify actual execution.',coreObjects:objects,coreFingerprint:sha(JSON.stringify(objects)),coreModuleSHA256:sha(await readFile(build+'/Modules/AutoApproveCore.swiftmodule'))};
}
await writeFile(path.join(output,'provenance.json'),JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
const run=target=>JSON.parse(execFileSync(target,[],{encoding:'utf8',timeout:90000,maxBuffer:2*1024*1024}));
const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
const reference=option('reference'),reports=[],referenceReports=[];
let before;
if(reference) {
 before=JSON.parse(await readFile(reference,'utf8'));assert.equal(before.provenance.fixtureSHA256,provenance.fixtureSHA256);
 const referenceBinary=path.resolve(path.dirname(reference),'check');assert.equal(sha(await readFile(referenceBinary)),before.provenance.binarySHA256);
 for(let pair=0;pair<3;pair++)for(const kind of pair%2?['current','reference']:['reference','current']) {
  if(kind==='current')reports.push(run(binary));else referenceReports.push(run(referenceBinary));
 }
} else reports.push(run(binary));
const report={...reports[0],label,provenance,reports};
for(const value of [...reports,...referenceReports]){
 assert.equal(value.checksum,1056);assert.equal(value.sessions,1);
 assert.deepEqual(value.payloadBytes,report.payloadBytes);assert.equal(value.inputPosts,0);assert.equal(value.captures,0);
}
report.workloads=report.workloads.map(w=>{
 const trials=reports.flatMap(r=>r.workloads.find(value=>value.name===w.name).trials);
 return {...w,trials,cpuSeconds:median(trials.map(t=>t.cpuSeconds)),wallSeconds:median(trials.map(t=>t.wallSeconds))};
});
if(reference) {
 report.comparison=report.workloads.map(w=>{
  const trials=referenceReports.flatMap(r=>{const old=r.workloads.find(v=>v.name===w.name);assert.ok(old);assert.equal(old.rounds,w.rounds);return old.trials;});
  const referenceCPUSeconds=median(trials.map(t=>t.cpuSeconds));
  return {name:w.name,referenceCPUSeconds,cpuReductionPercent:100*(1-w.cpuSeconds/referenceCPUSeconds),cpuDeltaSeconds:w.cpuSeconds-referenceCPUSeconds};
 });
 report.referenceProvenance=before.provenance;report.referenceReports=referenceReports;
}
await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({...report,reports:undefined,referenceProvenance:undefined,referenceReports:undefined,provenance:{...provenance,coreObjects:undefined},workloads:report.workloads.map(({trials,...w})=>w)}));
if(process.argv.includes('--assert-improved')) {
 assert.ok(reference,'An immutable matching reference binary is required');
 for(const row of report.comparison){
  if(row.name==='fresh-large')assert.ok(row.cpuReductionPercent>=20,'Fresh request CPU must improve at least 20%; '+JSON.stringify(row));
  else assert.ok(row.cpuReductionPercent>=30,'Saved replay/ACK CPU must improve at least 30%; '+JSON.stringify(row));
 }
}
