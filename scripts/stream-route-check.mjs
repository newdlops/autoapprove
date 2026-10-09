import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtemp, mkdir, readdir, readFile, writeFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

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
const stats = {primaryStream:0,backupStream:0,backupState:0,posts:0};
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
  const report={result:'PASS',checks,posts:stats.posts,scope:'Release Swift Core; isolated loopback-only peers; no Bonjour, physical subnet scan or user CLI'};
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
} finally {
  for(const child of children)if(child.exitCode===null)child.kill();
  for(const socket of sockets)socket.destroy();
  await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));
  await wait(100); await rm(root,{recursive:true,force:true});
}
