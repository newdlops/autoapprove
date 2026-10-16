// Actual Core HTTP and SSE handshakes against loopback synthetic originals.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readdir,writeFile,rm} from 'node:fs/promises';
import {coreLinkArguments} from './swift-core-link.mjs';
import path from 'node:path';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve('.build/release'),out=path.resolve(option('output')||'dist/qa/terminal-connection');
await mkdir(out,{recursive:true});const binary=path.join(out,'ConnectionPerformancePreview');
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.join(build,'ModuleCache'),
 '-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(v=>v.endsWith('.swift.o')).map(v=>path.join(build,'AutoApproveCore.build',v)),
 'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:300000});
const root=await mkdtemp('/private/tmp/aa-connection-http-'),children=[],checks=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(predicate,label){const end=performance.now()+15000;while(!predicate()){assert.ok(performance.now()<end,label);await wait(20);}}
async function start(label){
 const home=path.join(root,label),child=spawn(binary,[home,label,'--direct-only','--connection-performance'],{stdio:['ignore','pipe','pipe']});children.push(child);
 let text='',stderr='',info;child.stdout.on('data',chunk=>{text+=chunk;for(const line of text.split('\n'))if(line.startsWith('{'))try{const v=JSON.parse(line);if(v.url)info=v;}catch{}});
 child.stderr.on('data',chunk=>stderr+=chunk);
 await until(()=>info||child.exitCode!==null||child.signalCode!==null,'Fixture startup');assert.ok(info,stderr);return {...info,home};
}
async function json(url,body,headers={}){
 const r=await fetch(url,{method:body?'POST':'GET',headers:{...(body?{'Content-Type':'application/json'}:{}),...headers},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});
 return {status:r.status,value:await r.json()};
}
async function first(url,sse){
 const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),10000),start=performance.now();
 try {
  const r=await fetch(url,{signal:controller.signal});assert.equal(r.status,200);
  if(!sse)return {frame:await r.json(),ms:performance.now()-start};
  const reader=r.body.getReader(),decoder=new TextDecoder();let buffer='';
  for(;;){const chunk=await reader.read();assert.ok(!chunk.done,'SSE ended before its first frame');buffer+=decoder.decode(chunk.value,{stream:true});assert.ok(buffer.length<=2_100_000);let boundary;
   while((boundary=buffer.indexOf('\n\n'))>=0){const event=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);
    if(event.startsWith('event: screen\n'))return {frame:JSON.parse(event.split('\n').find(line=>line.startsWith('data: ')).slice(6)),ms:performance.now()-start};
   }
  }
 } finally {clearTimeout(timeout);controller.abort();}
}
try {
 const a=await start('A'),b=await start('B');
 assert.equal((await json(a.url+'/api/peers',{address:b.url})).status,200);
 const state=(await json(b.url+'/api/state')).value,id=state.sessions[0].session.id;
 const stats=async(node,relay=false)=>(await json(node.url+'/api/terminal/timings'+(relay?'?'+new URLSearchParams({node:b.id}):''))).value;
 const results=[];
 for(const [label,gateway,node]of [['direct',b,null],['relayed',a,b.id]]){
  await wait(2150);const before=await stats(b);
  const query=new URLSearchParams({session:id,initial:'1',...(node?{node}:{})});
  const [http,sse]=await Promise.all([first(gateway.url+'/api/terminal?'+query,false),first(gateway.url+'/api/terminal/stream?'+query,true)]);
  assert.equal(http.frame.sessionID,id);assert.equal(sse.frame.sessionID,id);assert.ok(http.frame.screen.length);assert.equal(sse.frame.screen,http.frame.screen);
  const after=await stats(b),difference=key=>(after.counters[key]||0)-(before.counters[key]||0);
  assert.equal(difference('initialReads'),1);assert.equal(difference('sharedInitialReads'),1);
  for(const stage of ['mainQueue','automation','automationQuery','identity','textRead','firstFrame','responseEncoding','transferPreparation','initialWrite'])assert.ok(after.stages[stage]?.count>=1,stage);
  results.push({label,httpMS:Math.round(http.ms),sseMS:Math.round(sse.ms),sourceReads:difference('initialReads'),sharedReads:difference('sharedInitialReads'),screenMatches:true});
  checks.push(label+': concurrent HTTP/SSE share one exact original read and expose phase timings');
 }
 const relayedStats=await stats(a,true);assert.ok(relayedStats.stages.textRead?.count>0);
 const ownStats=await stats(a);assert.ok(ownStats.stages.relayHTTP?.count>0);assert.ok(ownStats.stages.relayStreamOpen?.count>0);
 assert.equal((await json(b.url+'/api/terminal/timings',null,{Origin:'https://invalid.example'})).status,403);
 const cli=JSON.parse(execFileSync(path.join(build,'autoapprove'),['terminal-timings','--home',b.home],{encoding:'utf8',timeout:10000}));
 assert.equal(cli.sampleLimit,256);assert.ok(cli.counters.sharedInitialReads>=2);
 assert.deepEqual(Object.keys(cli).sort(),['counters','sampleLimit','stages']);
 checks.push('Local CLI and direct/relayed diagnostics preserve origin checks and contain only bounded aggregate timings');
 await writeFile(path.join(out,'report.json'),JSON.stringify({checks,results,inputPosts:0,scope:'Actual Core HTTP/SSE, synthetic original screens and permission delay; no real terminal input or physical phone performance claim'},null,2)+'\n');
 console.log(JSON.stringify({checks,results,inputPosts:0}));
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();
 await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));
 await rm(root,{recursive:true,force:true});
}
