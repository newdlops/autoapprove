// Real Swift gateway; synthetic loopback routes with controlled response delays.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer, get} from 'node:http';
import {mkdtemp, mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import {randomUUID, createHash} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import path from 'node:path';

const option = name => process.argv.find(arg => arg.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('binary'), 'Pass a fixed compiled Swift fixture with --binary');
const binary = path.resolve(option('binary')), baseline = process.argv.includes('--baseline');
const output = path.resolve(option('output') || 'dist/qa/adaptive-read.json');
await mkdir(path.dirname(output), {recursive:true});
const root = await mkdtemp('/private/tmp/aa-adaptive-read-'), children = [], servers = [], sockets = new Set(), checks = [];
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(test, label, timeout=10000) {
  const deadline = performance.now()+timeout;
  while (!test()) { assert.ok(performance.now()<deadline, label); await wait(10); }
}
async function json(url, body) {
  const response = await fetch(url, {method:body?'POST':'GET', headers:body?{'Content-Type':'application/json'}:{},
    body:body?JSON.stringify(body):undefined, signal:AbortSignal.timeout(10000)});
  return {status:response.status, value:await response.json()};
}
async function start(label) {
  const child = spawn(binary, [path.join(root,label),label,'--direct-only'], {stdio:['ignore','pipe','pipe']}); children.push(child);
  let lines='', errors='', ready;
  child.stdout.on('data', part => { lines+=part; for (const line of lines.split('\n')) if(line.startsWith('{')) try { const value=JSON.parse(line); if(value.url)ready=value; } catch {} });
  child.stderr.on('data', part => errors+=part);
  await until(()=>ready || child.exitCode!==null || child.signalCode!==null, 'Swift gateway startup: '+errors, 20000);
  assert.ok(ready, errors); return {...ready,child};
}
const nodeID=randomUUID(), sessionID='original+한글', screen=String('합성 원본🙂 \u001b[32m색상\u001b[0m\n').repeat(800);
const frame={sessionID,screen,revision:'same-original',streamID:'original-stream',observedAt:new Date().toISOString(),keys:['enter']};
let template, primaryURL, backupURL, mode={primaryMs:10,backupMs:10};
const stats={finite:{primary:0,backup:0,requestBytes:0}, stream:{primary:0,backup:0,requestBytes:0}, posts:0, peak:0};
const active=new Set();
function peer(backup) {
  const server=createServer(async(req,res)=>{
    const stream=req.url.startsWith('/api/terminal/stream?'), finite=!stream&&req.url.startsWith('/api/terminal?');
    const send=(status,value)=>{
      if(res.destroyed)return;
      const body=gzipSync(Buffer.from(JSON.stringify(value)),{level:6});
      res.writeHead(status,{'Content-Type':'application/json','Content-Length':body.length,'Content-Encoding':'gzip','X-AutoApprove-Node':nodeID,Connection:'close'}); res.end(body);
    };
    if(req.method!=='GET'){stats.posts++;req.socket.destroy();return;}
    if(stream||finite){
      const fault={...mode}, kind=stream?'stream':'finite';
      assert.equal(req.headers['x-autoapprove-node'],nodeID);assert.equal(new URL(req.url,'http://localhost').searchParams.get('session'),sessionID);
      stats[kind][backup?'backup':'primary']++;stats[kind].requestBytes+=req.socket.bytesRead;
      active.add(req.socket);stats.peak=Math.max(stats.peak,active.size);req.socket.once('close',()=>active.delete(req.socket));
      if(!backup&&fault.failure==='closed'){req.socket.destroy();return;}
      if(!backup&&fault.failure==='stall')return;
      await wait(backup?fault.backupMs:fault.primaryMs);
      if(res.destroyed)return;
      if(!backup&&fault.failure==='denied')return send(403,{error:'Synthetic explicit permission denial'});
      if(finite)return send(200,frame);
      res.useChunkedEncodingByDefault=false;
      res.writeHead(200,{'Content-Type':'text/event-stream','X-AutoApprove-Node':nodeID,Connection:'close'});
      res.write('event: screen\ndata: '+JSON.stringify(frame)+'\n\n');return;
    }
    send(200,req.url==='/api/discovery'?{service:'autoapprove',version:1,id:nodeID,name:'Timing fixture',urls:[primaryURL,backupURL],port:Number(new URL(primaryURL).port),release:template.release}
      :{...template,id:nodeID,name:'Timing fixture',webURLs:[primaryURL,backupURL],webPort:Number(new URL(primaryURL).port)});
  });
  server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});servers.push(server);return server;
}
async function gateway(label) {
  mode={primaryMs:10,backupMs:10};const owner=await start(label);
  assert.equal((await json(owner.url+'/api/peers',{address:primaryURL})).status,200);return owner;
}
async function read(owner,kind) {
  const started=performance.now(), route=kind==='stream'?'/api/terminal/stream?':'/api/terminal?';
  const url=owner.url+route+new URLSearchParams({node:nodeID,session:sessionID});
  if(kind==='finite') {const response=await json(url);assert.equal(response.status,200);assert.equal(response.value.screen,screen);}
  else await new Promise((resolve,reject)=>{
    const request=get(url,{headers:{'Accept-Encoding':'identity'}},response=>{
      if(response.statusCode!==200){response.resume();reject(new Error('Stream status '+response.statusCode));return;}
      let text='';response.setEncoding('utf8');response.on('data',part=>{
        text+=part;if(!text.includes('\n\n'))return;
        try{const event=JSON.parse(text.split('\n').find(line=>line.startsWith('data: ')).slice(6));assert.equal(event.screen,screen);request.destroy();resolve();}catch(error){request.destroy();reject(error);}
      });response.on('error',reject);
    });request.on('error',reject);request.setTimeout(10000,()=>request.destroy(new Error('Stream read timed out')));
  });
  await until(()=>active.size===0,'All winning and losing sockets must close');return Math.round(performance.now()-started);
}
const snapshot=kind=>({...stats[kind]});
const delta=(kind,before)=>Object.fromEntries(Object.entries(stats[kind]).map(([key,value])=>[key,value-before[key]]));
try {
  const bootstrap=await start('bootstrap');template=(await json(bootstrap.url+'/api/state')).value;
  const primary=peer(false),backup=peer(true);
  await new Promise(resolve=>primary.listen(0,'127.0.0.1',resolve));await new Promise(resolve=>backup.listen(0,'127.0.0.1',resolve));
  primaryURL='http://127.0.0.1:'+primary.address().port;backupURL='http://127.0.0.1:'+backup.address().port;
  for(const kind of ['finite','stream']){
    const busy=await gateway(kind+'-busy'), before=snapshot(kind), times=[];
    mode={primaryMs:400,backupMs:440};
    for(let i=0;i<12;i++)times.push(await read(busy,kind));
    const requests=delta(kind,before);assert.equal(requests.primary,12);
    if(baseline)assert.ok(requests.backup>=6&&requests.backup<=12,'The fixed 200ms timer should duplicate most 400ms reads');
    else assert.ok(requests.backup<=2,'Learning should suppress repeated duplicates of a consistently healthy busy route');
    checks.push({kind,condition:'healthy-400ms',...requests,elapsedMs:times});busy.child.kill();
    const recovery=[];
    for(let sample=0;sample<3;sample++){
      const fast=await gateway(kind+'-fast-'+sample);
      const beforeTraining=snapshot(kind);
      mode={primaryMs:10,backupMs:10};for(let i=0;i<6;i++)await read(fast,kind);
      assert.equal(delta(kind,beforeTraining).backup,0,'Healthy fast reads must stay on one route');
      mode={primaryMs:10,backupMs:10,failure:'stall'};const prior=snapshot(kind), elapsedMs=await read(fast,kind), requests=delta(kind,prior);
      assert.deepEqual({primary:requests.primary,backup:requests.backup},{primary:1,backup:1});assert.ok(elapsedMs<1200);
      recovery.push(elapsedMs);fast.child.kill();
    }
    checks.push({kind,condition:'learned-fast-route-stalls',elapsedMs:recovery,medianMs:[...recovery].sort((a,b)=>a-b)[1]});
    const failed=await gateway(kind+'-closed'), beforeClosed=snapshot(kind);
    mode={primaryMs:10,backupMs:10,failure:'closed'};const elapsedMs=await read(failed,kind);
    assert.equal(delta(kind,beforeClosed).backup,1);assert.ok(elapsedMs<1200);checks.push({kind,condition:'closed-route',elapsedMs});failed.child.kill();
  }
  assert.ok(stats.peak<=2);assert.equal(stats.posts,0);
  const report={baseline,binarySHA256:createHash('sha256').update(await readFile(binary)).digest('hex'),checks,peakReads:stats.peak,inputPosts:stats.posts,
    scope:'Actual Swift gateway, controlled loopback-only synthetic peer delays, 12 healthy reads and three trained-failure samples per kind; requestBytes are complete peer GET bytes, not all app traffic or physical VPN measurements'};
  await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
} finally {
  for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();for(const socket of sockets)socket.destroy();
  await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));
  await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));
  await rm(root,{recursive:true,force:true});
}
