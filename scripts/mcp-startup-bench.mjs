import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {once} from 'node:events';
import {mkdir,mkdtemp,rm,readFile,realpath,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import readline from 'node:readline';
import path from 'node:path';
const option=(name,fallback)=>process.argv.find(a=>a.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const directory=path.resolve('.runtime/mcp-startup-bench',label);await mkdir(directory,{recursive:true,mode:0o700});
const observer=path.join(directory,'owned-process-memory');
execFileSync('/usr/bin/xcrun',['clang','-O2','Tests/fixtures/owned-process-memory.c','-lproc','-o',observer],{stdio:'inherit',timeout:60000});
const binaries=[{label:'current',path:await realpath(option('candidate','.build/release/autoapprove'))}];
if(option('baseline'))binaries.unshift({label:'previous',path:await realpath(option('baseline'))});
for(const binary of binaries)binary.sha256=createHash('sha256').update(await readFile(binary.path)).digest('hex');
const reports=[];
for(let round=0;round<3;round++)for(const binary of round%2?[...binaries].reverse():binaries){
 const home=await mkdtemp('/private/tmp/aa-mcp-startup-');let child,lines,closed,failure;let sequence=0;const pending=new Map();
 try{
  const began=performance.now();child=spawn(binary.path,['mcp','--home',home],{stdio:['pipe','pipe','pipe']});
  function fail(error){failure=error;for(const item of pending.values())item.reject(error);pending.clear();}
  closed=once(child,'close');void closed.catch(fail);child.stderr.resume();lines=readline.createInterface({input:child.stdout});
  lines.on('line',line=>{try{const value=JSON.parse(line),item=pending.get(value.id);assert.ok(item,'Unexpected MCP response');pending.delete(value.id);item.resolve(value);}catch(error){fail(error);}});
  async function rpc(method,params){const id=++sequence;let timer;
   if(failure)throw failure;
   const response=new Promise((resolve,reject)=>{pending.set(id,{resolve,reject});timer=setTimeout(()=>{pending.delete(id);reject(Error('MCP startup response deadline'));},20000);});
   child.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,...(params?{params}:{})})+'\n');
   try{const value=await response;assert.equal(value.error,undefined);return value.result;}finally{clearTimeout(timer);}
  }
  const initialized=await rpc('initialize',{protocolVersion:'2025-11-25',capabilities:{},clientInfo:{name:'synthetic-benchmark',version:'1'}});
  const initializeMS=performance.now()-began;assert.equal(initialized.serverInfo.name,'autoapprove');
  const tools=await rpc('tools/list');assert.equal(tools.tools.length,5);
  await new Promise(r=>setTimeout(r,80));
  const initial=JSON.parse(execFileSync(observer,[String(child.pid),binary.path],{encoding:'utf8'}));
  for(let i=0;i<1000;i++)assert.equal((await rpc('tools/list')).tools.length,5);
  await new Promise(r=>setTimeout(r,80));
  const after=JSON.parse(execFileSync(observer,[String(child.pid),binary.path],{encoding:'utf8'}));assert.equal(after.start,initial.start);
  child.stdin.end();const [code,signal]=await closed;assert.equal(code,0);assert.equal(signal,null);child=null;
  reports.push({round,label:binary.label,initializeMS,initial,after,footprintGrowth:after.footprint-initial.footprint});
 }finally{lines?.close();if(child&&child.exitCode===null&&child.signalCode===null){child.kill();await closed;}await rm(home,{recursive:true,force:true});}
}
const median=values=>values.sort((a,b)=>a-b)[1];
const summary=Object.fromEntries(binaries.map(binary=>{const rows=reports.filter(r=>r.label===binary.label);return[binary.label,{initializeMS:median(rows.map(r=>r.initializeMS)),
 initialFootprint:median(rows.map(r=>r.initial.footprint)),after1000Footprint:median(rows.map(r=>r.after.footprint)),footprintGrowth:median(rows.map(r=>r.footprintGrowth))}]}));
const result={binaries,summary,reports,inputPosts:0,scope:'Owned fresh stdio helpers; initialize, tools/list and clean EOF only. No actual bridge tool, listener, screen capture or original CLI input. Per-process footprints include shared pages.'};
await writeFile(path.join(directory,'report.json'),JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(summary));
