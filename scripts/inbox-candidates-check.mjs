import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fixture=path.resolve(option('fixture','Tests/fixtures/inbox-candidates-check.swift'));
const parent=path.resolve('.runtime/inbox-candidates-check');fs.mkdirSync(parent,{recursive:true,mode:0o700});
const out=fs.mkdtempSync(parent+'/run-'),cache=path.resolve(option('cache',out+'/module-cache'));
const hashes={[fixture]:sha(fixture),[import.meta.filename]:sha(import.meta.filename)};
const references={"SessionInbox":{"sha256":"a95a601fc8407501d7da20724c6374a53491ab8fc0ff003988a076dd95a319d4","names":[["ReferenceNotice","SessionNotice"],["ReferenceInbox","SessionInbox"]]},"AttentionRequest":{"sha256":"627deea5df5ed22458cee372819bdb855d095d3f49c0df629b15f15389e628c3","names":[["ReferenceSchedule","AttentionNotificationSchedule"],["ReferenceTracker","AttentionTracker"],["ReferenceAttention","AttentionRequest"]]}};
Object.assign(references,{"AutomaticQuestionDecision":{"sha256":"3fe3c67c5b4e24a632f803fa98f3d3c4b06259e9effd70e04e024c9b02e32345","names":[["BoundOriginalQuestionDecision","AutomaticQuestionDecision"],["BoundOriginalYesNoConfirmation","YesNoConfirmation"]]},"YesNoConfirmation":{"sha256":"027d0b3c0ec2e5293267b728a7efae9772fb5df46657ff11c5a246881bd05709","names":[["BoundOriginalQuestionDecision","AutomaticQuestionDecision"],["BoundOriginalYesNoConfirmation","YesNoConfirmation"]]}});
const fixtureText=fs.readFileSync(fixture,'utf8');
for(const[name,info]of Object.entries(references)){
 const begin='// BEGIN ORIGINAL '+name+'\n',end='// END ORIGINAL '+name+'\n';assert.equal(fixtureText.split(begin).length,2);assert.equal(fixtureText.split(end).length,2);
 let body=fixtureText.split(begin)[1].split(end)[0];assert.ok(body.startsWith('import AutoApproveCore\n'));body=body.slice('import AutoApproveCore\n'.length);
 for(const[from,to]of info.names)body=body.replaceAll(new RegExp('\\b'+from+'\\b','g'),to);
 assert.equal(createHash('sha256').update(body).digest('hex'),info.sha256,'Original reference source changed: '+name);
 if(option('reference-source-root')){
  const file=path.resolve(option('reference-source-root'))+'/Sources/AutoApproveCore/'+name+'.swift';assert.equal(sha(file),info.sha256);hashes[file]=sha(file);
 }
}


const modelWordsBinding={"foundationSpanSHA256":"33592abce48db5878e9eaa1873267b80bd6c9b84ed9552884122c8881b7ebf27","previousSpanSHA256":"c691345caa9a3c144708ec6559a28839c1a534f9bdb8f963c159c3d9b43378c9","candidateSpanSHA256":"7fc39c43d3040b51a8a085660364817e03f1367acb82513fd772e57cf78db466","cases":188790};
function modelWordSpan(text){const begin=text.indexOf('    static func mentionsModel('),end=text.indexOf('    static func isModelHeading(',begin);assert.ok(begin>=0&&end>begin);return text.slice(begin,end)}
for(const [variant,name,digest]of [['ORIGINAL','BoundPreviousModelWordMatcher',modelWordsBinding.foundationSpanSHA256],['PREVIOUS','BoundImmediateModelWordMatcher',modelWordsBinding.previousSpanSHA256],['CANDIDATE','BoundCandidateModelWordMatcher',modelWordsBinding.candidateSpanSHA256]]){
 const begin='// BEGIN '+variant+' ModelWordMatcher\n',end='// END '+variant+' ModelWordMatcher\n';assert.equal(fixtureText.split(begin).length,2);assert.equal(fixtureText.split(end).length,2);
 const body=fixtureText.split(begin)[1].split(end)[0],prefix='enum '+name+' {\n';assert.ok(body.startsWith(prefix)&&body.endsWith('}\n'));
 assert.equal(createHash('sha256').update(body.slice(prefix.length,-2)).digest('hex'),digest);
}


