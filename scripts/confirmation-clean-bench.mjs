// Synthetic permission/cleanup comparison of matching release builds.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import readline from 'node:readline';
import {coreLinkArguments} from './swift-core-link.mjs';
class Endpoint {
 constructor(binary,root,pair,label){
  this.pair=pair;this.label=label;this.root=root;this.pending=[];this.done=false;
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
  fs.writeFileSync(this.root+'/'+this.pair+'-'+this.label+'-job.json',JSON.stringify(result)+'\n',{flag:'wx',mode:0o600});assert.equal(result.code,0);return result;
 }
 abort(){if(!this.done)this.child.kill('SIGTERM');}
}

const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
assert.ok(option('reference-build')&&option('candidate-build'),'Pass --reference-build=... --candidate-build=...');
const pairs=Number(option('pairs','8'));assert.ok(Number.isInteger(pairs)&&pairs>=1&&pairs<=16);
const assertImproved=process.argv.includes('--assert-improved');if(assertImproved)assert.ok(pairs>=8,'Improvement assertions need at least8 independent pairs');
const reference=option('reference','v0.2.172');assert.match(reference,/^[A-Za-z0-9][A-Za-z0-9._/-]*$/);
const experiment=path.resolve(option('output','.runtime/performance/confirmation-clean-'+Date.now())),root=experiment+'/comparison';
assert.equal(fs.existsSync(experiment),false,'Use a fresh output directory');fs.mkdirSync(experiment,{recursive:true,mode:0o700});
const hashFile=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const sourceFile='Sources/AutoApproveCore/YesNoConfirmation.swift';
const sources={Reference:execFileSync('git',['-c','core.fsmonitor=false','show',reference+':'+sourceFile],{encoding:'utf8'}),Candidate:fs.readFileSync(sourceFile,'utf8')};
for(const[label,text]of Object.entries(sources)){
 const source='import AutoApproveCore\n'+text.replaceAll(/\bYesNoConfirmation\b/g,label+'Confirmation')+'\nextension '+label+'Confirmation {\n static func oracleClean(_ value:String)->String {cleaned(value)}\n}\n';
 fs.writeFileSync(experiment+'/'+label+'.swift',source,{flag:'wx',mode:0o600});
}
for(const label of ['baseline','candidate'])fs.writeFileSync(experiment+'/'+label+'-alias.swift','typealias BenchConfirmation = '+(label==='baseline'?'Reference':'Candidate')+'Confirmation\n',{flag:'wx',mode:0o600});
fs.copyFileSync('Tests/fixtures/risk-compaction-engine-bench.swift',experiment+'/engine.swift');
fs.copyFileSync('Tests/fixtures/confirmation-clean-bench.swift',experiment+'/confirmation.swift');
const originalPlan={...{"epochsPerCase":8,"blocksPerSidePerCase":16,"engineRoundsPerBlock":8,"engineRoundsPerSide":128,"sessions":16,"storage":["ascii-native","mixed-native","ascii-cocoa","mixed-cocoa"],"engineGates":{"asciiNativeChangedCPUmaxRatio":0.98,"asciiNativeChangedWallMaxRatio":1.03,"otherCPUmaxRatio":1.05,"otherWallMaxRatio":1.1,"maximumRSSRatio":1.1,"maximumRSSAllowanceBytes":1048576},"confirmationWorkloads":["plain-short","plain-long","unicode-labels","permission-menus","task-choices"],"confirmationRounds":{"plain-short":16000,"plain-long":4000,"unicode-labels":4000,"permission-menus":2000,"task-choices":2000},"confirmationGates":{"shortCPU":0.6,"shortWall":0.8,"longCPU":0.6,"longWall":0.8,"unicodeCPU":1.1,"unicodeWall":1.15,"permissionCPU":0.85,"permissionWall":0.95,"taskCPU":0.9,"taskWall":0.95,"maximumRSSRatio":1.1,"maximumRSSAllowanceBytes":1048576},"gateCount":28},pairs,processes:pairs*4,windows:pairs*104,diagnosticOnly:pairs<8,reference,
 scope:'Actual Core engine; exact source-copy cleaned microcases; actual Core permission/task cases. Synthetic sessions only; no original terminal or screen access.',
 estimator:'Median of8 ABBA/BAAB window ratios per independent process pair, then median over '+pairs+' pairs per suite. Absolute totals separate; no exclusions.'};
