import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const output=path.resolve('.runtime/screen-display-equality-check',label),binary=path.join(output,'check');
await mkdir(output,{recursive:true,mode:0o700});
const fixture='Tests/fixtures/screen-display-equality-check.swift',sha=b=>createHash('sha256').update(b).digest('hex');
let provenance;
if(process.argv.includes('--reuse-binary')){
 provenance=JSON.parse(await readFile(path.join(output,'provenance.json'),'utf8'));
 assert.equal(provenance.fixtureSHA256,sha(await readFile(fixture)));assert.equal(provenance.binarySHA256,sha(await readFile(binary)));
}else{
 const baseline=option('baseline');assert.ok(!baseline||!option('source'),'Choose one provider');
 const source=baseline??option('source','Sources/AutoApproveCore/ScreenTextEquality.swift'),contents=await readFile(source,'utf8');
 let provider=contents;
 if(baseline){
  const clause=contents.match(/if (previousFrame\?\.raw != raw) \|\| previousFrame\?\.generation != generation/);assert.ok(clause,'Expected the actual production notification comparison');
  provider='import Foundation\nstruct PreviousScreenProbe {let raw:String}\nenum ScreenTextEquality {static func equal(_ previous:String?,_ current:String)->Bool {let previousFrame=previous.map(PreviousScreenProbe.init(raw:));let raw=current;return !('+clause[1]+')}}\n';
 }
 const engine=baseline?contents:await readFile(option('engine','Sources/AutoApproveCore/ApprovalEngine.swift'),'utf8');
 const condition=engine.match(/^ *if ([^\n]+) \{ remoteTerminalChanges\[sessionID\]\?\.notify\(\) \}$/m);assert.ok(condition,'Expected the actual notification decision');
 // Equality tokens project the five values consumed by this exact expression;
 // metadata validation itself remains in Core and is not replaced by this probe.
 const bridge='\nstruct FrameChangeProbe {let raw:String;let generation:String;let cursor:String?;let appearance:String?;let display:String?}\nfunc notificationChanged(_ previousFrame:FrameChangeProbe?,raw:String,generation:String,cursor:String?,appearance:String?,display:String?,screenContentsUnchanged:Bool = false)->Bool {return '+condition[1]+'}\n';
 const generated=path.join(output,'ScreenDisplayEqualityCheck.swift'),text=provider+bridge+'\n'+await readFile(fixture,'utf8');await writeFile(generated,text);
 const cache=path.resolve('.build/cache/ScreenDisplayEqualityCheck');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,generated,'-o',binary],{stdio:'inherit',timeout:120000});
 provenance={provider:baseline?'actual-notification-clause':'complete-production-helper',sourceSHA256:sha(contents),engineSourceSHA256:sha(engine),fixtureSHA256:sha(await readFile(fixture)),generatedSHA256:sha(text),binarySHA256:sha(await readFile(binary))};
 await writeFile(path.join(output,'provenance.json'),JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
}
const value=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:90000,maxBuffer:4*1024*1024}));
const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
const report={label,...value,workloads:value.workloads.map(w=>({...w,cpuSeconds:median(w.trials.map(t=>t.cpuSeconds)),wallSeconds:median(w.trials.map(t=>t.wallSeconds))})),provenance};
await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({label,correctnessCases:value.correctnessCases,resultSHA256:value.resultSHA256,provenance,workloads:report.workloads.filter(w=>w.lines===512&&!w.changed).map(({trials,...w})=>w)}));
const reference=option('reference');if(reference){const old=JSON.parse(await readFile(reference,'utf8'));assert.equal(value.correctnessCases,old.correctnessCases);assert.equal(value.resultSHA256,old.resultSHA256);assert.equal(provenance.fixtureSHA256,old.provenance.fixtureSHA256);}
if(process.argv.includes('--assert-efficient')){
 const matching=w=>w.pattern==='nfd'&&w.lines===512&&w.change==='tail';
 const native=report.workloads.find(w=>matching(w)&&w.storage==='native');
 for(const storage of ['cocoa','foreign','native-cocoa','cocoa-native']){
  const row=report.workloads.find(w=>matching(w)&&w.storage===storage);assert.ok(!row.lhsContiguousUTF8||!row.rhsContiguousUTF8,'The foreign storage must be real');
  assert.ok(row.cpuSeconds<native.cpuSeconds*5+.004,storage+': late changes in foreign display frames must not normalize the entire common prefix');
 }
}
if(process.argv.includes('--assert-head-efficient')){
 for(const row of report.workloads.filter(w=>w.lines===512&&w.change==='head')){
  assert.ok(row.cpuSeconds<.00015,row.storage+': early ASCII differences must retain cheap rejection');
 }
}
