// Differential exact-compaction/policy oracle. Synthetic strings/files only.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
assert.ok(option('build'),'Pass --build=/path/to/matching/.build/release');
const build=path.resolve(option('build')),reference=option('reference','v0.2.171'),output=fs.mkdtempSync(path.join(os.tmpdir(),'aa-risk-compaction-'));
const sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const files=['SystemCommandRisk.swift','RiskCandidateMatcher.swift'],sourceHashes={};
const tracked=[build+'/Modules/AutoApproveCore.swiftmodule'];
const objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>build+'/AutoApproveCore.build/'+name),links=await coreLinkArguments(build);
tracked.push(...objects,...links.filter(file=>file.endsWith('.o')));const frozen=Object.fromEntries(tracked.map(file=>[file,sha(file)]));
try{
 for(const label of ['Reference','Candidate']){
  const sources=files.map(name=>{const file='Sources/AutoApproveCore/'+name;return label==='Reference'?execFileSync('git',['-c','core.fsmonitor=false','show',reference+':'+file],{encoding:'utf8'}):fs.readFileSync(file,'utf8');});
  sourceHashes[label]=Object.fromEntries(files.map((name,index)=>[name,createHash('sha256').update(sources[index]).digest('hex')]));
  let source='import Foundation\nimport AutoApproveCore\n'+sources.join('\n');
  source=source.replaceAll(/\bSystemCommandRisk\b/g,label+'Risk').replaceAll(/\bRiskCandidateMatcher\b/g,label+'Matcher');
  source+='\nextension '+label+'Risk {\n static func oracleWords()->[String] {riskCandidateWords}\n static func oracleCompact(_ raw:String)->String {removingWhitespace(raw)}\n}\n';
  fs.writeFileSync(output+'/'+label+'.swift',source,{mode:0o600});
 }
 const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');fs.mkdirSync(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,output+'/Reference.swift',output+'/Candidate.swift','Tests/fixtures/risk-compaction-check.swift','-o',output+'/check'],{stdio:'inherit',timeout:180000});
 fs.mkdirSync(output+'/files');const report=execFileSync(output+'/check',[output+'/files'],{encoding:'utf8',timeout:180000});
 assert.match(report,/ASCII_COMPACTION triples 2097152; scalars 1112064; policies 6642; tools 2040; normalizations 5480262; foreign 1359; sourceChanges 56; digest f2f98b6bfc54d1c650ab753b7176e20ce16a4de4e2f8f939dfefd709a8faf9ae/);
 for(const[file,digest]of Object.entries(frozen))assert.equal(sha(file),digest,file);
 for(const name of files)assert.equal(sha('Sources/AutoApproveCore/'+name),sourceHashes.Candidate[name],name);
 console.log(report.trim());console.log(JSON.stringify({reference,sourceHashes,coreObjects:objects.length,originalTerminalActions:0}));
}finally{fs.rmSync(output,{recursive:true,force:true});}
