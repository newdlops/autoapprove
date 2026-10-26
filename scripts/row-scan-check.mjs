// Exact released-source oracle for row scanning; synthetic strings only.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';
const out=path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT||fs.mkdtempSync(path.join(os.tmpdir(),'aa-row-scan-')));
fs.mkdirSync(out,{recursive:true,mode:0o700});
const sha=value=>createHash('sha256').update(value).digest('hex');
const file='Sources/AutoApproveCore/ApprovalPrompt.swift',fixture='Tests/fixtures/row-scan-normalization-check.swift';
const original=name=>execFileSync('git',['-c','core.fsmonitor=false','show','v0.2.168:'+name],{encoding:'utf8'});
const baseline=original(file),candidate=fs.readFileSync(file,'utf8'),lines=original('Sources/AutoApproveCore/DetectionLines.swift');
const section=source=>{const start=source.indexOf('    public static func normalizedLines('),end=source.indexOf('    static func permissionMarkers(',start);assert.ok(start>=0&&end>start);return source.slice(start,end);};
const variant=(name,normalizer)=>lines.replaceAll('DetectionLineSuffix',name+'Suffix').replaceAll('DetectionLines',name+'Lines').replaceAll('PromptDetector',normalizer);
const common='Tests/fixtures/cocoa-fused-check.swift';
const shared=fs.readFileSync(common,'utf8').replace('let scalarProof = try whitespaceProof()','let added = try NormalizationOracle.run()\n        let scalarProof = try whitespaceProof()').replace('["matched":true,"cases":cases','["matched":true,"normalization":added,"cases":cases');
const generated='enum BaselineNormalize {\n'+section(baseline)+'}\nenum CandidateNormalize {\n'+section(candidate)+'}\n'+variant('Baseline','BaselineNormalize')+variant('Candidate','CandidateNormalize')+shared+'\n'+fs.readFileSync(fixture,'utf8');
fs.writeFileSync(out+'/probe.swift',generated,{flag:'wx',mode:0o600});
const inputs={baselineTag:'v0.2.168',originalPromptSHA256:sha(baseline),candidatePromptSHA256:sha(candidate),candidateSectionSHA256:sha(section(candidate)),fixtureSHA256:sha(fs.readFileSync(fixture)),commonFixtureSHA256:sha(fs.readFileSync(common)),generatedSHA256:sha(generated)};
fs.writeFileSync(out+'/inputs.json',JSON.stringify(inputs,null,2)+'\n',{flag:'wx',mode:0o600});
async function run(command,args,name,timeout){
 const fd=fs.openSync(out+'/'+name+'.log','wx',0o600),child=spawn(command,args,{stdio:['ignore',fd,fd]});let timedOut=false;const started=performance.now();
 const timer=setTimeout(()=>{timedOut=true;child.kill('SIGTERM');},timeout);
 const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}));});clearTimeout(timer);fs.closeSync(fd);
 fs.writeFileSync(out+'/'+name+'-job.json',JSON.stringify({...result,timedOut,seconds:(performance.now()-started)/1000})+'\n',{flag:'wx',mode:0o600});
 assert.equal(result.code,0,fs.readFileSync(out+'/'+name+'.log','utf8').slice(-6000));assert.equal(timedOut,false);return fs.readFileSync(out+'/'+name+'.log','utf8');
}
await run('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',process.env.AUTOAPPROVE_QA_MODULE_CACHE||out+'/module-cache',out+'/probe.swift','-o',out+'/probe'],'compile',120000);
const result=JSON.parse((await run(out+'/probe',[],'check',600000)).trim());
assert.equal(result.matched,true);assert.equal(result.cases,9984);assert.equal(result.scalarNFCNFDProof,1112064);assert.equal(result.normalization.scalars,1112064);
assert.equal(sha(fs.readFileSync(file)),inputs.candidatePromptSHA256);assert.equal(sha(fs.readFileSync(fixture)),inputs.fixtureSHA256);
fs.writeFileSync(out+'/result.json',JSON.stringify({...result,binarySHA256:sha(fs.readFileSync(out+'/probe'))},null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({...result,out,scope:'Exact row bytes/counts/suffix/fence request orders only. Actual Core performance and detector checks are separate.'}));
