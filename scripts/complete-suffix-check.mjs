// Differential normalization/permission oracle using public release source.
// Synthetic strings only; no original terminal, process, input or settings IO.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const buildOption=option('build');assert.ok(buildOption,'Pass --build=/path/to/a matching .build/release');
const build=path.resolve(buildOption),reference=option('reference','v0.2.170');
const output=fs.mkdtempSync(path.join(os.tmpdir(),'aa-complete-suffix-check-'));
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const files=['ApprovalPrompt.swift','DetectionLines.swift','YesNoConfirmation.swift'];
const names=['ApprovalPrompt','PromptDetector','DetectionLineSuffix','DetectionLines','YesNoConfirmation'];
function rename(source,prefix){for(const name of names)source=source.replaceAll(new RegExp('\\b'+name+'\\b','g'),prefix+name);return source.replace('import Foundation','import Foundation\nimport AutoApproveCore');}
const sources={};
for(const label of ['Reference','Candidate']){
  sources[label]=Object.fromEntries(files.map(name=>{const file='Sources/AutoApproveCore/'+name;return[name,label==='Reference'?execFileSync('git',['-c','core.fsmonitor=false','show',reference+':'+file],{encoding:'utf8'}):fs.readFileSync(file,'utf8')];}));
  fs.writeFileSync(output+'/'+label+'.swift',files.map(name=>rename(sources[label][name],label)).join('\n'),{mode:0o600});
}
const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');fs.mkdirSync(cache,{recursive:true});
const objects=fs.readdirSync(build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>build+'/AutoApproveCore.build/'+name);
const links=await coreLinkArguments(build),tracked=[build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))];
const hashes=Object.fromEntries(tracked.map(file=>[file,sha(fs.readFileSync(file))]));
try{
  execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,output+'/Reference.swift',output+'/Candidate.swift','Tests/fixtures/complete-suffix-check.swift','-o',output+'/check'],{stdio:'inherit',timeout:180000});
  const report=execFileSync(output+'/check',[],{encoding:'utf8',timeout:180000});
  assert.match(report,/COMPLETE_SUFFIX scalars 1112064; storage 2253; prompts 1920; accepted 768; foreign 364; checksum 16066818104591319445/);
  for(const [file,digest]of Object.entries(hashes))assert.equal(sha(fs.readFileSync(file)),digest,file);
  for(const name of files)assert.equal(fs.readFileSync('Sources/AutoApproveCore/'+name,'utf8'),sources.Candidate[name],name);
  console.log(report.trim());console.log(JSON.stringify({reference,sourceHashes:Object.fromEntries(Object.entries(sources).map(([label,values])=>[label,Object.fromEntries(files.map(name=>[name,sha(Buffer.from(values[name]))]))])),coreObjects:objects.length,originalTerminalActions:0}));
}finally{fs.rmSync(output,{recursive:true,force:true});}
