import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {coreLinkArguments} from './swift-core-link.mjs';

// Optimized real Core, own synthetic adapters and own-process memory counters.
// No installed manager, terminal, screen capture, input or network listener.
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const out=path.resolve(option('output','.runtime/remote-read-retention-bench/'+label));
const current=path.resolve(option('core-build','.build/release')),reference=option('reference-build',null);
const pairs=Number(option('pairs','8'));assert.ok(Number.isInteger(pairs)&&pairs>=1&&pairs<=32);
const improved=process.argv.includes('--assert-improved');if(improved){assert.ok(reference);assert.equal(pairs,8);}
const fixture='Tests/fixtures/remote-read-retention-bench.swift',sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
fs.mkdirSync(out,{recursive:true,mode:0o700});assert.ok(!fs.existsSync(out+'/run-plan.json'),'Use a new output directory; completed trials are immutable.');
const plan={fixture,fixtureSHA256:sha(fixture),pairs,referenceBuild:reference?path.resolve(reference):null,currentBuild:current,
 modes:['retention','controls'],gates:{finalFootprintRatio:.65,finalFootprintReductionBytes:32*1024*1024,liveAllocatedRatio:.35,liveAllocatedReductionBytes:32*1024*1024,
 firstPhaseFootprintRatio:1.1,firstPhaseFootprintAllowance:1048576,activeCPURatio:1.1,activeWallRatio:1.1,
 controlsCPURatio:1.05,controlsWallRatio:1.1,peakResidentRatio:1.1,peakResidentAllowance:2097152,cleanupWallSeconds:.020},
 scope:'Actual optimized Core,3 representations,3 successive batches of36 distinct live synthetic sessions (108 total),~1MiB/source,actual10.2s expiration each phase.98,304 control frames with discovery. Own phys_footprint and malloc live bytes,not whole-app/user/VPN or exact payload accounting.',inputPosts:0,captures:0,listeners:0};
