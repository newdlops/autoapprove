import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const label=process.argv.find(value=>value.startsWith('--label='))?.slice(8)||'current';
assert.match(label,/^[a-z0-9-]+$/);
const build=path.resolve(process.argv.find(value=>value.startsWith('--core-build='))?.slice(13)||'.build/release');
const moduleCache=path.resolve(process.argv.find(value=>value.startsWith('--module-cache='))?.slice(15)||path.join('/private/tmp','aa-session-processing-'+label+'-module-cache'));
const directory=path.resolve('.runtime/session-processing-bench',label),binary=path.join(directory,'check');
await mkdir(directory,{recursive:true});
if(!process.argv.includes('--reuse-binary')){
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',moduleCache,
  '-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
  'Tests/fixtures/session-processing-bench.swift','-o',binary],{stdio:'inherit'});
}
const reports=[];
for(let sample=0;sample<5;sample++){
 const home=await mkdtemp('/private/tmp/aa-session-processing-');
 try{reports.push(JSON.parse(execFileSync(binary,[home],{encoding:'utf8',timeout:90000})));}
 finally{await rm(home,{recursive:true,force:true});}
}
const median=values=>values.sort((a,b)=>a-b)[Math.floor(values.length/2)];
const result={label,samples:reports.length,records:reports[0].records,sessions:reports[0].sessions,
 publications:reports.map(report=>report.publications),workloads:reports[0].workloads.map((workload,index)=>({...workload,
  cpuSeconds:median(reports.map(report=>report.workloads[index].cpuSeconds)),wallSeconds:median(reports.map(report=>report.workloads[index].wallSeconds))}))};
const comparison=process.argv.find(value=>value.startsWith('--compare='))?.slice(10);
if(comparison){
 assert.match(comparison,/^[a-z0-9-]+$/);
 const before=JSON.parse(await readFile(path.resolve('.runtime/session-processing-bench',comparison,'report.json'),'utf8'));
 result.comparison=result.workloads.flatMap(workload=>{
  const reference=before.workloads.find(value=>value.name===workload.name);
  if(!reference)return [];
  assert.equal(reference.rounds,workload.rounds,'Reference workload rounds differ');
  assert.equal(reference.checksum,workload.checksum,'Reference workload result differs');
  return [{name:workload.name,cpuReductionPercent:100*(1-workload.cpuSeconds/reference.cpuSeconds)}];
 });
 result.workloadsWithoutReference=result.workloads.filter(workload=>!before.workloads.some(value=>value.name===workload.name)).map(value=>value.name);
}
await writeFile(path.join(directory,'report.json'),JSON.stringify({...result,reports},null,2)+'\n');
console.log(JSON.stringify(result,null,2));
