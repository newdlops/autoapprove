import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import readline from 'node:readline';
import {coreLinkArguments} from './swift-core-link.mjs';
function endpointFactory(binary,root){
class Endpoint {
 constructor(pair,label){
  this.pair=pair;this.label=label;this.pending=[];this.done=false;
  this.out=fs.openSync(root+'/'+pair+'-'+label+'.stdout','wx',0o600);this.err=fs.openSync(root+'/'+pair+'-'+label+'.stderr','wx',0o600);
  this.child=spawn(binary,[],{stdio:['pipe','pipe',this.err]});
  fs.writeFileSync(root+'/'+pair+'-'+label+'-started.json',JSON.stringify({pid:this.child.pid,at:new Date().toISOString()})+'\n',{flag:'wx',mode:0o600});
  this.raw=[];this.child.stdout.on('data',bytes=>this.raw.push(Buffer.from(bytes)));
  this.lines=readline.createInterface({input:this.child.stdout});
  this.lines.on('line',line=>{const pending=this.pending.shift();if(!pending)return;clearTimeout(pending.timer);try{pending.resolve(JSON.parse(line));}catch(error){pending.reject(error);}});
  this.exited=new Promise((resolve,reject)=>{this.child.once('error',reject);this.child.once('exit',(code,signal)=>{this.done=true;for(const pending of this.pending.splice(0)){clearTimeout(pending.timer);pending.reject(new Error('Owned fixture exited '+code+' '+signal));}resolve({code,signal});});});
 }
 request(command){
  return new Promise((resolve,reject)=>{
   const pending={resolve,reject,timer:null};pending.timer=setTimeout(()=>reject(new Error('Owned fixture response exceeded60s')),60000);this.pending.push(pending);
   this.child.stdin.write(JSON.stringify(command)+'\n',error=>{if(error){clearTimeout(pending.timer);reject(error);}});
  });
 }
 async close(){
  if(!this.done){await this.request({op:'quit'});this.child.stdin.end();}
  const result=await this.exited;this.lines.close();fs.writeSync(this.out,Buffer.concat(this.raw));fs.closeSync(this.out);fs.closeSync(this.err);
  fs.writeFileSync(root+'/'+this.pair+'-'+this.label+'-job.json',JSON.stringify(result)+'\n',{flag:'wx',mode:0o600});assert.equal(result.code,0);return result;
 }
 abort(){if(!this.done)this.child.kill('SIGTERM');}
}

return Endpoint;
}

