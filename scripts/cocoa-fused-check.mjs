// Exact original-source parser oracle. Own synthetic strings only.
import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';
const out=path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT||fs.mkdtempSync(path.join(os.tmpdir(),'aa-cocoa-fused-')));
fs.mkdirSync(out,{recursive:true,mode:0o700});
const sourceFile='Sources/AutoApproveCore/DetectionLines.swift',fixture='Tests/fixtures/cocoa-fused-check.swift',sha=value=>createHash('sha256').update(value).digest('hex');
const original=file=>execFileSync('git',['-c','core.fsmonitor=false','show','v0.2.168:'+file],{encoding:'utf8'});
const prompt=original('Sources/AutoApproveCore/ApprovalPrompt.swift'),baseline=original(sourceFile),candidate=fs.readFileSync(sourceFile,'utf8');
const start=prompt.indexOf('    public static func normalizedLines('),end=prompt.indexOf('    static func permissionMarkers(',start);assert.ok(start>=0&&end>start);
const variant=(source,name)=>source.replaceAll('DetectionLineSuffix',name+'Suffix').replaceAll('DetectionLines',name+'Lines').replaceAll('PromptDetector','GoldNormalize');
const generated='enum GoldNormalize {\n'+prompt.slice(start,end)+'}\n'+variant(baseline,'Baseline')+variant(candidate,'Candidate')+fs.readFileSync(fixture,'utf8');
fs.writeFileSync(out+'/probe.swift',generated,{flag:'wx',mode:0o600});
const proof={baselineTag:'v0.2.168',originalPromptSHA256:sha(prompt),originalLinesSHA256:sha(baseline),candidateLinesSHA256:sha(candidate),fixtureSHA256:sha(fs.readFileSync(fixture)),generatedSHA256:sha(generated)};
fs.writeFileSync(out+'/inputs.json',JSON.stringify(proof,null,2)+'\n',{flag:'wx',mode:0o600});
async function run(command,args,name,timeout){
 const fd=fs.openSync(out+'/'+name+'.log','wx',0o600),child=spawn(command,args,{stdio:['ignore',fd,fd]});let timedOut=false;const started=performance.now();
 const timer=setTimeout(()=>{timedOut=true;child.kill('SIGTERM');},timeout);
 const r=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}));});clearTimeout(timer);fs.closeSync(fd);
 fs.writeFileSync(out+'/'+name+'-job.json',JSON.stringify({...r,timedOut,seconds:(performance.now()-started)/1000})+'\n',{flag:'wx',mode:0o600});
 assert.equal(r.code,0,fs.readFileSync(out+'/'+name+'.log','utf8').slice(-4000));assert.equal(timedOut,false);return fs.readFileSync(out+'/'+name+'.log','utf8');
}
await run('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',out+'/module-cache',out+'/probe.swift','-o',out+'/probe'],'compile',120000);
const result=JSON.parse((await run(out+'/probe',[],'check',300000)).trim());
assert.equal(result.matched,true);assert.equal(result.cases,9984);assert.equal(result.scalarNFCNFDProof,1112064);assert.equal(result.originalInputs,0);assert.equal(result.captures,0);assert.equal(result.listeners,0);
assert.equal(sha(fs.readFileSync(sourceFile)),proof.candidateLinesSHA256);assert.equal(sha(fs.readFileSync(fixture)),proof.fixtureSHA256);
fs.writeFileSync(out+'/result.json',JSON.stringify({...result,binarySHA256:sha(fs.readFileSync(out+'/probe'))},null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({matched:true,cases:result.cases,foreignCases:result.foreignCases,scalarProof:result.scalarNFCNFDProof,digest:result.digest,out,
 scope:'Direct parser fields/request orders and exhaustive scalar-whitespace proof only. Actual Core CPU/wall/RSS and detector invariants require separate validation.'}));
