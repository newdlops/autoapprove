// Compare cell normalization and classification with the immutable 0.2.166
// source. Synthetic inputs only; no terminal, service, or network operations.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';

const build=path.resolve(process.env.AUTOAPPROVE_QA_BUILD||'.build/release');
const out=process.env.AUTOAPPROVE_QA_OUTPUT?path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT):fs.mkdtempSync(path.join(os.tmpdir(),'aa-capacity-cell-'));
fs.mkdirSync(out,{recursive:true});
const file='Sources/AutoApproveCore/CapacityResume.swift';
const old=execFileSync('git',['-c','core.fsmonitor=false','show','v0.2.166:'+file],{encoding:'utf8'});
const current=fs.readFileSync(file,'utf8'),sha=value=>createHash('sha256').update(value).digest('hex');
assert.equal(sha(old),'38c8dc9b396be4f3400049b5c9665d977dce25acf8e2ac138505de10ec3d9b8d');
function cell(source,name){
 const start=source.indexOf('        let cell = end.map'),end=source.indexOf('\n        let kind:',start);
 assert.ok(start>=0&&end>start);
 const helperStart=source.indexOf('    @inline(never)\n    private static func normalizedErrorCell(');
 const helperEnd=source.indexOf('    private static func errorKind(',helperStart);
 const helper=helperStart<0?'':source.slice(helperStart,helperEnd);
 return 'enum '+name+' {\n    @inline(never) static func normalize(_ lines: [String], start: Int, end: Int?, agent: AgentKind) -> String {\n'+source.slice(start,end)+'\n        return cell\n    }\n'+helper+'}\n';
}
function classifier(source,name){
 const begin=source.indexOf('    private static func errorKind('),end=source.indexOf('\n}\n\npublic enum ResumeDelivery',begin);
 assert.ok(begin>=0&&end>begin);
 return 'enum '+name+' {\n    static let message = CodexCapacityStop.message\n'+source.slice(begin,end).replace('    private static func errorKind','    @inline(never) static func classify')+'\n}\n';
}
const classifiers=classifier(old,'BaselineCapacityCellClassifier')+classifier(current,'CandidateCapacityCellClassifier');
const fixture=fs.readFileSync('Tests/fixtures/capacity-cell-check.swift','utf8');
const generated='import Foundation\nimport AutoApproveCore\n'+classifiers+cell(old,'BaselineCellProbe')+cell(current,'CandidateCellProbe')+fixture;
const source=out+'/probe.swift',binary=out+'/probe';fs.writeFileSync(source,generated,{flag:'wx',mode:0o600});
const objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort();
const inputs={baselineSource:sha(old),candidateSource:sha(current),fixture:sha(fixture),generated:sha(generated),
 module:sha(fs.readFileSync(build+'/Modules/AutoApproveCore.swiftmodule')),
 coreObjects:Object.fromEntries(objects.map(name=>[name,sha(fs.readFileSync(build+'/AutoApproveCore.build/'+name))]))};
fs.writeFileSync(out+'/inputs.json',JSON.stringify(inputs,null,2)+'\n',{flag:'wx',mode:0o600});
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-name','CapacityCellProbe','-module-cache-path',out+'/module-cache',
 '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...objects.map(name=>build+'/AutoApproveCore.build/'+name),source,'-o',binary],{stdio:'inherit'});
const output=execFileSync(binary,[],{encoding:'utf8',timeout:600000,maxBuffer:8*1024*1024});
fs.writeFileSync(out+'/output.log',output,{flag:'wx',mode:0o600});
const result=JSON.parse(output.trim().split('\n').at(-1));
assert.equal(result.correctnessCases,244104);assert.equal(result.workloads.length,72);
assert.equal(result.originalInputs,0);assert.equal(result.captures,0);assert.equal(result.listeners,0);
assert.equal(sha(fs.readFileSync(file)),inputs.candidateSource);
assert.equal(sha(fs.readFileSync(build+'/Modules/AutoApproveCore.swiftmodule')),inputs.module);
for(const[name,digest]of Object.entries(inputs.coreObjects))assert.equal(sha(fs.readFileSync(build+'/AutoApproveCore.build/'+name)),digest);
fs.writeFileSync(out+'/result.json',JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({passed:true,cases:result.correctnessCases,recognized:result.recognizedCases,digest:result.resultSHA256,
 conditions:result.workloads.length,output:out,scope:'Cell oracle and helper timings only. Complete Core adoption requires separate fresh process comparisons.'}));