// Fresh paired-window comparison of two existing, matching Core builds.
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
assert.ok(option('reference-build')&&option('candidate-build'),'Pass --reference-build=... --candidate-build=...');
const pairs=Number(option('pairs','8'));assert.ok(Number.isInteger(pairs)&&pairs>=1&&pairs<=16);
const assertImproved=process.argv.includes('--assert-improved');if(assertImproved)assert.ok(pairs>=8,'Use at least8 independent pairs for improvement assertions');
const experiment=path.resolve(option('output','.runtime/performance/risk-compaction-'+Date.now())),root=experiment+'/comparison';
assert.equal(fs.existsSync(experiment),false,'Use a fresh output directory');fs.mkdirSync(experiment,{recursive:true,mode:0o700});
const hashFile=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const plan={...{"epochsPerCase":8,"blocksPerSidePerCase":16,"engineRoundsPerBlock":8,"engineRoundsPerSide":128,"sessions":16,"storage":["ascii-native","mixed-native","ascii-cocoa","mixed-cocoa"],"policyWorkloads":["short-negative","long-negative","unicode-negative","foreign-negative","late-positive","unicode-positive","read-only-candidate","short-positive","single-token-negative","blank-ascii"],"engineGates":{"asciiNativeUnchangedCPUmaxRatio":0.8,"asciiNativeUnchangedWallMaxRatio":0.9,"asciiNativeChangedCPUmaxRatio":1,"asciiNativeChangedWallMaxRatio":1.05,"otherCPUmaxRatio":1.05,"otherWallMaxRatio":1.1,"maximumRSSRatio":1.1,"maximumRSSAllowanceBytes":1048576},"policyGates":{"shortNegativeCPU":0.8,"shortNegativeWall":1,"longNegativeCPU":0.5,"longNegativeWall":0.7,"controlCPU":1.1,"controlWall":1.15,"maximumRSSRatio":1.1,"maximumRSSAllowanceBytes":1048576,"singleTokenCPU":0.6,"singleTokenWall":0.8,"blankCPU":0.5,"blankWall":0.7},"gateCount":38,"estimator":"For each independent process pair/case, median of8 temporally paired ABBA/BAAB CPU and wall ratios. Final ratio is the median of8 independent pair estimates. Absolute CPU/wall totals are also reported separately. No sample exclusions.","scope":"Actual Core synthetic engine/policy comparison. No original terminal input/read/capture/listener. CPU/wall and process maxRSS are not whole-app/phone measurements; scheduling variation remains."},pairs,processes:pairs*4,priorTimedSamplesReused:0,diagnosticOnly:pairs<8};
const fixtureFiles={'engine':'Tests/fixtures/risk-compaction-engine-bench.swift','policy':'Tests/fixtures/risk-compaction-policy-bench.swift'};
for(const[kind,file]of Object.entries(fixtureFiles))fs.copyFileSync(file,experiment+(kind==='engine'?'/window-engine-plain.swift':'/window-policy.swift'));
plan.engineFixtureSHA256=hashFile(experiment+'/window-engine-plain.swift');plan.policyFixtureSHA256=hashFile(experiment+'/window-policy.swift');
fs.writeFileSync(experiment+'/window-protocol.json',JSON.stringify(plan,null,2)+'\n',{mode:0o600});
// These two integrity anchors describe the generic run, not a private release.
fs.writeFileSync(experiment+'/plan.json',JSON.stringify({engineGates:plan.engineGates})+'\n',{mode:0o600});
fs.writeFileSync(experiment+'/policy-plan.json',JSON.stringify({policyGates:plan.policyGates})+'\n',{mode:0o600});
plan.originalPlanSHA256=hashFile(experiment+'/plan.json');plan.originalPolicyPlanSHA256=hashFile(experiment+'/policy-plan.json');
fs.writeFileSync(experiment+'/window-protocol.json',JSON.stringify(plan,null,2)+'\n',{mode:0o600});
const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');fs.mkdirSync(cache,{recursive:true});
for(const label of ['baseline','candidate']){
 const build=path.resolve(option(label==='baseline'?'reference-build':'candidate-build'));
 const coreObjects=Object.fromEntries(fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>[name,hashFile(build+'/AutoApproveCore.build/'+name)]));
 const moduleSHA256=hashFile(build+'/Modules/AutoApproveCore.swiftmodule'),links=await coreLinkArguments(build),linkObjects=Object.fromEntries(links.filter(file=>file.endsWith('.o')).map(file=>[file,hashFile(file)]));
 for(const kind of ['engine','policy']){
  const stem=label+(kind==='engine'?'-window-plain':'-policy-window'),fixture=experiment+(kind==='engine'?'/window-engine-plain.swift':'/window-policy.swift');
  const log=fs.openSync(experiment+'/'+stem+'-compile.log','wx',0o600),start=performance.now();
  const child=spawn('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-name','profile','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...Object.keys(coreObjects).map(name=>build+'/AutoApproveCore.build/'+name),fixture,'-o',experiment+'/'+stem],{stdio:['ignore',log,log]});
  const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}));});fs.closeSync(log);
  fs.writeFileSync(experiment+'/'+stem+'-compile-job.json',JSON.stringify({...result,seconds:(performance.now()-start)/1000})+'\n',{mode:0o600});assert.equal(result.code,0,'See preserved compiler log');
  for(const[name,digest]of Object.entries(coreObjects))assert.equal(hashFile(build+'/AutoApproveCore.build/'+name),digest,name);assert.equal(hashFile(build+'/Modules/AutoApproveCore.swiftmodule'),moduleSHA256);
  fs.writeFileSync(experiment+'/'+stem+'-provenance.json',JSON.stringify({build,coreObjects,moduleSHA256,linkObjects,binarySHA256:hashFile(experiment+'/'+stem),fixtureSHA256:hashFile(fixture),inputs:{}},null,2)+'\n',{mode:0o600});
 }
}

