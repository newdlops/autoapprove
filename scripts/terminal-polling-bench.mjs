import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {performance} from 'node:perf_hooks';
import path from 'node:path';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';

const label=process.argv.find(value=>value.startsWith('--label='))?.slice(8)||'current'; assert.match(label,/^[a-z0-9-]+$/);
const build=path.resolve('.build/release'), output=path.resolve('.runtime/terminal-polling-bench',label);
await mkdir(output,{recursive:true});
const binary=path.join(output,'fixture'), cache=path.resolve('.build/cache/TerminalPollingBench'); await mkdir(cache,{recursive:true});
const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/terminal-polling-bench.swift','-o',binary],{stdio:'inherit'});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms)), reports=[];
async function read(file){try{return JSON.parse(await readFile(file,'utf8'));}catch{return null;}}
for(const sessions of [16,32])for(const distinct of [false,true]) {
  const directory=await mkdtemp('/private/tmp/aa-terminal-poll-bench-'), controllers=[], viewers=[];
  const child=spawn(binary,[directory,String(sessions)],{stdio:['ignore','ignore','inherit']});
  try {
    let port;for(let i=0;i<200&&!port;i++){try{port=Number(await readFile(path.join(directory,'port'),'utf8'));}catch{}if(!port)await wait(50);}
    assert.ok(port); const base='http://127.0.0.1:'+port;
    const state=await (await fetch(base+'/api/state')).json(); assert.equal(state.sessions.length,sessions);
    for(let i=0;i<3;i++) {
      const session=state.sessions[distinct?i:0].session,controller=new AbortController();controllers.push(controller);
      const response=await fetch(base+'/api/terminal/stream?session='+encodeURIComponent(session.id),{signal:controller.signal});assert.equal(response.status,200);
      const viewer={sessionID:session.id,frame:null,frames:0};viewers.push(viewer);
      void(async()=>{let buffer='';const decoder=new TextDecoder();try{for await(const bytes of response.body){buffer+=decoder.decode(bytes,{stream:true});let end;while((end=buffer.indexOf('\n\n'))>=0){const event=buffer.slice(0,end);buffer=buffer.slice(end+2);const data=event.split('\n').filter(line=>line.startsWith('data: ')).map(line=>line.slice(6)).join('\n');if(event.startsWith('event: screen')&&data){const update=JSON.parse(data);viewer.frame={...viewer.frame,...update};viewer.frames++;}}}}catch(error){if(!controller.signal.aborted)throw error;}})();
    }
    for(let i=0;i<100&&!viewers.every(viewer=>viewer.frame);i++)await wait(30);
    assert.ok(viewers.every(viewer=>viewer.frame)); await wait(2000);
    const before=await read(path.join(directory,'stats.json'));await wait(5000);const after=await read(path.join(directory,'stats.json'));
    const frame=viewers[0].frame,marker=' BENCH-'+label+'-'+sessions+'-'+distinct;
    const started=performance.now();
    const input=await fetch(base+'/api/input',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({requestID:randomUUID(),sessionID:frame.sessionID,revision:frame.revision,streamID:frame.streamID,relay:true,kind:'characters',text:marker})});assert.equal(input.status,200,await input.text());
    for(let i=0;i<100&&!viewers[0].frame.screen.includes(marker);i++)await wait(20);
    assert.ok(viewers[0].frame.screen.includes(marker));
    reports.push({sessions,viewers:3,distinct,idleSeconds:after.seconds-before.seconds,singleReads:after.singleReads-before.singleReads,cpuSeconds:after.cpuSeconds-before.cpuSeconds,inputEchoMs:Math.round(performance.now()-started),frames:viewers.map(viewer=>viewer.frames)});
  } finally {for(const controller of controllers)controller.abort();child.kill();await new Promise(resolve=>child.once('exit',resolve));await rm(directory,{recursive:true,force:true});}
}
const result={label,reports,scope:'Release Core, synthetic native adapters and process records, three real HTTP/SSE clients; no user terminal, Bonjour or physical network'};
await writeFile(path.join(output,'report.json'),JSON.stringify(result,null,2));console.log(JSON.stringify(result,null,2));
