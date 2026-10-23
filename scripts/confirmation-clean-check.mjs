// Differential cleanup and permission oracle. Synthetic inputs only.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
assert.ok(option('build'),'Pass --build=/path/to/matching/.build/release');
const build=path.resolve(option('build')),reference=option('reference','v0.2.172');assert.match(reference,/^[A-Za-z0-9][A-Za-z0-9._/-]*$/);
const output=fs.mkdtempSync(path.join(os.tmpdir(),'aa-confirmation-clean-')),sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const file='Sources/AutoApproveCore/YesNoConfirmation.swift',objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>build+'/AutoApproveCore.build/'+name),links=await coreLinkArguments(build);
const tracked=[build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))],frozen=Object.fromEntries(tracked.map(file=>[file,sha(file)]));
const sources={Reference:execFileSync('git',['-c','core.fsmonitor=false','show',reference+':'+file],{encoding:'utf8'}),Candidate:fs.readFileSync(file,'utf8')};
const sourceHashes=Object.fromEntries(Object.entries(sources).map(([label,text])=>[label,createHash('sha256').update(text).digest('hex')]));
try{
 for(const[label,text]of Object.entries(sources)){
  const source='import AutoApproveCore\n'+text.replaceAll(/\bYesNoConfirmation\b/g,label+'Confirmation')+'\nextension '+label+'Confirmation {\n static func oracleClean(_ value:String)->String {cleaned(value)}\n'+(label==='Candidate'?' static func oracleFast(_ value:String)->Bool {isUnchangedASCII(value)}\n':'')+'}\n';
  fs.writeFileSync(output+'/'+label+'.swift',source,{mode:0o600});
 }
 const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');fs.mkdirSync(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,output+'/Reference.swift',output+'/Candidate.swift','Tests/fixtures/confirmation-clean-check.swift','-o',output+'/check'],{stdio:'inherit',timeout:180000});
 const report=execFileSync(output+'/check',[],{encoding:'utf8',timeout:180000}).trim();
 assert.match(report,/^YESNO_ORACLE normalizations \d+; fast \d+; foreign \d+; scalarExclusions 1111936; scalarProbes 3335808; menus \d+; nonIdempotent \d+; digest \d+$/);
 for(const[file,digest]of Object.entries(frozen))assert.equal(sha(file),digest,file);assert.equal(sha(file),sourceHashes.Candidate);
 console.log(report);console.log(JSON.stringify({reference,sourceHashes,coreObjects:objects.length,originalTerminalActions:0}));
}finally{fs.rmSync(output,{recursive:true,force:true});}
