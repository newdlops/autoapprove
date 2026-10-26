import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {coreLinkArguments} from './swift-core-link.mjs';

// This is the original ordering-policy reference, not the optimized product
// helper. The worker links and exercises the real compiled Core.
const referencePolicy = "import Foundation\nimport AutoApproveCore\n@MainActor enum BoundOriginalOrder {\n    static func apply(rows: [AgentSession], ranks: [String:Int], projects: [String:String]) -> [AgentSession] {\n        let presented = rows.sorted {\n            if ($0.phase == .ended) != ($1.phase == .ended) { return $0.phase != .ended }\n            let left = ranks[$0.id] ?? Int.max, right = ranks[$1.id] ?? Int.max\n            if left != right { return left < right }\n            let leftProject = projects[$0.id] ?? $0.project, rightProject = projects[$1.id] ?? $1.project\n            if leftProject != rightProject { return leftProject.localizedStandardCompare(rightProject) == .orderedAscending }\n            return $0.id < $1.id\n        }\n        return presented\n    }\n}\n";
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fixture=path.resolve(option('fixture','Tests/fixtures/presentation-order-check.swift'));
const shared=path.resolve(option('shared-fixture','Tests/fixtures/screen-session-publication-check.swift'));
const parent=path.resolve('.runtime/presentation-order-check');fs.mkdirSync(parent,{recursive:true,mode:0o700});
const out=fs.mkdtempSync(parent+'/run-'),cache=path.resolve(option('cache',out+'/module-cache'));
const hashes={[fixture]:sha(fixture),[shared]:sha(shared),[import.meta.filename]:sha(import.meta.filename)};
const verify=()=>{for(const[file,digest]of Object.entries(hashes))assert.equal(sha(file),digest,file)};
const save=(name,value)=>fs.writeFileSync(out+'/'+name,JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});
const original=fs.readFileSync(shared,'utf8'),marker='@main enum ScreenSessionCompareWorker';
assert.equal(original.split(marker).length,2);
const helper=out+'/helper.swift',reference=out+'/reference.swift';
fs.writeFileSync(helper,original.replace(marker,'enum ScreenSessionCompareWorker'),{flag:'wx',mode:0o600});
fs.writeFileSync(reference,referencePolicy,{flag:'wx',mode:0o600});hashes[helper]=sha(helper);hashes[reference]=sha(reference);
const variants={candidate:{build:path.resolve(option('build','.build/release')),source:path.resolve(option('source-root','.'))}};
if(option('baseline-build')){
 assert.ok(option('baseline-source-root'),'Supply source matching baseline build');
 variants.baseline={build:path.resolve(option('baseline-build')),source:path.resolve(option('baseline-source-root'))};
}
for(const[label,value]of Object.entries(variants)){
 const objects=fs.readdirSync(value.build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>value.build+'/AutoApproveCore.build/'+name);
 const links=await coreLinkArguments(value.build);assert.ok(objects.length>0,'Build matching release Core first');
 for(const file of [value.source+'/Sources/AutoApproveCore/ApprovalEngine.swift',value.build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))])hashes[file]=sha(file);
 value.binary=out+'/'+label;value.coreObjects=objects.length;value.moduleSHA256=sha(value.build+'/Modules/AutoApproveCore.swiftmodule');verify();
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,
  '-I',value.build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,helper,reference,fixture,'-o',value.binary],{stdio:'inherit',timeout:300000});
 hashes[value.binary]=sha(value.binary);verify();
}
const environment={...process.env};delete environment.SWIFT_DETERMINISTIC_HASHING;
let sequence=0;
function run(label,args,input){
 verify();const text=execFileSync(variants[label].binary,args,{input,encoding:'utf8',env:environment,timeout:120000,maxBuffer:1048576});verify();
 const rows=text.trim().split('\n').map(JSON.parse);save(label+'-'+args[0]+'-'+(++sequence)+'.json',rows);return rows;
}
const cases={},smokes={},modes=['steady19-unique','steady32-unique','steady96-unique','steady19-shared','steady32-shared','changed-cwd19','empty','single'];
for(const label of Object.keys(variants)){
 const output=out+'/'+label+'-cases.bin';cases[label]=run(label,['cases',output])[0];
 assert.equal(cases[label].passed,true);assert.equal(cases[label].policyChecks,1204);assert.equal(cases[label].quietCases,70);assert.equal(cases[label].groupedProjectionCases,4);
 hashes[output]=sha(output);
 const requests=modes.map(mode=>({id:'public/'+mode,mode,iterations:32}));
 const rows=run(label,['bench'],requests.concat({command:'stop'}).map(value=>JSON.stringify(value)+'\n').join(''));
 const ready=rows.shift();assert.equal(ready.allRepeatedSnapshotsQuiet,true);assert.equal(ready.engineEnsemblePerMode,16);assert.equal(rows.length,8);
 smokes[label]=rows.map((row,index)=>{assert.equal(row.mode,modes[index]);return {mode:row.mode,iterations:row.iterations,checksum:row.checksum}});
}
if(variants.baseline){
 assert.ok(fs.readFileSync(out+'/candidate-cases.bin').equals(fs.readFileSync(out+'/baseline-cases.bin')));
 assert.deepEqual(smokes.candidate,smokes.baseline);
}
verify();
save('report.json',{passed:true,actualCompiledCore:true,policyChecksPerBuild:1204,quietCasesPerBuild:70,groupedProjectionCasesPerBuild:4,
 exactOrderComparedToOriginalPolicyWithinEachProcess:true,fullCurrentPayloadCompared:true,rawUTF8AndUTF16:true,
 crossProcessReceiptOrderOnlySortedByUniqueID:true,baselineComparisonRun:!!variants.baseline,
 fullCrossProcessPayloadBytesMatch:!!variants.baseline,actualCWDUpdateAsserted:true,freshQuestionsCustomizationEndedAndIdentityChecked:true,
 smokeModes:8,independentEnginesPerMode:16,cases,smokes,variants,inputs:hashes,
 originalOrderingPolicyReferenceOnly:true,productionOptimizationNotCopied:true,onlyMainAttributeRemovedFromExistingHelper:true,
 noSpeedOrMemoryImprovementClaimFromSmoke:true,originalTerminalActions:0,realPowerCommands:0});
console.log(JSON.stringify({passed:true,actualCompiledCore:true,policyChecksPerBuild:1204,quietCasesPerBuild:70,groupedCases:4,
 baselineComparisonRun:!!variants.baseline,report:out+'/report.json'}));
