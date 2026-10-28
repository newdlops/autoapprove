// Process-scoped public OS assertions only; no root sleep or lock preferences.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/lid-session-201/activity');
await mkdir(out,{recursive:true});const cache=path.resolve('.build/cache/Continuity'),binary=out+'/KeepAwakeActivityCheck';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/keep-awake-activity.swift','-o',binary],{stdio:'inherit',timeout:120000});
console.log(execFileSync(binary,[],{encoding:'utf8',timeout:15000}).trim());
const child=spawn(binary,['--hold'],{stdio:['ignore','pipe','pipe']});let text='',stderr='';child.stderr.on('data',v=>stderr+=v);
try{
 await new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('Child startup '+stderr)),10000);child.stdout.on('data',v=>{text+=v;if(text.includes('READY ')){clearTimeout(timer);resolve();}});child.once('error',reject);});
 const counts=()=>JSON.parse(execFileSync(binary,['--pid',String(child.pid)],{encoding:'utf8',timeout:10000}));
 let held;for(let i=0;i<30;i++){held=counts();if(held.PreventUserIdleDisplaySleep>0)break;await new Promise(r=>setTimeout(r,50));}assert.ok(held.PreventUserIdleDisplaySleep>0);
 const exited=new Promise(r=>child.once('exit',r));child.kill('SIGTERM');await exited;
 let after;for(let i=0;i<30;i++){after=counts();if(Object.keys(after).length===0)break;await new Promise(r=>setTimeout(r,50));}assert.deepEqual(after,{});
 const report={passed:true,explicitRelease:true,processExitRelease:true,held,scope:'Actual compiled Core and process-owned IOPM assertions; no sudo, pmset, input, password or screen-lock policy changes'};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');}
