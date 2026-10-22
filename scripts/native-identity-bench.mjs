// Real Core comparisons against one owned inert PTY; no user terminal IO,
// live screen capture, input permission requests or settings changes.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const reference=option('reference-build'),candidate=option('candidate-build');
assert.ok(reference&&candidate,'Pass --reference-build=/path/to/.build/release and --candidate-build=/path/to/.build/release');
const pairs=Number(option('pairs','8'));assert.ok(Number.isInteger(pairs)&&pairs>=1&&pairs<=16);
const output=path.resolve(option('output','.runtime/performance/native-identity-'+Date.now()));assert.ok(!fs.existsSync(output),'Use a fresh output directory');fs.mkdirSync(output,{recursive:true,mode:0o700});
const sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fixture='Tests/fixtures/native-identity-bench.swift',holderSource='Tests/fixtures/pty-holder.c';
const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');fs.mkdirSync(cache,{recursive:true});
async function run(name,binary,args){
 const out=fs.openSync(output+'/'+name+'.stdout','wx',0o600),err=fs.openSync(output+'/'+name+'.stderr','wx',0o600),start=performance.now();
 const child=spawn(binary,args,{stdio:['ignore',out,err]});
 const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}));});
 fs.closeSync(out);fs.closeSync(err);
 fs.writeFileSync(output+'/'+name+'-job.json',JSON.stringify({...result,seconds:(performance.now()-start)/1000})+'\n',{mode:0o600});
 assert.equal(result.code,0,fs.readFileSync(output+'/'+name+'.stderr','utf8').slice(-4000));
 return fs.readFileSync(output+'/'+name+'.stdout','utf8');
}
await run('holder-compile','/usr/bin/cc',[holderSource,'-o',output+'/pty-holder']);
const builds={baseline:path.resolve(reference),candidate:path.resolve(candidate)},provenance={};
for(const[label,build]of Object.entries(builds)){
 const links=await coreLinkArguments(build),objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>build+'/AutoApproveCore.build/'+name);
 assert.ok(objects.length>0);
 const files=[build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))];
 const hashes=Object.fromEntries(files.map(file=>[file,sha(file)]));
 await run(label+'-compile','/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,fixture,'-o',output+'/'+label]);
 provenance[label]={hashes,binarySHA256:sha(output+'/'+label)};
}
const plan={pairs,fixtureSHA256:sha(fixture),holderSourceSHA256:sha(holderSource),holderSHA256:sha(output+'/pty-holder'),provenance,
 gates:{targetCPU:0.65,targetWall:0.8,discoveryCPU:0.95,discoveryWall:1.0,controlCPU:1.1,controlWall:1.1,maxRSSRatio:1.1,maxRSSAllowanceBytes:2097152}};
fs.writeFileSync(output+'/plan.json',JSON.stringify(plan,null,2)+'\n',{mode:0o600});
function verify(){
 assert.equal(sha(fixture),plan.fixtureSHA256);assert.equal(sha(holderSource),plan.holderSourceSHA256);assert.equal(sha(output+'/pty-holder'),plan.holderSHA256);
 for(const[label,proof]of Object.entries(provenance)){
  for(const[file,digest]of Object.entries(proof.hashes))assert.equal(sha(file),digest,file);
  assert.equal(sha(output+'/'+label),proof.binarySHA256,label);
 }
}
const reports=[];let semantics;
for(let pair=0;pair<pairs;pair++)for(const label of pair%2?['candidate','baseline']:['baseline','candidate']){
 verify();const value=JSON.parse(await run(pair+'-'+label,output+'/'+label,[output+'/pty-holder',...(pair%2?['--reverse']:[])]));verify();
 semantics??=value.semanticDigest;assert.equal(value.semanticDigest,semantics);
 assert.equal(value.source.inputs,0);assert.equal(value.source.permissionRequests,0);assert.equal(value.source.images,48);assert.equal(value.source.reveals,24);
 assert.equal(value.phases.length,6);for(const phase of value.phases)assert.equal(phase.childCPUSeconds,0);
 reports.push({pair,label,...value});console.log(JSON.stringify({completed:reports.length,total:pairs*2,pair,label}));
}
const median=list=>{const values=[...list].sort((a,b)=>a-b),middle=Math.floor(values.length/2);return values.length%2?values[middle]:(values[middle-1]+values[middle])/2;};
const gates=[],rows=[];
for(const mode of reports[0].phases.map(value=>value.mode)){
 const target=['connect','fresh-preview','cached-preview'].includes(mode),discovery=mode==='discovery-control',row={mode};
 for(const field of ['combinedCPUSeconds','wallSeconds','medianMS','p95MS']){
  const get=label=>median(reports.filter(value=>value.label===label).map(value=>value.phases.find(phase=>phase.mode===mode)[field]));
  const before=get('baseline'),after=get('candidate'),ratio=after/before;row[field]={baseline:before,candidate:after,ratio};
  if(field==='combinedCPUSeconds'||field==='wallSeconds'){
   const maximum=field==='combinedCPUSeconds'?(target?plan.gates.targetCPU:discovery?plan.gates.discoveryCPU:plan.gates.controlCPU):target?plan.gates.targetWall:discovery?plan.gates.discoveryWall:plan.gates.controlWall;
   gates.push({name:mode+':'+field,ratio,maximum,passed:ratio<=maximum});
  }
 }
 if(mode==='full-table-control'||discovery){
  const get=label=>median(reports.filter(value=>value.label===label).map(value=>{const phase=value.phases.find(phase=>phase.mode===mode);return phase.combinedCPUSeconds/phase.workUnits;}));
  const before=get('baseline'),after=get('candidate'),ratio=after/before,maximum=discovery?0.95:1.1;
  row.cpuPerRecord={baseline:before,candidate:after,ratio};gates.push({name:mode+':cpuPerRecord',ratio,maximum,passed:ratio<=maximum});
 }
 rows.push(row);
}
const max=label=>Math.max(...reports.filter(value=>value.label===label).map(value=>value.peakResidentBytes));
const limit=Math.max(max('baseline')*1.1,max('baseline')+2097152);gates.push({name:'maximumRSS',actual:max('candidate'),maximum:limit,passed:max('candidate')<=limit});
const result={passed:gates.every(value=>value.passed),pairs,processes:reports.length,rows,gates,semanticDigest:semantics,
 sourceReadCounts:reports.map(value=>({pair:value.pair,label:value.label,reads:value.source.screens})),
 scope:reports[0].scope,originalTerminalActions:0,systemSettingsChanged:false};
verify();fs.writeFileSync(output+'/comparison.json',JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(result));
if(process.argv.includes('--assert-improved')&&!result.passed)process.exitCode=1;