const permissionPrefixBinding={"previousSHA256":"25589c17920957450b233b708c353e6e63a04dab98f66bbed67f1113fb3c7f35","candidateSHA256":"0df3637e6aaa7d2af5c9c22856ae792f09992a188886f541f738abf428183373","cases":64556,"counts":{"leadingASCIIPairs":16384,"trailingASCIIPairs":16384,"asciiInsertions":14592,"curatedMenus":2560,"unicodeInsertions":12716,"optionNames":1600,"lengthBoundaries":128,"malformedUTF16":192}};
for(const[variant,name,digest]of [['PREVIOUS','BoundPreviousPermissionConfirmation',permissionPrefixBinding.previousSHA256],['CANDIDATE','BoundCandidatePermissionConfirmation',permissionPrefixBinding.candidateSHA256]]){
 const begin='// BEGIN '+variant+' PermissionPrefix\n',end='// END '+variant+' PermissionPrefix\n';assert.equal(fixtureText.split(begin).length,2);assert.equal(fixtureText.split(end).length,2);
 let body=fixtureText.split(begin)[1].split(end)[0];assert.ok(body.startsWith('import AutoApproveCore\n'));body=body.slice('import AutoApproveCore\n'.length).replaceAll(new RegExp('\\b'+name+'\\b','g'),'YesNoConfirmation');
 assert.equal(createHash('sha256').update(body).digest('hex'),digest);
}

const verify=()=>{for(const[file,digest]of Object.entries(hashes))assert.equal(sha(file),digest,file)};
const variants={candidate:{build:path.resolve(option('build','.build/release')),source:path.resolve(option('source-root','.'))}};
if(option('baseline-build')){assert.ok(option('baseline-source-root'));variants.baseline={build:path.resolve(option('baseline-build')),source:path.resolve(option('baseline-source-root'))}}
const results={};
for(const[label,value]of Object.entries(variants)){
 const objects=fs.readdirSync(value.build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>value.build+'/AutoApproveCore.build/'+name);
 const links=await coreLinkArguments(value.build);assert.ok(objects.length>0,'Build a matching release Core first');
 const confirmationFile=value.source+'/Sources/AutoApproveCore/YesNoConfirmation.swift';hashes[confirmationFile]=sha(confirmationFile);assert.equal(hashes[confirmationFile],permissionPrefixBinding.candidateSHA256);
 const modelFile=value.source+'/Sources/AutoApproveCore/AutomaticQuestionDecision.swift';hashes[modelFile]=sha(modelFile);
 assert.equal(createHash('sha256').update(modelWordSpan(fs.readFileSync(modelFile,'utf8'))).digest('hex'),label==='candidate'?modelWordsBinding.candidateSpanSHA256:modelWordsBinding.previousSpanSHA256);
 for(const file of [value.build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o')),
  ...['ApprovalEngine.swift','SessionInbox.swift','AttentionRequest.swift','AutomaticQuestionDecision.swift','YesNoConfirmation.swift'].map(name=>value.source+'/Sources/AutoApproveCore/'+name)])hashes[file]=sha(file);
 value.binary=out+'/'+label;value.coreObjects=objects.length;value.moduleSHA256=sha(value.build+'/Modules/AutoApproveCore.swiftmodule');verify();
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',value.build+'/Modules',
  '-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,fixture,'-o',value.binary],{stdio:'inherit',timeout:300000});
 hashes[value.binary]=sha(value.binary);verify();
 const environment={...process.env};delete environment.SWIFT_DETERMINISTIC_HASHING;
 results[label]=JSON.parse(execFileSync(value.binary,[],{encoding:'utf8',env:environment,timeout:240000,maxBuffer:1048576}));verify();
 assert.equal(results[label].passed,true);assert.equal(results[label].inboxSteps,4096);assert.equal(results[label].attentionCases,2048);assert.equal(results[label].explicitMalformedNotices,32);assert.equal(results[label].permissionPrefixCases,64556);assert.ok(results[label].permissionPrefixForeignInputs>0);assert.equal(results[label].modelWordLinkedCoreCases,188790);assert.equal(results[label].modelWordCases,188790);assert.ok(results[label].modelWordForeignInputs>0);assert.equal(results[label].typedDecisionCases,4096);assert.equal(results[label].jsonDecisionCases,512);assert.ok(results[label].foreignDecisionInputs>0);
}
if(results.baseline)assert.equal(results.baseline.digest,results.candidate.digest);
verify();
const report={passed:true,actualCompiledCore:true,sourceBoundOriginalReference:true,inboxStepsPerBuild:4096,attentionCasesPerBuild:2048,
 fullRawUTF8AndUTF16StateCompared:true,onlyUUIDsNormalizedAcrossSteps:true,wireAndCodecOutcomesCompared:true,baselineComparisonRun:!!results.baseline,
 crossBuildDigestMatches:!!results.baseline,results,variants,inputs:hashes,originalTerminalActions:0,realPowerCommands:0,noPerformanceClaim:true};
fs.writeFileSync(out+'/report.json',JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({passed:true,inboxStepsPerBuild:4096,attentionCasesPerBuild:2048,explicitMalformedNotices:32,baselineComparisonRun:!!results.baseline,report:out+'/report.json'}));
