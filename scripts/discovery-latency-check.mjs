// Actual linked Core, owned loopback peers and stalled HTTP responses only.
// No physical subnet scan, user terminal, input or system settings are touched.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdir,mkdtemp,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';

const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/release'),output=path.resolve(option('output')||'dist/qa/discovery-latency');
await mkdir(output,{recursive:true});const root=await mkdtemp('/private/tmp/aa-discovery-latency-');
const binary=path.join(output,'DiscoveryPreview'),cache=path.resolve('.build/cache/DiscoveryLatency');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),'Tests/fixtures/discovery-preview.swift','-o',binary],{stdio:'inherit'});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms)),children=[],servers=[],checks=[];
const json=async(url)=>{const response=await fetch(url,{signal:AbortSignal.timeout(5000)});assert.equal(response.status,200);return response.json();};
async function fixture(name,known=[],candidates=[]) {
  const directory=path.join(root,name);await mkdir(directory);
  for(const[file,value]of [['web-known-peers.json',known],['candidates.json',candidates],['hints.json',[]]])await writeFile(path.join(directory,file),JSON.stringify(value));
  const child=spawn(binary,[directory],{stdio:['ignore','ignore','pipe']});children.push(child);let errors='';child.stderr.on('data',data=>errors+=data);
  for(let i=0;i<200;i++){try{return {...JSON.parse(await readFile(path.join(directory,'ready.json'),'utf8')),child};}catch{}assert.equal(child.exitCode,null,errors);await wait(25);}
  throw Error('Fixture did not start: '+errors);
}
async function peer(template,{stall=false,traffic}={}) {
  const id=randomUUID(),sockets=new Set(),stats={unpinned:0};let url;
  const server=createServer((req,res)=>{
    if(!req.headers['x-autoapprove-node'])stats.unpinned++;
    if(traffic){traffic.active++;traffic.peak=Math.max(traffic.peak,traffic.active);traffic.requests++;res.once('close',()=>traffic.active--);}
    if(stall)return;
    const body=JSON.stringify(req.url==='/api/discovery'?{service:'autoapprove',version:1,id,name:'Synthetic discovery peer',urls:[url],port:Number(new URL(url).port),release:template.release}:{...template,id,name:'Synthetic discovery peer',webURLs:[url],webPort:Number(new URL(url).port)});
    res.writeHead(200,{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body),'X-AutoApprove-Node':id,Connection:'close'});res.end(body);
  });
  server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));servers.push({server,sockets});url='http://127.0.0.1:'+server.address().port;return {id,url,stats};
}
async function find(gateway,id,budget=5500) {
  const start=performance.now();let found=false;
  while(performance.now()-start<budget){const value=await json(gateway.url+'/api/network');if(value.nodes.some(node=>node.id===id&&node.online)){found=true;break;}await wait(50);}
  return {found,ms:Math.round(performance.now()-start)};
}
async function stop(child){if(child.exitCode!==null||child.signalCode!==null)return;child.kill();await new Promise(resolve=>child.once('exit',resolve));}
try {
  const bootstrap=await fixture('bootstrap'),template=await json(bootstrap.url+'/api/state');await stop(bootstrap.child);
  for(const existing of [false,true]) {
    const traffic={active:0,peak:0,requests:0};
    const blocked=await Promise.all(Array.from({length:16},()=>peer(template,{stall:true,traffic}))),target=await peer(template),saved=existing?await peer(template):null;
    const known=saved?[{id:saved.id,name:'Already known Mac',address:saved.url,urls:[saved.url],port:Number(new URL(saved.url).port),release:template.release,lastSeen:new Date().toISOString().replace(/\.\d+Z$/,'Z')}]:[];
    const gateway=await fixture(existing?'same-lan-newcomer':'cold-tail',known,[...(saved?[saved.url]:[]),...blocked.map(row=>row.url),target.url]);
    if(saved)assert.equal((await find(gateway,saved.id,2000)).found,true,'The first Mac remains quickly available');
    const result=await find(gateway,target.id);
    checks.push({case:existing?'A second Mac on an already reached LAN':'Cold discovery behind sixteen silent addresses',...result,stalledRequests:traffic.requests,peakStalledConnections:traffic.peak,budgetMS:5500});
    if(saved)assert.equal(saved.stats.unpinned,0,'A healthy saved address never needs an unpinned blind probe');
    assert.ok(traffic.peak<=8,'Discovery must leave input and dashboard traffic independent');await stop(gateway.child);
  }
  const replacement=await peer(template),oldID=randomUUID();
  const reused=await fixture('reused-address',[{id:oldID,name:'Previous address owner',address:replacement.url,urls:[replacement.url],port:Number(new URL(replacement.url).port),release:template.release,lastSeen:new Date().toISOString().replace(/\.\d+Z$/,'Z')}],[replacement.url]);
  const identified=await find(reused,replacement.id);
  const nodes=(await json(reused.url+'/api/network')).nodes;
  assert.ok(!nodes.find(node=>node.id===oldID)?.online,'A new machine must never impersonate the saved identity');
  checks.push({case:'A new machine at an old saved IP',...identified,unpinnedDiscoveryReads:replacement.stats.unpinned,budgetMS:5500});await stop(reused.child);
  const report={result:checks.every(row=>row.found)?'PASS':'FAIL',checks,scope:'Actual compiled Core with synthetic loopback HTTP timeouts, not physical phone/LAN timing'};
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));assert.ok(checks.every(row=>row.found),'Late candidates must be discovered within the same bounded budget, even after another Mac was found');
} finally {
  await Promise.all(children.map(stop));for(const{server,sockets}of servers){for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));}await rm(root,{recursive:true,force:true});
}