fs.writeFileSync(experiment+'/plan.json',JSON.stringify(originalPlan,null,2)+'\n',{flag:'wx',mode:0o600});
const plan={...originalPlan,planSHA256:hashFile(experiment+'/plan.json'),engineFixtureSHA256:hashFile(experiment+'/engine.swift'),confirmationFixtureSHA256:hashFile(experiment+'/confirmation.swift')};
fs.writeFileSync(experiment+'/protocol.json',JSON.stringify(plan,null,2)+'\n',{flag:'wx',mode:0o600});
async function run(name,binary,args,extraEnvironment={}){
 const log=fs.openSync(experiment+'/'+name+'.log','wx',0o600),start=performance.now();
 const child=spawn(binary,args,{env:{...process.env,...extraEnvironment},stdio:['ignore',log,log]});
 const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}));});fs.closeSync(log);
 fs.writeFileSync(experiment+'/'+name+'-job.json',JSON.stringify({...result,seconds:(performance.now()-start)/1000})+'\n',{flag:'wx',mode:0o600});
 assert.equal(result.code,0,'See preserved '+name+' log');return fs.readFileSync(experiment+'/'+name+'.log','utf8');
}
const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');fs.mkdirSync(cache,{recursive:true});
const oracleOutput=await run('oracle',process.execPath,['scripts/confirmation-clean-check.mjs','--build='+path.resolve(option('candidate-build')),'--reference='+reference],{AUTOAPPROVE_SWIFT_MODULE_CACHE:cache});
const oracleLine=oracleOutput.match(/^YESNO_ORACLE.*$/m)?.[0];assert.ok(oracleLine);
fs.writeFileSync(experiment+'/correctness.json',JSON.stringify({passed:true,output:oracleLine,scope:'Exact source oracle; see oracle log for full coverage and source hashes'})+'\n',{flag:'wx',mode:0o600});
for(const label of ['baseline','candidate']){
 const build=path.resolve(option(label==='baseline'?'reference-build':'candidate-build'));
 const coreObjects=Object.fromEntries(fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>[name,hashFile(build+'/AutoApproveCore.build/'+name)]));
 const links=await coreLinkArguments(build),linkObjects=Object.fromEntries(links.filter(file=>file.endsWith('.o')).map(file=>[file,hashFile(file)])),moduleSHA256=hashFile(build+'/Modules/AutoApproveCore.swiftmodule');
 for(const kind of ['engine','confirmation']){
  const extra=kind==='confirmation'?[experiment+'/'+(label==='baseline'?'Reference':'Candidate')+'.swift',experiment+'/'+label+'-alias.swift']:[];
  await run(label+'-'+kind+'-compile','/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-name','profile','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...Object.keys(coreObjects).map(name=>build+'/AutoApproveCore.build/'+name),...extra,experiment+'/'+kind+'.swift','-o',experiment+'/'+label+'-'+kind]);
  for(const[name,digest]of Object.entries(coreObjects))assert.equal(hashFile(build+'/AutoApproveCore.build/'+name),digest,name);assert.equal(hashFile(build+'/Modules/AutoApproveCore.swiftmodule'),moduleSHA256);
  fs.writeFileSync(experiment+'/'+label+'-'+kind+'-provenance.json',JSON.stringify({build,coreObjects,moduleSHA256,linkObjects,extraInputs:Object.fromEntries(extra.map(file=>[file,hashFile(file)])),binarySHA256:hashFile(experiment+'/'+label+'-'+kind),fixtureSHA256:hashFile(experiment+'/'+kind+'.swift'),inputs:label==='candidate'?{[sourceFile]:hashFile(sourceFile)}:{}},null,2)+'\n',{flag:'wx',mode:0o600});
 }
}
const sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex'),proofs={},expected=new Map();
for(const label of ['baseline','candidate'])for(const suite of ['engine','confirmation']){
 const proof=JSON.parse(fs.readFileSync(experiment+'/'+label+'-'+suite+'-provenance.json'));proof.binary=experiment+'/'+label+'-'+suite;proofs[label+'-'+suite]=proof;
 expected.set(proof.binary,proof.binarySHA256);expected.set(proof.build+'/Modules/AutoApproveCore.swiftmodule',proof.moduleSHA256);
 for(const[name,digest]of Object.entries(proof.coreObjects))expected.set(proof.build+'/AutoApproveCore.build/'+name,digest);
 for(const[file,digest]of Object.entries(proof.linkObjects))expected.set(file,digest);for(const[file,digest]of Object.entries(proof.extraInputs??{}))expected.set(file,digest);
}
for(const[file,digest]of Object.entries(proofs['candidate-engine'].inputs))expected.set(path.resolve(file),digest);
expected.set(experiment+'/engine.swift',plan.engineFixtureSHA256);expected.set(experiment+'/confirmation.swift',plan.confirmationFixtureSHA256);
expected.set(experiment+'/plan.json',plan.planSHA256);expected.set(experiment+'/protocol.json',sha(experiment+'/protocol.json'));
expected.set(experiment+'/correctness.json',sha(experiment+'/correctness.json'));expected.set(path.resolve('scripts/confirmation-clean-bench.mjs'),sha('scripts/confirmation-clean-bench.mjs'));
const fullVerify=()=>{for(const[file,digest]of expected)assert.equal(sha(file),digest,file);};
const stat=file=>{const value=fs.statSync(file,{bigint:true});return[value.dev,value.ino,value.size,value.mtimeNs,value.ctimeNs].map(String).join(':');};
fullVerify();const metadata=new Map([...expected.keys()].map(file=>[file,stat(file)]));
const verify=()=>{for(const[file,value]of metadata)assert.equal(stat(file),value,'Input changed: '+file);};
fs.mkdirSync(root,{mode:0o700});for(const suite of ['engine','confirmation'])fs.mkdirSync(root+'/'+suite,{mode:0o700});
const all=[],preparations=[];
fs.writeFileSync(root+'/started.json',JSON.stringify({at:new Date().toISOString(),processes:plan.pairs*4,protocolSHA256:sha(experiment+'/protocol.json'),priorTimedSamplesReused:0})+'\n',{flag:'wx',mode:0o600});
for(let pair=0;pair<plan.pairs;pair++)for(const suite of pair%2?['confirmation','engine']:['engine','confirmation']){
 verify();const endpoints=Object.fromEntries([['A','baseline'],['B','candidate']].map(([side,label])=>[side,new Endpoint(proofs[label+'-'+suite].binary,root+'/'+suite,pair,label)]));
 try{
  const groups=suite==='engine'?[...plan.storage.slice(pair%4),...plan.storage.slice(0,pair%4)]:['confirmation'];
  for(const group of groups){
   verify();const ready=await Promise.all(['A','B'].map(async side=>{
    const state=root+'/state-'+pair+'-'+side+'/'+group;
    const response=await endpoints[side].request(suite==='engine'?{op:'setup',kind:group,state}:{op:'setup',state});assert.equal(response.op,'ready');return{pair,suite,side,...response};
   }));
   if(suite==='engine')for(const row of ready){
    assert.equal(row.result.foreignFrames,group.endsWith('cocoa')?32:0);assert.deepEqual(row.result.phaseCounts,{working:4,approval:4,input:4,idle:4});assert.deepEqual(row.result.nativeOwnerKeys,group.endsWith('cocoa')?[0,0]:[16,16]);
   }else for(const row of ready){assert.deepEqual(row.workloads,plan.confirmationRounds);assert.ok(row.scope.includes('actual linked Core'));}
   preparations.push(...ready);
   const cases=suite==='engine'?['unchanged-screens','changing-screens']:plan.confirmationWorkloads;
   for(let caseIndex=0;caseIndex<cases.length;caseIndex++){
    verify();const name=cases[caseIndex],completed={A:0,B:0},blockCounts={A:0,B:0};
    for(let epoch=0;epoch<8;epoch++){
     const order=(pair+epoch+caseIndex)%2?['B','A','A','B']:['A','B','B','A'],blocks={A:[],B:[]};
     for(const side of order){
      const total=suite==='engine'?128:plan.confirmationRounds[name],block=blockCounts[side]++,rounds=suite==='engine'?8:Math.floor(total/16)+(block<total%16?1:0),offset=completed[side];
      const request=suite==='engine'?{op:'measure',changed:name==='changing-screens',rounds}:{op:'measure',name,rounds,offset};
      const response=await endpoints[side].request(request);assert.equal(response.op,'measured');const row=response.result;
      assert.equal(row.rounds,rounds);assert.equal(row.name,name);assert.ok(row.cpuSeconds>0&&row.wallSeconds>0);
      if(suite==='engine'){
       assert.equal(row.kind,group);assert.equal(row.sessions,16);assert.equal(row.reads.calls,rounds);assert.equal(row.reads.requested,rounds*16);
       assert.equal(row.publications,name==='changing-screens'?rounds:0);assert.deepEqual(row.phaseCounts,{working:4,approval:4,input:4,idle:4});
      }else{
       assert.equal(row.matches,rounds);assert.equal(row.offset,offset);assert.ok(Number.isSafeInteger(row.checksum));
      }
      completed[side]+=rounds;blocks[side].push(row);
     }
     const totals=Object.fromEntries(['A','B'].map(side=>[side,{rounds:blocks[side].reduce((sum,row)=>sum+row.rounds,0),cpu:blocks[side].reduce((sum,row)=>sum+row.cpuSeconds,0),wall:blocks[side].reduce((sum,row)=>sum+row.wallSeconds,0)}]));
     assert.equal(totals.A.rounds,totals.B.rounds);if(suite==='confirmation')assert.equal(blocks.A.reduce((s,r)=>s+r.checksum,0),blocks.B.reduce((s,r)=>s+r.checksum,0));
     all.push({pair,suite,kind:group,name,epoch,order,blocks,totals,cpuRatio:totals.B.cpu/totals.A.cpu,wallRatio:totals.B.wall/totals.A.wall});
    }
    assert.equal(completed.A,suite==='engine'?128:plan.confirmationRounds[name]);assert.equal(completed.A,completed.B);
   }
  }
  await Promise.all(Object.values(endpoints).map(endpoint=>endpoint.close()));verify();
  const rows=all.filter(row=>row.pair===pair&&row.suite===suite);
  fs.writeFileSync(root+'/'+pair+'-'+suite+'-windows.json',JSON.stringify(rows,null,2)+'\n',{flag:'wx',mode:0o600});
  fs.writeFileSync(root+'/preparations.json',JSON.stringify(preparations,null,2)+'\n',{mode:0o600});
  console.log(JSON.stringify({pair,suite,completedProcesses:(pair*2+(suite===(pair%2?'engine':'confirmation')?2:1))*2,total:plan.pairs*4,windows:rows.length,exactStatesPoliciesAndReads:true}));
 }catch(error){for(const endpoint of Object.values(endpoints))endpoint.abort();throw error;}
}
const median=values=>{const sorted=[...values].sort((a,b)=>a-b),mid=Math.floor(sorted.length/2);return sorted.length%2?sorted[mid]:(sorted[mid-1]+sorted[mid])/2;};
function rowFor(suite,kind,name,cpuLimit,wallLimit){
 const pairs=[];for(let pair=0;pair<plan.pairs;pair++){
  const values=all.filter(row=>row.pair===pair&&row.suite===suite&&row.kind===kind&&row.name===name);assert.equal(values.length,8);
  const metrics=Object.fromEntries(['A','B'].map(side=>[side,{rounds:values.reduce((sum,row)=>sum+row.totals[side].rounds,0),cpu:values.reduce((sum,row)=>sum+row.totals[side].cpu,0),wall:values.reduce((sum,row)=>sum+row.totals[side].wall,0)}]));
  assert.equal(metrics.A.rounds,suite==='engine'?128:plan.confirmationRounds[name]);assert.equal(metrics.A.rounds,metrics.B.rounds);
  pairs.push({pair,cpuRatio:median(values.map(row=>row.cpuRatio)),wallRatio:median(values.map(row=>row.wallRatio)),...metrics});
 }
 const cpuRatio=median(pairs.map(row=>row.cpuRatio)),wallRatio=median(pairs.map(row=>row.wallRatio));
 return{suite,kind,name,pairs,cpuRatio,wallRatio,cpuLimit,wallLimit,passed:cpuRatio<=cpuLimit&&wallRatio<=wallLimit,baseline:{cpu:median(pairs.map(row=>row.A.cpu)),wall:median(pairs.map(row=>row.A.wall))},candidate:{cpu:median(pairs.map(row=>row.B.cpu)),wall:median(pairs.map(row=>row.B.wall))}};
}
const engineRows=plan.storage.flatMap(kind=>['unchanged-screens','changing-screens'].map(name=>{const g=plan.engineGates,target=kind==='ascii-native'&&name==='changing-screens';return rowFor('engine',kind,name,target?g.asciiNativeChangedCPUmaxRatio:g.otherCPUmaxRatio,target?g.asciiNativeChangedWallMaxRatio:g.otherWallMaxRatio);}));
const limits={'plain-short':['shortCPU','shortWall'],'plain-long':['longCPU','longWall'],'unicode-labels':['unicodeCPU','unicodeWall'],'permission-menus':['permissionCPU','permissionWall'],'task-choices':['taskCPU','taskWall']};
const confirmationRows=plan.confirmationWorkloads.map(name=>rowFor('confirmation','confirmation',name,...limits[name].map(key=>plan.confirmationGates[key])));
const memory={};for(const suite of ['engine','confirmation']){
 const values=Object.fromEntries(['A','B'].map(side=>[side,Math.max(...all.filter(row=>row.suite===suite).flatMap(row=>row.blocks[side].map(block=>block.peakResidentBytes)))]));
 const g=suite==='engine'?plan.engineGates:plan.confirmationGates,limit=Math.max(values.A*g.maximumRSSRatio,values.A+g.maximumRSSAllowanceBytes);
 memory[suite]={baseline:values.A,candidate:values.B,limit,passed:values.B<=limit};
}
verify();fullVerify();assert.equal(all.length,plan.pairs*104);
const result={diagnosticOnly:plan.diagnosticOnly,passed:[...engineRows,...confirmationRows].every(row=>row.passed)&&Object.values(memory).every(row=>row.passed),engineRows,confirmationRows,memory,processes:plan.pairs*4,pairsPerSuite:plan.pairs,gateCount:28,windows:all.length,protocolSHA256:sha(experiment+'/protocol.json'),priorTimedSamplesReused:0,originalTerminalActions:0,realPowerCommands:0};
fs.writeFileSync(root+'/comparison.json',JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({passed:result.passed,gateCount:28,failedRows:[...engineRows,...confirmationRows].filter(row=>!row.passed).map(row=>({suite:row.suite,kind:row.kind,name:row.name,cpuRatio:row.cpuRatio,wallRatio:row.wallRatio})),memory,processes:plan.pairs*4,windows:all.length}));if(assertImproved&&!result.passed)process.exitCode=1;

