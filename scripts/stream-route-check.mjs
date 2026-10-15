import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtemp, mkdir, readdir, readFile, writeFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { randomUUID,randomBytes } from 'node:crypto';
import {createConnection} from 'node:net';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import {gzipSync,createGzip,constants} from 'node:zlib';

const { coreLinkArguments } = await import('./swift-core-link.mjs');
const output = path.resolve('dist/qa/stream-route');
await mkdir(output,{recursive:true});
const root = await mkdtemp('/private/tmp/aa-stream-route-audit-');
const binary = path.join(root, 'DiscoveryPreview');
const children = [], servers = [], sockets = new Set();
const build = path.resolve('.build/release'), cache = path.resolve('.build/cache/StreamRouteAudit');
await mkdir(cache, {recursive:true});
const objects = (await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name));
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', cache, '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build), ...objects, 'Tests/fixtures/discovery-preview.swift', '-o', binary], {stdio:'inherit'});
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function start(label, known = []) {
  const directory = path.join(root,label); await mkdir(directory);
  await writeFile(path.join(directory,'web-known-peers.json'),JSON.stringify(known));
  const child = spawn(binary,[directory],{stdio:['ignore','ignore','pipe']}); children.push(child); child.stderr.resume();
  let ready;
  for(let i=0; i<150 && !ready; i++) {
    try { ready = JSON.parse(await readFile(path.join(directory,'ready.json'),'utf8')); } catch {}
    if(!ready) await wait(50);
  }
  assert.ok(ready,'Isolated fixture did not start'); return ready;
}
async function json(url) { const response = await fetch(url,{signal:AbortSignal.timeout(8000)}); assert.equal(response.status,200); return response.json(); }
const id = randomUUID(), sessionID = 'isolated-audit-session';
const stats = {primaryStream:0,backupStream:0,backupState:0,posts:0,gzipNegotiated:0};
const activeStreams = new Set();
let mode='closed', template, primaryURL, backupURL;
function server(backup) {
  const instance = createServer((req,res) => {
    if(req.method !== 'GET') { stats.posts++; res.writeHead(405); res.end(); return; }
    if(req.headers['x-autoapprove-node'] && req.headers['x-autoapprove-node'] !== id) { res.writeHead(409); res.end(); return; }
    if(req.url.startsWith('/api/terminal/stream')) {
      activeStreams.add(req.socket);req.socket.once('close',()=>activeStreams.delete(req.socket));
      if(!backup) {
        stats.primaryStream++;
        if(mode==='closed'){req.socket.destroy();return;}
        if(mode==='stall'||mode==='cancel'||mode==='cancel-both'){return;}
        if(mode==='denied'){const body=JSON.stringify({error:'QA explicit permission denial'});res.writeHead(403,{'Content-Length':Buffer.byteLength(body),Connection:'close'});res.end(body);return;}
      } else {stats.backupStream++;if(mode==='cancel-both')return;}
      res.useChunkedEncodingByDefault = false;
      if(mode.startsWith('idle-')||mode==='send-stall'){
        const fault=mode;
        res.writeHead(200,{'Content-Type':'text/event-stream',...(fault==='idle-partial'?{'Content-Encoding':'gzip'}:{}),'X-AutoApprove-Node':id,Connection:'close'});res.flushHeaders();
        let timer,encoder;
        if(fault==='idle-partial'){
          encoder=createGzip({level:1});encoder.pipe(res,{end:false});encoder.write('event: screen\ndata: {');encoder.flush(constants.Z_SYNC_FLUSH);
          timer=setInterval(()=>{encoder.write(' ');encoder.flush(constants.Z_SYNC_FLUSH);},4000);
        }else if(fault==='idle-heartbeat'){
          res.write(': keepalive\n\n');timer=setInterval(()=>res.write(': keepalive\n\n'),10000);
        }else if(fault==='send-stall'){
          const text=randomBytes(400000).toString('base64');let sent=0;
          const pump=()=>{while(!res.destroyed&&sent<64){sent++;if(!res.write('event: screen\ndata: '+JSON.stringify({sessionID,screen:text,revision:'blocked-'+sent,observedAt:new Date().toISOString(),keys:[]})+'\n\n')){res.once('drain',pump);return;}}};pump();
        }
        res.once('close',()=>{clearInterval(timer);encoder?.destroy();});return;
      }
      if(mode.startsWith('gzip-')) {
        assert.equal(req.headers['accept-encoding'],'gzip');stats.gzipNegotiated++;
        const event=index=>'event: screen\nid: gzip-'+index+'\ndata: '+JSON.stringify({sessionID,screen:'압축 원본🙂 '+index+' '+String('x').repeat(mode==='gzip-bomb'?2_000_200:mode==='gzip-coalesced'?1_200_000:80000),revision:'gzip-'+index,keys:[],streamID:'same-gzip-original',observedAt:new Date().toISOString()})+'\n\n';
        const plain=Buffer.from(event(1)+(mode==='gzip-coalesced'?event(2):''));let wire=gzipSync(plain,{level:1});
        if(mode==='gzip-corrupt'){wire=Buffer.from(wire);wire[wire.length-5]^=255;}
        if(mode==='gzip-truncated')wire=wire.subarray(0,wire.length-5);
        res.writeHead(200,{'Content-Type':'text/event-stream','Content-Encoding':'gzip','X-AutoApprove-Node':id,Connection:'close'});
        if(mode==='gzip-fragmented'){
          res.write(wire.subarray(0,1));setTimeout(()=>{if(!res.destroyed)res.write(wire.subarray(1,11));},5);
          setTimeout(()=>{if(!res.destroyed)res.end(wire.subarray(11));},10);
        }else res.end(wire);
        return;
      }
      res.writeHead(200,{'Content-Type':'text/event-stream','X-AutoApprove-Node':(!backup&&mode==='identity')?randomUUID():id,Connection:'close'});
      const frame = {sessionID,screen:'Isolated read-only terminal',revision:'audit-1',observedAt:new Date().toISOString(),keys:[],streamID:'audit-stream'};
      res.write('event: screen\nid: audit-1\ndata: '+JSON.stringify(frame)+'\n\n');
      return;
    }
    if(req.url === '/api/state') {
      if(backup) stats.backupState++;
    }
    const body = JSON.stringify(req.url === '/api/discovery'
      ? {service:'autoapprove',version:1,id,name:'Isolated two-route peer',urls:[primaryURL,backupURL],port:Number(new URL(primaryURL).port),release:template.release}
      : {...template,id,name:'Isolated two-route peer',webURLs:[primaryURL,backupURL],webPort:Number(new URL(primaryURL).port)});
    res.writeHead(200,{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body),'X-AutoApprove-Node':id,Connection:'close'}); res.end(body);
  });
  instance.on('connection',socket => { sockets.add(socket); socket.on('close',()=>sockets.delete(socket)); });
  servers.push(instance); return instance;
}
try {
  const bootstrap = await start('bootstrap'); template = await json(bootstrap.url+'/api/state');
  const primary = server(false), backup = server(true);
  await new Promise(resolve=>primary.listen(0,'127.0.0.1',resolve));
  await new Promise(resolve=>backup.listen(0,'127.0.0.1',resolve));
  primaryURL = 'http://127.0.0.1:'+primary.address().port; backupURL = 'http://127.0.0.1:'+backup.address().port;
  const checks=[];
  for(const fault of ['fast','closed','stall','denied','identity','cancel','cancel-both']) {
    mode=fault; const before={...stats};
    const gateway=await start('gateway-'+fault,[{id,name:'Isolated peer',address:primaryURL,urls:[primaryURL,backupURL],port:primary.address().port,release:template.release,lastSeen:new Date().toISOString()}]);
    let online=false;
    for(let i=0;i<40&&!online;i++){online=(await json(gateway.url+'/api/network')).nodes.some(node=>node.id===id&&node.online);if(!online)await wait(100);}
    assert.ok(online,'Metadata/state must remain healthy');
    const controller=new AbortController(), started=performance.now();
    let timer;if(fault.startsWith('cancel'))timer=setTimeout(()=>controller.abort(),fault==='cancel'?100:350);
    let firstFrameMs=null;
    try {
      const response=await fetch(gateway.url+'/api/terminal/stream?node='+id+'&session='+sessionID,{signal:controller.signal});
      if(['fast','closed','stall'].includes(fault)) {
        assert.equal(response.status,200);assert.equal(response.headers.get('transfer-encoding'),null);
        const initial=await response.body.getReader().read();assert.match(new TextDecoder().decode(initial.value),/event: screen/);
        firstFrameMs=Math.round(performance.now()-started);
        assert.equal(stats.backupStream-before.backupStream,fault==='fast'?0:1);assert.ok(firstFrameMs<900,'A stalled primary must not add its former two-second timeout');controller.abort();
      } else {
        assert.equal(response.status,fault==='denied'?403:502);await response.text();assert.equal(stats.backupStream-before.backupStream,0);
      }
    } catch(error){if(!fault.startsWith('cancel')||!controller.signal.aborted)throw error;}
    finally{clearTimeout(timer);controller.abort();}
    await wait(400);assert.equal(stats.posts,0);assert.equal(activeStreams.size,0,'Cancelled or losing subscriptions must release all upstream sockets');
    assert.equal(stats.primaryStream-before.primaryStream,1);if(fault==='cancel')assert.equal(stats.backupStream-before.backupStream,0);if(fault==='cancel-both')assert.equal(stats.backupStream-before.backupStream,1);
    checks.push({fault,firstFrameMs,elapsedMs:Math.round(performance.now()-started),primaryRequests:stats.primaryStream-before.primaryStream,backupRequests:stats.backupStream-before.backupStream});
  }
  const gzipGateway=await start('gzip-gateway',[{id,name:'Isolated gzip peer',address:primaryURL,urls:[primaryURL],port:primary.address().port,release:template.release,lastSeen:new Date().toISOString()}]);
  let gzipOnline=false;
  for(let i=0;i<50&&!gzipOnline;i++){gzipOnline=(await json(gzipGateway.url+'/api/network')).nodes.some(node=>node.id===id&&node.online);if(!gzipOnline)await wait(100);}
  assert.ok(gzipOnline,'Compressed peer metadata must be ready before subscribing');
  for(const fault of ['gzip-fragmented','gzip-coalesced','gzip-corrupt','gzip-truncated','gzip-bomb']){
    mode=fault;const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),8000),before=stats.gzipNegotiated;
    const events=[];let buffer='';
    try{
      const response=await fetch(gzipGateway.url+'/api/terminal/stream?node='+id+'&session='+sessionID,{signal:controller.signal});assert.equal(response.status,200);
      const decoder=new TextDecoder();for await(const chunk of response.body){buffer+=decoder.decode(chunk,{stream:true});let boundary;while((boundary=buffer.indexOf('\n\n'))>=0){const text=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);const json=text.split('\n').find(line=>line.startsWith('data: '));if(json)events.push({type:text.split('\n').find(line=>line.startsWith('event: ')).slice(7),data:JSON.parse(json.slice(6))});}assert.ok(buffer.length<2_000_128);}
      if(['gzip-fragmented','gzip-coalesced'].includes(fault)){
        assert.equal(events.length,fault==='gzip-coalesced'?2:1);assert.ok(events.every(e=>e.type==='screen'&&e.data.screen.startsWith('압축 원본🙂')));
      }else{
        assert.equal(events.at(-1)?.type,'failure');assert.equal(events.at(-1).data.retryable,fault!=='gzip-bomb');
        if(fault==='gzip-bomb')assert.equal(events.length,1,'Oversized decompressed event must never be forwarded as a partial JSON frame');
      }
      assert.equal(stats.gzipNegotiated-before,1);checks.push({fault,screenEvents:events.filter(e=>e.type==='screen').length,failure:events.at(-1)?.type==='failure',retryable:events.at(-1)?.data.retryable});
    }finally{clearTimeout(timer);controller.abort();}
    await wait(100);assert.equal(activeStreams.size,0,'Ended compressed subscriptions must release the upstream socket');
  }
  const pending=[];
  for(const fault of ['idle-empty','idle-partial','idle-heartbeat']){
    mode=fault;const controller=new AbortController(),started=performance.now();
    const response=await fetch(gzipGateway.url+'/api/terminal/stream?node='+id+'&session='+sessionID,{signal:controller.signal});assert.equal(response.status,200);
    pending.push((async()=>{
      const timer=setTimeout(()=>controller.abort(),fault==='idle-heartbeat'?37000:41000);let text='';
      try{for await(const part of response.body)text+=new TextDecoder().decode(part);}
      catch(error){if(fault!=='idle-heartbeat'||!controller.signal.aborted)throw error;}
      finally{clearTimeout(timer);controller.abort();}
      const elapsedMs=Math.round(performance.now()-started);
      if(fault==='idle-heartbeat'){
        assert.ok((text.match(/: keepalive/g)||[]).length>=4);assert.ok(!text.includes('event: failure'),'Healthy idle PTY heartbeats must not hit the event deadline');
      }else{
        assert.match(text,/event: failure/);assert.match(text,/"retryable":true/);assert.ok(!text.includes('event: screen'),'A stalled partial JSON event must never reach the browser');
        assert.ok(elapsedMs>=34000&&elapsedMs<40500,'Idle or trickled partial event must release within the bounded 35 second budget');
      }
      return {fault,elapsedMs,retryable: fault!=='idle-heartbeat'};
    })());
  }
  mode='send-stall';
  const blocked=createConnection({host:'127.0.0.1',port:new URL(gzipGateway.url).port});sockets.add(blocked);blocked.on('error',()=>{});blocked.on('close',()=>sockets.delete(blocked));
  await new Promise(resolve=>blocked.once('connect',resolve));blocked.pause();
  blocked.write('GET /api/terminal/stream?node='+id+'&session='+sessionID+' HTTP/1.1\r\nHost: 127.0.0.1:'+new URL(gzipGateway.url).port+'\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n');
  const blockedStarted=performance.now();
  pending.push((async()=>{
    await wait(1000);assert.equal(activeStreams.size,4,'All four isolated fault/control subscriptions must be open');
    // Idle tests above finish at 35/37 seconds. The send-window timeout must
    // release the blocked subscriber's upstream before either idle deadline.
    while(activeStreams.size===4&&performance.now()-blockedStarted<34000)await wait(100);
    const elapsedMs=Math.round(performance.now()-blockedStarted);assert.equal(activeStreams.size,3,'A non-reading downstream must release its upstream source after the send deadline');
    blocked.destroy();return {fault:'send-stall',elapsedMs,upstreamReleased:true};
  })());
  checks.push(...await Promise.all(pending));await wait(200);assert.equal(activeStreams.size,0);assert.equal(stats.posts,0);
  const report={result:'PASS',checks,posts:stats.posts,scope:'Release Swift Core; isolated loopback-only peers; no Bonjour, physical subnet scan or user CLI'};
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
} finally {
  for(const child of children)if(child.exitCode===null)child.kill();
  for(const socket of sockets)socket.destroy();
  await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));
  await wait(100); await rm(root,{recursive:true,force:true});
}
