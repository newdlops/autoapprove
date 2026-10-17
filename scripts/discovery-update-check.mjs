// Link the real release Core. Isolated synthetic process updates; never starts
// the engine, opens a listener, reads a user terminal or sends original input.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,mkdtemp,readFile,readdir,rm,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const directory=path.resolve('.runtime/discovery-update-check',label),binary=path.join(directory,'check'),build=path.resolve('.build/release');
await mkdir(directory,{recursive:true,mode:0o700});await mkdir('.build/cache/DiscoveryUpdateCheck',{recursive:true});
if(process.argv.includes('--reuse-binary')){
 const previous=JSON.parse(await readFile(path.join(directory,'report.json'),'utf8'));
 assert.equal(previous.fixtureSHA256,createHash('sha256').update(await readFile('Tests/fixtures/discovery-update-check.swift')).digest('hex'),'The compiled fixture changed');
 assert.equal(previous.binarySHA256,createHash('sha256').update(await readFile(binary)).digest('hex'),'The measured binary changed');
}else execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/DiscoveryUpdateCheck'),
 '-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
 'Tests/fixtures/discovery-update-check.swift','-o',binary],{stdio:'inherit'});
const reports=[];
for(let trial=0;trial<3;trial++){
 const home=await mkdtemp('/private/tmp/aa-discovery-update-');
 try{reports.push(JSON.parse(execFileSync(binary,[home],{encoding:'utf8',timeout:30000})));}
 finally{await rm(home,{recursive:true,force:true});}
}
const median=values=>values.sort((a,b)=>a-b)[1];
const summary=reports[0].workloads.map((row,index)=>({automatic:row.automatic,rounds:row.rounds,cpuSeconds:median(reports.map(r=>r.workloads[index].cpuSeconds)),wallSeconds:median(reports.map(r=>r.workloads[index].wallSeconds))}));
const report={label,trials:3,records:reports[0].records,sessions:reports[0].sessions,summary,reports,
 binarySHA256:createHash('sha256').update(await readFile(binary)).digest('hex'),fixtureSHA256:createHash('sha256').update(await readFile('Tests/fixtures/discovery-update-check.swift')).digest('hex'),
 inputPosts:0,scope:'Actual engine updateDiscovery; same1249 synthetic records and24sessions,200refreshes,manual/automatic isolated preferences. Not whole-program or physical-LAN speedup.'};
const reference=option('reference');
const previous=reference?JSON.parse(await readFile(reference,'utf8')):null;
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
if(reference){
 assert.equal(previous.fixtureSHA256,report.fixtureSHA256);assert.equal(previous.records,report.records);assert.equal(previous.sessions,report.sessions);
 assert.ok(summary[1].cpuSeconds<previous.summary[1].cpuSeconds*0.8,'Automatic discovery updates must use at least20%less CPU than the measured reference');
}
console.log(JSON.stringify({...report,reports:undefined}));
