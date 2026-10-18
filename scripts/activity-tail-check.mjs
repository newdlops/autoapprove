// Exact production ActivityDetector; its goal-footer helpers and other detectors remain real.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const directory=path.resolve('.runtime/activity-tail-check',label),build=path.resolve('.build/release'),binary=path.join(directory,'check');
await mkdir(directory,{recursive:true,mode:0o700});
const fixture='Tests/fixtures/activity-tail-check.swift',source=option('source','Sources/AutoApproveCore/ActivityDetector.swift'),capacity='Sources/AutoApproveCore/CapacityResume.swift';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
let provenance;
if(process.argv.includes('--reuse-binary')){
 provenance=JSON.parse(await readFile(path.join(directory,'provenance.json'),'utf8'));
 assert.equal(provenance.fixtureSHA256,sha(await readFile(fixture)));assert.equal(provenance.binarySHA256,sha(await readFile(binary)));
}else{
 const activity=await readFile(source,'utf8'),helpers=await readFile(capacity,'utf8');
 const composer=helpers.slice(helpers.indexOf('    static func isComposer('),helpers.indexOf('\n    /// Vim normal'));
 const start=helpers.indexOf('    private static func footer('),end=helpers.indexOf('\n    static func goalHeld(',start);
 assert.ok(composer.startsWith('    static func isComposer(')&&start>=0&&end>start);
 const tailStart=activity.indexOf('        let tail ='),tailEnd=activity.indexOf('\n        guard !tail.isEmpty',tailStart);assert.ok(tailStart>=0&&tailEnd>tailStart);
 const tailProbe='\nextension ActivityDetector { static func fixtureTail(_ screen:String)->[String] {\n'+activity.slice(tailStart,tailEnd)+'\nreturn tail\n} }\n';
 const generated=path.join(directory,'ActivityTailCheck.swift');
 const generatedSource='import AutoApproveCore\n'+activity+tailProbe+'\nprivate enum CodexResumeCheck {\n'+composer+'\n'+helpers.slice(start,end)+'\n}\n'+await readFile(fixture,'utf8');
 await writeFile(generated,generatedSource);
 const cache=path.resolve('.build/cache/ActivityTailCheck');await mkdir(cache,{recursive:true});
 const objectNames=(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).sort();
 const objects=Object.fromEntries(await Promise.all(objectNames.map(async name=>[name,sha(await readFile(build+'/AutoApproveCore.build/'+name))])));
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...objectNames.map(n=>build+'/AutoApproveCore.build/'+n),generated,'-o',binary],{stdio:'inherit',timeout:120000});
 provenance={activitySourceSHA256:sha(activity),capacitySourceSHA256:sha(helpers),generatedSHA256:sha(generatedSource),fixtureSHA256:sha(await readFile(fixture)),binarySHA256:sha(await readFile(binary)),
  coreObjects:objects,coreFingerprint:sha(JSON.stringify(objects)),coreModuleSHA256:sha(await readFile(build+'/Modules/AutoApproveCore.swiftmodule')),
  scope:'Activity source copied verbatim; exact tail statement and isComposer/footer/goalStalled helpers. Other detector calls use the fingerprinted release Core.'};
 await writeFile(path.join(directory,'provenance.json'),JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
}
const result=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:60000,maxBuffer:2*1024*1024}));
const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
const workloads=result.workloads.map(w=>({...w,cpuSeconds:median(w.trials.map(t=>t.cpuSeconds)),wallSeconds:median(w.trials.map(t=>t.wallSeconds))}));
const tailWorkloads=(result.tailWorkloads??[]).map(w=>({...w,cpuSeconds:median(w.trials.map(t=>t.cpuSeconds)),wallSeconds:median(w.trials.map(t=>t.wallSeconds))}));
const report={label,...result,workloads,tailWorkloads,provenance};
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({...report,provenance:{...provenance,coreObjects:undefined},workloads:workloads.map(({trials,...w})=>w),tailWorkloads:tailWorkloads.map(({trials,...w})=>w)}));
const reference=option('reference');
if(reference){const old=JSON.parse(await readFile(reference,'utf8'));assert.equal(report.correctnessCases,old.correctnessCases);assert.equal(report.observationSHA256,old.observationSHA256,'All observations must remain byte-identical');assert.equal(provenance.fixtureSHA256,old.provenance.fixtureSHA256);}
if(process.argv.includes('--assert-bounded')) for(const storage of ['swift','foundation'])for(const scenario of ['reused','changing']){
 const small=workloads.find(w=>w.storage===storage&&w.scenario===scenario&&w.historyLines===18),large=workloads.find(w=>w.storage===storage&&w.scenario===scenario&&w.historyLines===4096);
 assert.ok(large.cpuSeconds<=small.cpuSeconds*3+.006,storage+': unrelated scrollback must not multiply activity detection CPU');
}
