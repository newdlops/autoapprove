import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const label=process.argv.find(value=>value.startsWith('--label='))?.slice(8)||'current';
assert.match(label,/^[a-z0-9-]+$/);
const directory=path.resolve('.runtime/history-safety-bench',label),binary=path.join(directory,'check');
await mkdir(directory,{recursive:true});
if(!process.argv.includes('--reuse-binary')){
 const build=path.resolve('.build/release');
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/HistorySafetyBench'),
  '-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
  'Tests/fixtures/history-safety-bench.swift','-o',binary],{stdio:'inherit'});
}
const reports=[];
for(let sample=0;sample<5;sample++){
 const home=await mkdtemp('/private/tmp/aa-history-safety-');
 try{reports.push(JSON.parse(execFileSync(binary,[home],{encoding:'utf8',timeout:90000})));}
 finally{await rm(home,{recursive:true,force:true});}
}
const median=values=>values.sort((a,b)=>a-b)[Math.floor(values.length/2)];
const result={label,samples:reports.length,workloads:reports[0].workloads.map((workload,index)=>({...workload,
  cpuSeconds:median(reports.map(report=>report.workloads[index].cpuSeconds)),wallSeconds:median(reports.map(report=>report.workloads[index].wallSeconds))}))};
const comparison=process.argv.find(value=>value.startsWith('--compare='))?.slice(10);
if(comparison){
 assert.match(comparison,/^[a-z0-9-]+$/);
 const before=JSON.parse(await readFile(path.resolve('.runtime/history-safety-bench',comparison,'report.json'),'utf8'));
 result.comparison=result.workloads.map((workload,index)=>({name:workload.name,cpuReductionPercent:100*(1-workload.cpuSeconds/before.workloads[index].cpuSeconds)}));
}
await writeFile(path.join(directory,'report.json'),JSON.stringify({...result,reports},null,2)+'\n');
console.log(JSON.stringify(result,null,2));
