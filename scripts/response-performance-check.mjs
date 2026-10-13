import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
const label=process.argv.find(v=>v.startsWith('--label='))?.slice(8)||'current';assert.match(label,/^[a-z0-9-]+$/);
const build=path.resolve('.build/release'),out=path.resolve('.runtime/response-performance-check',label);await mkdir(out,{recursive:true});
const binary=path.join(out,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ResponsePerformanceCheck'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...(await readdir(build+'/AutoApproveCore.build')).filter(v=>v.endsWith('.swift.o')).map(v=>build+'/AutoApproveCore.build/'+v),'Tests/fixtures/response-performance-check.swift','-o',binary],{stdio:'inherit'});
const samples=[];
for(let i=0;i<3;i++){const root=await mkdtemp('/private/tmp/aa-response-perf-');try{samples.push(JSON.parse(execFileSync(binary,[root],{encoding:'utf8',timeout:45000})));}finally{await rm(root,{recursive:true,force:true});}}
const median=values=>[...values].sort((a,b)=>a-b)[Math.floor(values.length/2)];
const report=Object.fromEntries(Object.keys(samples[0]).map(key=>[key,median(samples.map(s=>s[key]))]));
assert.ok(samples.every(s=>s.approvals===1&&s.continuations===1),'Synthetic responses were duplicated');
const result={label,samples:samples.length,...report};
const compare=process.argv.find(v=>v.startsWith('--compare='))?.slice(10);
if(compare){assert.match(compare,/^[a-z0-9-]+$/);const baseline=JSON.parse(await readFile(path.resolve('.runtime/response-performance-check',compare,'report.json'),'utf8'));result.reductionPercent=Object.fromEntries(['commandCPUSeconds','approvalSeconds','recoverySeconds'].map(key=>[key,100*(1-result[key]/baseline[key]) ]));}
if(process.argv.includes('--assert-responsive')){assert.ok(samples.every(s=>s.approvalSeconds<3&&s.recoverySeconds<3),'A slow host delayed the healthy host');assert.ok(samples.every(s=>s.quietTerminalReads<=2),'A paused host polled unnecessarily');}
await writeFile(path.join(out,'report.json'),JSON.stringify({...result,raw:samples},null,2));console.log(JSON.stringify(result,null,2));
