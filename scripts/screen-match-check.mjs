import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const output=path.resolve('.runtime/screen-match-check',label),build=path.resolve('.build/release'),binary=path.join(output,'check');
await mkdir(output,{recursive:true,mode:0o700});
const fixture='Tests/fixtures/screen-match-check.swift',source=option('source','Sources/AutoApproveCore/ScreenTextEquality.swift');
const sha=b=>createHash('sha256').update(b).digest('hex');let provenance;
if(process.argv.includes('--reuse-binary')){
 provenance=JSON.parse(await readFile(path.join(output,'provenance.json'),'utf8'));
 assert.equal(provenance.fixtureSHA256,sha(await readFile(fixture)));assert.equal(provenance.binarySHA256,sha(await readFile(binary)));
}else{
 const contents=await readFile(source,'utf8');
 const generated=path.join(output,'ScreenMatchCheck.swift');
 const generatedSource=contents+'\nimport AutoApproveCore\nstruct ScreenMatchProbe {\nlet raw:String;let agent:AgentKind\nfunc matches(_ current:String,agent:AgentKind)->Bool { self.agent == agent && ScreenTextEquality.identical(raw,current) }\n}\n'+await readFile(fixture,'utf8');
 await writeFile(generated,generatedSource);
 const cache=path.resolve('.build/cache/ScreenMatchCheck');await mkdir(cache,{recursive:true});
 const names=(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).sort();
 const objects=Object.fromEntries(await Promise.all(names.map(async n=>[n,sha(await readFile(build+'/AutoApproveCore.build/'+n))])));
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...names.map(n=>build+'/AutoApproveCore.build/'+n),generated,'-o',binary],{stdio:'inherit',timeout:120000});
 provenance={sourceSHA256:sha(contents),generatedSHA256:sha(generatedSource),fixtureSHA256:sha(await readFile(fixture)),binarySHA256:sha(await readFile(binary)),coreObjects:objects,coreFingerprint:sha(JSON.stringify(objects)),coreModuleSHA256:sha(await readFile(build+'/Modules/AutoApproveCore.swiftmodule'))};
 await writeFile(path.join(output,'provenance.json'),JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
}
const value=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:90000,maxBuffer:4*1024*1024}));
const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
const report={label,...value,workloads:value.workloads.map(w=>({...w,cpuSeconds:median(w.trials.map(t=>t.cpuSeconds)),wallSeconds:median(w.trials.map(t=>t.wallSeconds))})),provenance};
await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({label,correctnessCases:value.correctnessCases,resultSHA256:value.resultSHA256,provenance:{...provenance,coreObjects:undefined},workloads:report.workloads.map(({trials,...w})=>w)}));
const reference=option('reference');if(reference){const old=JSON.parse(await readFile(reference,'utf8'));assert.equal(value.correctnessCases,old.correctnessCases);assert.equal(value.resultSHA256,old.resultSHA256);assert.equal(provenance.fixtureSHA256,old.provenance.fixtureSHA256);}
if(process.argv.includes('--assert-efficient')){
 const matching=w=>w.pattern==='unicode'&&w.lines===768&&!w.changed;
 const native=report.workloads.find(w=>matching(w)&&w.storage==='native');
 for(const storage of ['cocoa','foreign','native-cocoa','cocoa-native']){
  const row=report.workloads.find(w=>matching(w)&&w.storage===storage);assert.ok(!row.lhsContiguousUTF8||!row.rhsContiguousUTF8,'The foreign storage must be real');
  assert.ok(row.cpuSeconds<native.cpuSeconds*4+.003,storage+': unchanged foreign frames must not repeatedly traverse UTF-8 scalars');
 }
}