fs.writeFileSync(out+'/run-plan.json',JSON.stringify(plan,null,2)+'\n',{flag:'wx',mode:0o600});
async function execute(command,args,stem,timeout){
 const log=fs.openSync(out+'/'+stem+'.log','wx',0o600),start=performance.now();
 const child=spawn(command,args,{stdio:['ignore',log,log]});let timedOut=false;
 const timer=setTimeout(()=>{timedOut=true;child.kill('SIGTERM');},timeout);
 const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}));});
 clearTimeout(timer);fs.closeSync(log);const report={...result,seconds:(performance.now()-start)/1000,timedOut};
 fs.writeFileSync(out+'/'+stem+'-job.json',JSON.stringify(report)+'\n',{flag:'wx',mode:0o600});
 assert.equal(result.code,0,stem+' '+fs.readFileSync(out+'/'+stem+'.log','utf8').slice(-3000));assert.equal(timedOut,false);
 return fs.readFileSync(out+'/'+stem+'.log','utf8');
}
const versions={};
for(const [name,build]of Object.entries({...reference?{baseline:path.resolve(reference)}:{},candidate:current})){
 const coreNames=fs.readdirSync(build+'/AutoApproveCore.build').filter(n=>n.endsWith('.swift.o')).sort();
 const coreObjects=Object.fromEntries(coreNames.map(n=>[n,sha(build+'/AutoApproveCore.build/'+n)]));
 const linked=await coreLinkArguments(build),linkedObjects=Object.fromEntries(linked.filter(p=>p.endsWith('.o')).map(p=>[path.relative(build,p),sha(p)]));
 const moduleSHA256=sha(build+'/Modules/AutoApproveCore.swiftmodule');
 const binary=out+'/'+name,cache=out+'/module-cache';fs.mkdirSync(cache,{recursive:true});
 await execute('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...linked,...coreNames.map(n=>build+'/AutoApproveCore.build/'+n),fixture,'-o',binary],name+'-compile',120000);
 const proof={build,binary,fixtureSHA256:sha(fixture),binarySHA256:sha(binary),moduleSHA256,coreObjects,linkedObjects};
 fs.writeFileSync(out+'/'+name+'-provenance.json',JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o600});versions[name]=proof;
}
function verify(){
 assert.equal(sha(fixture),plan.fixtureSHA256);
 for(const proof of Object.values(versions)){
  assert.equal(sha(proof.binary),proof.binarySHA256);assert.equal(sha(proof.build+'/Modules/AutoApproveCore.swiftmodule'),proof.moduleSHA256);
  for(const [name,digest]of Object.entries(proof.coreObjects))assert.equal(sha(proof.build+'/AutoApproveCore.build/'+name),digest,name);
  for(const [name,digest]of Object.entries(proof.linkedObjects))assert.equal(sha(proof.build+'/'+name),digest,name);
 }
}verify();
const reports={baseline:{retention:[],controls:[]},candidate:{retention:[],controls:[]}};
for(let pair=0;pair<pairs;pair++)for(const mode of pair%2?['controls','retention']:plan.modes){
 const names=reference?(pair%2?['candidate','baseline']:['baseline','candidate']):['candidate'];
 for(const name of names){
  const stem=name+'-'+mode+'-'+pair,report=JSON.parse((await execute(versions[name].binary,[mode],stem,90000)).trim());
  assert.equal(report.mode,mode);assert.equal(report.inputPosts,0);assert.equal(report.captures,0);
  if(mode==='retention'){
   assert.equal(report.sessions,108);assert.equal(report.verifiedFrames,216);assert.equal(report.phases.length,3);
   for(const [batch,phase]of report.phases.entries()){
    assert.equal(phase.batch,batch);assert.ok(phase.filledCounts.every(v=>v.remoteFrames===12));assert.ok(phase.expiredCounts.every(v=>v.remoteFrames===0));
    if(reference){assert.ok(phase.filledCounts.every(v=>v.remoteScreenReads===(name==='baseline'?(batch+1)*12:12)),stem+' filled reads');
     assert.ok(phase.expiredCounts.every(v=>v.remoteScreenReads===(name==='baseline'?(batch+1)*12:0)),stem+' expired reads');}
   }
  }else assert.equal(report.frames,98304);
  reports[name][mode].push(report);fs.writeFileSync(out+'/'+stem+'.json',JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
  console.log(JSON.stringify({pair,mode,name,...mode==='retention'?{footprint:report.phases.map(p=>p.expired.footprint),liveAllocated:report.phases.map(p=>p.expired.liveAllocated)}:{footprint:report.footprint,cpu:report.cpu}}));
 }
}verify();
const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
const summary={};for(const name of Object.keys(versions)){
 const r=reports[name].retention,c=reports[name].controls;
 const expired=v=>v.phases.at(-1).expired,active=(v,key)=>v.phases.reduce((n,p)=>n+p.filled[key]-p.before[key]+p.expired[key]-p.cleanupStart[key],0);
 summary[name]={expiredFootprint:median(r.map(v=>expired(v).footprint)),expiredLiveAllocated:median(r.map(v=>expired(v).liveAllocated)),
  firstExpiredFootprint:median(r.map(v=>v.phases[0].expired.footprint)),firstExpiredLiveAllocated:median(r.map(v=>v.phases[0].expired.liveAllocated)),
  retainedGrowth:median(r.map(v=>expired(v).footprint-v.before.footprint)),setupCPU:median(r.map(v=>active(v,'cpu'))),setupWall:median(r.map(v=>active(v,'wall'))),
  cleanupWallMax:Math.max(...r.flatMap(v=>v.phases.map(p=>p.expired.wall-p.cleanupStart.wall))),
  retentionPeak:median(r.map(v=>expired(v).peakResident)),controlsCPU:median(c.map(v=>v.cpu)),controlsWall:median(c.map(v=>v.wall)),controlsPeak:median(c.map(v=>v.peakResident))};
 for(const mode of plan.modes){const values=reports[name][mode];assert.equal(new Set(values.map(v=>v.characters)).size,1);}
}
const checks=[];if(reference){
 for(const mode of plan.modes)assert.equal(reports.baseline[mode][0].characters,reports.candidate[mode][0].characters);
 const b=summary.baseline,c=summary.candidate,g=plan.gates;
 checks.push({name:'final footprint ratio',actual:c.expiredFootprint/b.expiredFootprint,limit:g.finalFootprintRatio},
  {name:'final footprint minimum reduction',actual:g.finalFootprintReductionBytes,limit:b.expiredFootprint-c.expiredFootprint},
  {name:'live allocation ratio',actual:c.expiredLiveAllocated/b.expiredLiveAllocated,limit:g.liveAllocatedRatio},
  {name:'live allocation minimum reduction',actual:g.liveAllocatedReductionBytes,limit:b.expiredLiveAllocated-c.expiredLiveAllocated},
  {name:'first phase footprint',actual:c.firstExpiredFootprint,limit:Math.max(b.firstExpiredFootprint*g.firstPhaseFootprintRatio,b.firstExpiredFootprint+g.firstPhaseFootprintAllowance)},
  {name:'active CPU ratio',actual:c.setupCPU/b.setupCPU,limit:g.activeCPURatio},{name:'active wall ratio',actual:c.setupWall/b.setupWall,limit:g.activeWallRatio},
  {name:'cleanup wall max',actual:c.cleanupWallMax,limit:g.cleanupWallSeconds},
  {name:'control CPU ratio',actual:c.controlsCPU/b.controlsCPU,limit:g.controlsCPURatio},{name:'control wall ratio',actual:c.controlsWall/b.controlsWall,limit:g.controlsWallRatio});
 for(const key of ['retentionPeak','controlsPeak'])checks.push({name:key,actual:c[key],limit:Math.max(b[key]*g.peakResidentRatio,b[key]+g.peakResidentAllowance)});
}
const result={passed:checks.every(v=>v.actual<=v.limit),pairs,processExecutions:Object.values(reports).reduce((n,m)=>n+m.retention.length+m.controls.length,0),
 fixtureSHA256:plan.fixtureSHA256,planSHA256:sha(out+'/run-plan.json'),summary,checks,scope:plan.scope,originalInputs:0,captures:0,listeners:0};
fs.writeFileSync(out+'/comparison.json',JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o600});console.log(JSON.stringify(result));
if(improved)assert.equal(result.passed,true,'Predeclared memory/CPU/latency gates failed. All trials remain recorded.');
