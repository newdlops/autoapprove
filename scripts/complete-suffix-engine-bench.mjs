// Compare two existing Core builds with synthetic adapters and prebuilt frames.
// No engine.start, original terminal reads/input, captures, listeners or PTYs.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const reference=option('reference-build'),candidate=option('candidate-build');assert.ok(reference&&candidate,'Pass --reference-build=/path/to/release --candidate-build=/path/to/release');
const pairs=Number(option('pairs','8')),rounds=Number(option('rounds','128'));assert.ok(Number.isInteger(pairs)&&pairs>=1&&pairs<=16);assert.ok(Number.isInteger(rounds)&&rounds>=1&&rounds<=1024);
const assertImproved=process.argv.includes('--assert-improved');if(assertImproved)assert.ok(pairs>=8&&rounds>=128,'Improvement assertions require at least8 pairs and128 rounds');
const output=path.resolve(option('output','.runtime/performance/complete-suffix-'+Date.now()));assert.ok(!fs.existsSync(output),'Use a fresh output directory');fs.mkdirSync(output,{recursive:true,mode:0o700});
const fixture='Tests/fixtures/complete-suffix-engine-bench.swift',sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');fs.mkdirSync(cache,{recursive:true});
async function run(name,binary,args){
  const out=fs.openSync(output+'/'+name+'.stdout','wx',0o600),err=fs.openSync(output+'/'+name+'.stderr','wx',0o600),start=performance.now();const child=spawn(binary,args,{stdio:['ignore',out,err]});
  const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}));});fs.closeSync(out);fs.closeSync(err);
  fs.writeFileSync(output+'/'+name+'-job.json',JSON.stringify({...result,seconds:(performance.now()-start)/1000})+'\n',{mode:0o600});assert.equal(result.code,0,fs.readFileSync(output+'/'+name+'.stderr','utf8').slice(-4000));return fs.readFileSync(output+'/'+name+'.stdout','utf8');
}
const builds={baseline:path.resolve(reference),candidate:path.resolve(candidate)},proofs={};
for(const [label,build]of Object.entries(builds)){
  const objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>build+'/AutoApproveCore.build/'+name),links=await coreLinkArguments(build);
  const files=[build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))],hashes=Object.fromEntries(files.map(file=>[file,sha(file)]));
  await run(label+'-compile','/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-name','profile','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,fixture,'-o',output+'/'+label]);
  proofs[label]={hashes,binarySHA256:sha(output+'/'+label)};
}
const kinds=['ascii-native','mixed-native','ascii-cocoa','mixed-cocoa'];
const plan={pairs,rounds,kinds,fixtureSHA256:sha(fixture),proofs,gates:{nativeChangedCPU:.95,nativeChangedWall:1,cocoaChangedCPU:1.05,cocoaChangedWall:1.1,unchangedCPU:1.05,unchangedWall:1.1,maxRSSRatio:1.1,maxRSSAllowance:1048576}};
fs.writeFileSync(output+'/plan.json',JSON.stringify(plan,null,2)+'\n',{mode:0o600});
function verify(){assert.equal(sha(fixture),plan.fixtureSHA256);for(const [label,proof]of Object.entries(proofs)){assert.equal(sha(output+'/'+label),proof.binarySHA256);for(const [file,digest]of Object.entries(proof.hashes))assert.equal(sha(file),digest,file);}}
const reports=[];
for(let pair=0;pair<pairs;pair++)for(const label of pair%2?['candidate','baseline']:['baseline','candidate']){
  verify();const state=output+'/state-'+pair+'-'+label;fs.mkdirSync(state,{mode:0o700});const report=JSON.parse((await run(pair+'-'+label,output+'/'+label,[state,String(rounds),String(pair%4)])).trim().split('\n').at(-1));verify();
  assert.equal(report.terminalInputs,0);assert.equal(report.captures,0);assert.equal(report.listeners,0);const offset=pair%4;assert.deepEqual(report.kinds.map(value=>value.kind),[...kinds.slice(offset),...kinds.slice(0,offset)]);
  for(const kind of report.kinds){assert.equal(kind.foreignFrames,kind.kind.endsWith('cocoa')?32:0);for(const row of kind.workloads){assert.equal(row.rounds,rounds);assert.equal(row.sessions,16);assert.equal(row.publications,row.name==='changing-screens'?rounds:0);assert.deepEqual(row.phaseCounts,{working:4,approval:4,input:4,idle:4});}}
  reports.push({pair,label,report});fs.writeFileSync(output+'/samples.json',JSON.stringify(reports,null,2)+'\n',{mode:0o600});console.log(JSON.stringify({completed:reports.length,total:pairs*2,pair,label}));
}
const median=values=>{const sorted=[...values].sort((a,b)=>a-b),mid=Math.floor(sorted.length/2);return sorted.length%2?sorted[mid]:(sorted[mid-1]+sorted[mid])/2;};
const rows=kinds.flatMap(kind=>['unchanged-screens','changing-screens'].map(name=>{
  const values={};for(const label of ['baseline','candidate']){const samples=reports.filter(value=>value.label===label).map(value=>value.report.kinds.find(item=>item.kind===kind).workloads.find(item=>item.name===name));values[label]={cpu:median(samples.map(row=>row.cpuSeconds)),wall:median(samples.map(row=>row.wallSeconds))};}
  const changed=name==='changing-screens',native=kind.endsWith('native'),g=plan.gates,cpuLimit=changed?(native?g.nativeChangedCPU:g.cocoaChangedCPU):g.unchangedCPU,wallLimit=changed?(native?g.nativeChangedWall:g.cocoaChangedWall):g.unchangedWall;
  const cpuRatio=values.candidate.cpu/values.baseline.cpu,wallRatio=values.candidate.wall/values.baseline.wall;return{kind,name,...values,cpuRatio,wallRatio,cpuLimit,wallLimit,passed:cpuRatio<=cpuLimit&&wallRatio<=wallLimit};
}));
const peak=label=>Math.max(...reports.filter(value=>value.label===label).flatMap(value=>value.report.kinds.map(kind=>kind.peakResidentBytes))),before=peak('baseline'),after=peak('candidate'),limit=Math.max(before*1.1,before+1048576);
const memory={baseline:before,candidate:after,limit,passed:after<=limit},result={passed:rows.every(row=>row.passed)&&memory.passed,diagnosticOnly:pairs<8||rounds<128,pairs,rounds,processes:reports.length,rows,memory,originalTerminalActions:0,scope:'Actual Core with16 synthetic sessions, prebuilt native/Cocoa frame banks; no original reads/input/capture/listeners. Factory and idle readiness outside timing. Instrument-free CPU/wall and process maximum RSS; not whole-app or phone performance.'};
verify();fs.writeFileSync(output+'/comparison.json',JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(result));if(assertImproved&&!result.passed)process.exitCode=1;
