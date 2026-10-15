// Actual Swift gateway with loopback-only synthetic peers. No user terminal.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import path from 'node:path';
const option=name=>process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3);
const binary=path.resolve(option('binary')||'.runtime/performance/connection-095/StreamPayloadPreview');
const output=path.resolve(option('output')||'dist/qa/peer-read-route.json'),baseline=process.argv.includes('--baseline');
await mkdir(path.dirname(output),{recursive:true});
const root=await mkdtemp('/private/tmp/aa-peer-read-'),children=[],servers=[],sockets=new Set(),checks=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,ms=10000){const end=performance.now()+ms;while(!test()){assert.ok(performance.now()<end,label);await wait(20);}}
async function start(label){
 const child=spawn(binary,[path.join(root,label),label,'--direct-only'],{stdio:['ignore','pipe','pipe']});children.push(child);let buffer='',error='',ready;
 child.stdout.on('data',part=>{buffer+=part;for(const line of buffer.split('\n'))if(line.startsWith('{'))try{const value=JSON.parse(line);if(value.url)ready=value;}catch{}});child.stderr.on('data',part=>error+=part);
 await until(()=>!!ready||child.exitCode!==null||child.signalCode!==null,'Gateway startup: '+error,20000);assert.ok(ready,error);return {...ready,child};
}
async function json(url,body,signal){const response=await fetch(url,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal:signal||AbortSignal.timeout(12000)});return {status:response.status,value:await response.json()};}
const id=randomUUID(),session='original+한글',screen=Array.from({length:600},(_,i)=>`[합성 ${i}] /fixture/project/module-${i}.swift · 원본 화면·질문·색상🙂`).join('\n');
let template,primaryURL,backupURL,mode='fast';
const stats={primaryReads:0,backupReads:0,primaryPosts:0,backupPosts:0,gzip:0,wireBytes:0,plainBytes:0,peakReads:0},activeReads=new Set();
function peer(backup){
 const server=createServer(async(req,res)=>{
  const fault=mode,terminal=req.url.startsWith('/api/terminal?'),stalledState=fault==='deadline'&&req.url==='/api/state';
  const send=(status,value,headers={})=>{
   let body=Buffer.from(JSON.stringify(value));const size=body.length,gzip=fault!=='legacy'&&req.headers['accept-encoding']==='gzip'&&status===200;
   if(gzip){body=gzipSync(body,{level:6});if(terminal)stats.gzip++;}
   if(fault==='corrupt'&&!backup&&terminal){body=Buffer.from(body);body[body.length-5]^=255;}
   if(terminal){stats.plainBytes+=size;stats.wireBytes+=body.length;}
   res.writeHead(status,{'Content-Type':'application/json','Content-Length':body.length+(fault==='truncated'&&!backup&&terminal?5:0),...(fault==='legacy'?{}:{'X-AutoApprove-Node':fault==='identity'&&!backup&&terminal?randomUUID():id}),...(gzip?{'Content-Encoding':'gzip'}:{}),Connection:'close',...headers});res.end(body);
  };
  if(req.method==='POST'){
   stats[backup?'backupPosts':'primaryPosts']++;for await(const _ of req){}req.socket.destroy();return;
  }
  if(terminal||stalledState){
   if(terminal)assert.equal(new URL(req.url,'http://localhost').searchParams.get('session'),session);assert.equal(req.headers['x-autoapprove-node'],id);
   stats[backup?'backupReads':'primaryReads']++;activeReads.add(req.socket);req.socket.once('close',()=>activeReads.delete(req.socket));
   stats.peakReads=Math.max(stats.peakReads,activeReads.size);
   if(stalledState||fault==='both-stall'||!backup&&['slow','cancel','closed'].includes(fault)) {if(fault==='closed')req.socket.destroy();return;}
   if(fault==='denied'&&!backup)return send(403,{error:'Synthetic explicit denial'});
   if(fault==='unavailable'&&!backup)return send(503,{error:'Synthetic temporarily unavailable'});
   return send(200,{sessionID:session,screen,revision:'same-original',streamID:'verified-original',observedAt:new Date().toISOString(),keys:['enter'],appearance:{runs:[{offset:0,length:4,fg:'#87d7ff'}]}});
  }
  return send(200,req.url==='/api/discovery'?{service:'autoapprove',version:1,id,name:'Synthetic route peer',urls:[primaryURL,backupURL],port:Number(new URL(primaryURL).port),release:template.release}:{...template,id,name:'Synthetic route peer',webURLs:[primaryURL,backupURL],webPort:Number(new URL(primaryURL).port)});
 });
 server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});servers.push(server);return server;
}
async function gateway(label){
 const instance=await start(label),added=await json(instance.url+'/api/peers',{address:primaryURL});assert.equal(added.status,200);return instance;
}
try{
 const bootstrap=await start('bootstrap');template=(await json(bootstrap.url+'/api/state')).value;
 const primary=peer(false),backup=peer(true);await new Promise(resolve=>primary.listen(0,'127.0.0.1',resolve));await new Promise(resolve=>backup.listen(0,'127.0.0.1',resolve));
 primaryURL='http://127.0.0.1:'+primary.address().port;backupURL='http://127.0.0.1:'+backup.address().port;
 const route='/api/terminal?'+new URLSearchParams({node:id,session});
 for(const fault of baseline?['fast','slow','slow','slow']:['fast','legacy','slow','slow','slow','closed','unavailable','denied','identity','corrupt','truncated']){
  mode=fault;const owner=await gateway(fault+'-'+checks.length),before={...stats},started=performance.now(),result=await json(owner.url+route);
  const elapsedMs=Math.round(performance.now()-started),backupRequests=stats.backupReads-before.backupReads;
  if(['denied','identity'].includes(fault)){
   assert.equal(result.status,fault==='denied'?403:502);assert.equal(backupRequests,0);
  }else{
   assert.equal(result.status,200);assert.equal(result.value.screen,screen);assert.equal(result.value.streamID,'verified-original');assert.deepEqual(result.value.appearance.runs,[{offset:0,length:4,fg:'#87d7ff'}]);
   assert.equal(backupRequests,['fast','legacy'].includes(fault)?0:1);if(!baseline)assert.ok(elapsedMs<1200,'A stalled route must not consume the phone read timeout');
  }
  await until(()=>activeReads.size===0,'Winner and losing sockets must be released');
  let warmMs;
  if(fault==='slow'){
   const p=stats.primaryReads,now=performance.now();assert.equal((await json(owner.url+route)).status,200);warmMs=Math.round(performance.now()-now);assert.equal(stats.primaryReads,p,'Next read must reuse the successful route');
  }
  checks.push({fault,elapsedMs,warmMs,primaryRequests:stats.primaryReads-before.primaryReads,backupRequests,gzipResponses:stats.gzip-before.gzip,plainBytes:stats.plainBytes-before.plainBytes,wireBytes:stats.wireBytes-before.wireBytes});
  owner.child.kill();
 }
 if(!baseline){
  for(const [label,delay]of [['before-hedge',70],['both-open',350]]){
   mode='both-stall';const owner=await gateway(label),before={...stats},controller=new AbortController(),timer=setTimeout(()=>controller.abort(),delay);
   await assert.rejects(json(owner.url+route,undefined,controller.signal));clearTimeout(timer);await until(()=>activeReads.size===0,'Cancelled route reads must release both sockets');
   assert.equal(stats.backupReads-before.backupReads,label==='before-hedge'?0:1);checks.push({fault:'cancel-'+label,primaryRequests:stats.primaryReads-before.primaryReads,backupRequests:stats.backupReads-before.backupReads});
   owner.child.kill();
  }
  mode='fast';const bounded=await gateway('deadline');mode='deadline';const started=performance.now(),timed=await json(bounded.url+'/api/state?node='+id),elapsedMs=Math.round(performance.now()-started);
  assert.equal(timed.status,504);assert.ok(elapsedMs>=3800&&elapsedMs<4800);await until(()=>activeReads.size===0,'Both failed routes must close within the original shared deadline');bounded.child.kill();checks.push({fault:'both-stalled-deadline',elapsedMs});
  mode='fast';const owner=await gateway('one-post'),before={...stats};const reply=await json(owner.url+'/api/action?node='+id,{action:'pause',paused:true,requestID:randomUUID()});assert.ok(reply.status>=400);assert.equal(stats.primaryPosts-before.primaryPosts,1);assert.equal(stats.backupPosts-before.backupPosts,0);checks.push({fault:'uncertain-post',primaryPosts:1,backupPosts:0});
 }
 assert.ok(stats.peakReads<=2);const report={baseline,checks,peakReads:stats.peakReads,scope:'Actual Swift gateway and bounded loopback-only synthetic peers; no user CLI or physical VPN changes'};await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();for(const socket of sockets)socket.destroy();
 await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));await rm(root,{recursive:true,force:true});
}
