// Real release Core, synthetic registry/job files, no user profile or terminal.
import assert from 'node:assert/strict';import{execFileSync}from'node:child_process';import{createHash}from'node:crypto';
import{mkdir,mkdtemp,readFile,readdir,writeFile,rm}from'node:fs/promises';import path from'node:path';import{coreLinkArguments}from'./swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const directory=path.resolve('.runtime/registry-resource-check',label),binary=path.join(directory,'check'),fixture='Tests/fixtures/registry-resource-check.swift',build=path.resolve('.build/release');
await mkdir(directory,{recursive:true,mode:0o700});await mkdir('.build/cache/RegistryResourceCheck',{recursive:true});
const hash=async file=>createHash('sha256').update(await readFile(file)).digest('hex');
if(process.argv.includes('--reuse-binary')){const prior=JSON.parse(await readFile(path.join(directory,'report.json'),'utf8'));assert.equal(prior.fixtureSHA256,await hash(fixture));assert.equal(prior.binarySHA256,await hash(binary));}
else execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/RegistryResourceCheck'),
 '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).map(n=>build+'/AutoApproveCore.build/'+n),fixture,'-o',binary],{stdio:'inherit',timeout:120000});
const reports=[];
for(let round=0;round<3;round++){const home=await mkdtemp('/private/tmp/aa-registry-check-');try{reports.push(JSON.parse(execFileSync(binary,[home],{encoding:'utf8',timeout:30000})));}finally{await rm(home,{recursive:true,force:true});}}
const median=xs=>xs.sort((a,b)=>a-b)[1],summary=reports[0].workloads.map((row,index)=>({mode:row.mode,rounds:row.rounds,cpuSeconds:median(reports.map(r=>r.workloads[index].cpuSeconds)),wallSeconds:median(reports.map(r=>r.workloads[index].wallSeconds))}));
const report={label,trials:3,summary,reports,binarySHA256:await hash(binary),fixtureSHA256:await hash(fixture),inputPosts:0,scope:'Real registry reader;1000synthetic nonagents,0/1/24sessions,interactive or blocked with both ISO timestamp forms;fixed isolated files. Not whole-program/phone performance.'};
const reference=option('reference'),prior=reference?JSON.parse(await readFile(reference,'utf8')):null;
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
if(prior){assert.equal(prior.fixtureSHA256,report.fixtureSHA256);for(const mode of ['interactive','blocked'])assert.ok(summary.find(r=>r.mode===mode).cpuSeconds<prior.summary.find(r=>r.mode===mode).cpuSeconds*.8,mode+': at least20%less CPU required');}
console.log(JSON.stringify({...report,reports:undefined}));