fs.mkdirSync(root,{mode:0o700});for(const kind of ['engine','policy'])fs.mkdirSync(root+'/'+kind,{mode:0o700});
const proofs={},expected=new Map(),sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
for(const label of ['baseline','candidate'])for(const kind of ['engine','policy']){
 const name=kind==='engine'?label+'-window-plain':label+'-policy-window';
 const proof=JSON.parse(fs.readFileSync(experiment+'/'+name+'-provenance.json'));proof.binary=path.resolve(experiment+'/'+name);proofs[label+'-'+kind]=proof;
 expected.set(proof.binary,proof.binarySHA256);expected.set(proof.build+'/Modules/AutoApproveCore.swiftmodule',proof.moduleSHA256);
 for(const[name,digest]of Object.entries(proof.coreObjects))expected.set(proof.build+'/AutoApproveCore.build/'+name,digest);
 for(const[file,digest]of Object.entries(proof.linkObjects))expected.set(file,digest);
}
for(const[file,digest]of Object.entries(proofs['candidate-engine'].inputs))expected.set(path.resolve(file),digest);
expected.set(experiment+'/window-engine-plain.swift',plan.engineFixtureSHA256);expected.set(experiment+'/window-policy.swift',plan.policyFixtureSHA256);
expected.set(experiment+'/plan.json',plan.originalPlanSHA256);expected.set(experiment+'/policy-plan.json',plan.originalPolicyPlanSHA256);
expected.set(experiment+'/window-protocol.json',sha(experiment+'/window-protocol.json'));
const fullVerify=()=>{for(const[file,digest]of expected)assert.equal(sha(file),digest,file);};
const stat=file=>{const value=fs.statSync(file,{bigint:true});return[value.dev,value.ino,value.size,value.mtimeNs,value.ctimeNs].map(String).join(':');};
fullVerify();const metadata=new Map([...expected.keys()].map(file=>[file,stat(file)]));
const verify=()=>{for(const[file,value]of metadata)assert.equal(stat(file),value,'Input changed: '+file);};
const totalRounds={'short-negative':20000,'long-negative':1000,'unicode-negative':1000,'foreign-negative':1000,'late-positive':1000,'unicode-positive':10000,'read-only-candidate':10000,'short-positive':10000,'single-token-negative':1000,'blank-ascii':100};
const all=[],preparations=[];
fs.writeFileSync(root+'/started.json',JSON.stringify({at:new Date().toISOString(),pairs:plan.pairs,processes:plan.pairs*4,protocolSHA256:sha(experiment+'/window-protocol.json'),priorTimedSamplesReused:0})+'\n',{flag:'wx',mode:0o600});
for(let pair=0;pair<plan.pairs;pair++)for(const suite of pair%2?['policy','engine']:['engine','policy']){
 verify();const endpoints={};
 for(const [side,label]of [['A','baseline'],['B','candidate']]){const Endpoint=endpointFactory(proofs[label+'-'+suite].binary,root+'/'+suite);endpoints[side]=new Endpoint(pair,label);}
 try{
  const groups=suite==='engine'?[...plan.storage.slice(pair%4),...plan.storage.slice(0,pair%4)]:['policy'];
  for(const group of groups){
   const ready=await Promise.all(['A','B'].map(async side=>{const request=suite==='engine'?{op:'setup',kind:group,state:path.resolve(root+'/state-'+pair+'-'+side+'/'+group)}:{op:'setup'};const response=await endpoints[side].request(request);assert.equal(response.op,'ready');return{pair,suite,side,...response};}));
   if(suite==='engine'){
    for(const row of ready){assert.equal(row.result.foreignFrames,group.endsWith('cocoa')?32:0);assert.deepEqual(row.result.phaseCounts,{working:4,approval:4,input:4,idle:4});assert.deepEqual(row.result.nativeOwnerKeys,group.endsWith('cocoa')?[0,0]:[16,16]);}
   }else{
    for(const row of ready){assert.equal(row.workloads.length,10);for(const value of row.workloads){assert.equal(value.rounds,totalRounds[value.name]);assert.equal(value.foreign,value.name==='foreign-negative');}}
    assert.deepEqual(ready[0].workloads,ready[1].workloads);
   }
   preparations.push(...ready);
   const names=suite==='engine'?['unchanged-screens','changing-screens']:[...plan.policyWorkloads.slice(pair%10),...plan.policyWorkloads.slice(0,pair%10)];
   for(const name of names){
    verify();const counters={A:0,B:0};
    for(let epoch=0;epoch<8;epoch++){
     const order=(pair+epoch)%2?['B','A','A','B']:['A','B','B','A'],blocks={A:[],B:[]};
     for(const side of order){
      const index=counters[side]++,total=suite==='engine'?128:totalRounds[name];
      const rounds=Math.floor((index+1)*total/16)-Math.floor(index*total/16);
      const command=suite==='engine'?{op:'measure',changed:name==='changing-screens',rounds}:{op:'measure',name,rounds};
      const response=await endpoints[side].request(command);assert.equal(response.op,'measured');const row=response.result;
      assert.equal(row.rounds,rounds);assert.equal(row.name,name);assert.ok(row.cpuSeconds>0&&row.wallSeconds>0);
      if(suite==='engine'){
       assert.equal(row.kind,group);assert.equal(row.sessions,16);assert.equal(row.reads.calls,rounds);assert.equal(row.reads.requested,rounds*16);
       assert.equal(row.publications,name==='changing-screens'?rounds:0);assert.deepEqual(row.phaseCounts,{working:4,approval:4,input:4,idle:4});
      }else{assert.equal(row.matches,rounds);assert.equal(row.foreign,name==='foreign-negative');}
      blocks[side].push(row);
     }
     const totals=Object.fromEntries(['A','B'].map(side=>[side,{rounds:blocks[side].reduce((sum,row)=>sum+row.rounds,0),cpu:blocks[side].reduce((sum,row)=>sum+row.cpuSeconds,0),wall:blocks[side].reduce((sum,row)=>sum+row.wallSeconds,0)}]));
     assert.equal(totals.A.rounds,totals.B.rounds);
     all.push({pair,suite,kind:group,name,epoch,order,blocks,totals,cpuRatio:totals.B.cpu/totals.A.cpu,wallRatio:totals.B.wall/totals.A.wall});
    }
   }
  }
  await Promise.all(['A','B'].map(side=>endpoints[side].close()));verify();
  const completed=all.filter(row=>row.pair===pair&&row.suite===suite);
  fs.writeFileSync(root+'/'+pair+'-'+suite+'-windows.json',JSON.stringify(completed,null,2)+'\n',{flag:'wx',mode:0o600});
  fs.writeFileSync(root+'/preparations.json',JSON.stringify(preparations,null,2)+'\n',{mode:0o600});
  console.log(JSON.stringify({pair,suite,completedProcesses:(pair*2+(suite===(pair%2?'engine':'policy')?2:1))*2,total:plan.pairs*4,windows:completed.length,statesPoliciesAndReadsMatched:true}));
 }catch(error){for(const endpoint of Object.values(endpoints))endpoint.abort();throw error;}
}
const median=values=>{const sorted=[...values].sort((a,b)=>a-b),mid=Math.floor(sorted.length/2);return sorted.length%2?sorted[mid]:(sorted[mid-1]+sorted[mid])/2;};
function rowFor(suite,kind,name,cpuLimit,wallLimit){
 const pairs=[];for(let pair=0;pair<plan.pairs;pair++){
  const values=all.filter(row=>row.pair===pair&&row.suite===suite&&row.kind===kind&&row.name===name);assert.equal(values.length,8);
  const metrics=Object.fromEntries(['A','B'].map(side=>[side,{rounds:values.reduce((sum,row)=>sum+row.totals[side].rounds,0),cpu:values.reduce((sum,row)=>sum+row.totals[side].cpu,0),wall:values.reduce((sum,row)=>sum+row.totals[side].wall,0)}]));
  assert.equal(metrics.A.rounds,suite==='engine'?128:totalRounds[name]);assert.equal(metrics.A.rounds,metrics.B.rounds);
  pairs.push({pair,cpuRatio:median(values.map(row=>row.cpuRatio)),wallRatio:median(values.map(row=>row.wallRatio)),...metrics});
 }
 const cpuRatio=median(pairs.map(row=>row.cpuRatio)),wallRatio=median(pairs.map(row=>row.wallRatio));
 return{suite,kind,name,pairs,cpuRatio,wallRatio,cpuLimit,wallLimit,passed:cpuRatio<=cpuLimit&&wallRatio<=wallLimit,baseline:{cpu:median(pairs.map(row=>row.A.cpu)),wall:median(pairs.map(row=>row.A.wall))},candidate:{cpu:median(pairs.map(row=>row.B.cpu)),wall:median(pairs.map(row=>row.B.wall))}};
}
const engineRows=plan.storage.flatMap(kind=>['unchanged-screens','changing-screens'].map(name=>{const g=plan.engineGates,ascii=kind==='ascii-native',changed=name==='changing-screens';return rowFor('engine',kind,name,ascii?(changed?g.asciiNativeChangedCPUmaxRatio:g.asciiNativeUnchangedCPUmaxRatio):g.otherCPUmaxRatio,ascii?(changed?g.asciiNativeChangedWallMaxRatio:g.asciiNativeUnchangedWallMaxRatio):g.otherWallMaxRatio);}));
const policyRows=plan.policyWorkloads.map(name=>{const g=plan.policyGates;return rowFor('policy','policy',name,name==='short-negative'?g.shortNegativeCPU:name==='long-negative'?g.longNegativeCPU:name==='single-token-negative'?g.singleTokenCPU:name==='blank-ascii'?g.blankCPU:g.controlCPU,name==='short-negative'?g.shortNegativeWall:name==='long-negative'?g.longNegativeWall:name==='single-token-negative'?g.singleTokenWall:name==='blank-ascii'?g.blankWall:g.controlWall);});
const memory={};for(const suite of ['engine','policy']){
 const values=Object.fromEntries(['A','B'].map(side=>[side,Math.max(...all.filter(row=>row.suite===suite).flatMap(row=>row.blocks[side].map(block=>block.peakResidentBytes)))]));
 const g=suite==='engine'?plan.engineGates:plan.policyGates,limit=Math.max(values.A*g.maximumRSSRatio,values.A+g.maximumRSSAllowanceBytes);
 memory[suite]={baseline:values.A,candidate:values.B,limit,passed:values.B<=limit};
}
verify();fullVerify();
const result={passed:[...engineRows,...policyRows].every(row=>row.passed)&&Object.values(memory).every(row=>row.passed),diagnosticOnly:plan.diagnosticOnly,engineRows,policyRows,memory,processes:plan.pairs*4,pairsPerSuite:plan.pairs,gateCount:38,windows:all.length,protocolSHA256:sha(experiment+'/window-protocol.json'),priorTimedSamplesReused:0,originalTerminalActions:0,realPowerCommands:0};
fs.writeFileSync(root+'/comparison.json',JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({passed:result.passed,gateCount:38,failedRows:[...engineRows,...policyRows].filter(row=>!row.passed).map(row=>({suite:row.suite,kind:row.kind,name:row.name,cpuRatio:row.cpuRatio,wallRatio:row.wallRatio})),memory,processes:plan.pairs*4,windows:all.length}));if(assertImproved&&!result.passed)process.exitCode=1;
