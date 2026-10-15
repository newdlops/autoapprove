// Actual Core HTTP/SSE, gzip wire bytes and browsers; only synthetic originals.
import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {get} from 'node:http';
import {createGunzip} from 'node:zlib';
import {StringDecoder} from 'node:string_decoder';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
import path from 'node:path';
const build=path.resolve('.build/release'),out=path.resolve('.runtime/performance/payload-092'),cache=path.resolve('.build/cache/StreamPayload');
await mkdir(out,{recursive:true});await mkdir(cache,{recursive:true});
const binary=path.join(out,'StreamPayloadPreview');
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...(await readdir(build+'/AutoApproveCore.build')).filter(name=>name.endsWith('.swift.o')).map(name=>build+'/AutoApproveCore.build/'+name),'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:300000});
const root=await mkdtemp('/private/tmp/aa-stream-payload-'),children=[],collectors=[],checks=[],metrics=[],errors=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,timeout=10000){const end=performance.now()+timeout;while(!test()){assert.ok(performance.now()<end,label);await wait(20);}}
async function start(label){
 const child=spawn(binary,[path.join(root,label),label,'--direct-only','--stream-payload'],{stdio:['ignore','pipe','pipe']});children.push(child);
 let buffer='',stderr='',info;child.stdout.on('data',part=>{buffer+=part;for(const line of buffer.split('\n'))if(line.startsWith('{'))try{const value=JSON.parse(line);if(value.url)info=value;}catch{}});child.stderr.on('data',part=>stderr+=part);
 await until(()=>!!info,'Fixture startup: '+stderr,20000);return info;
}
async function request(node,route,body){const r=await fetch(node.url+route,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});const value=await r.json();assert.equal(r.status,200,JSON.stringify(value));return value;}
function collect(url,encoding){
 const value={wireBytes:0,events:[],encoding:null,error:null,closed:false};let response,decoder,buffer='';const utf8=new StringDecoder('utf8');
 const consume=bytes=>{buffer+=utf8.write(bytes);let end;while((end=buffer.indexOf('\n\n'))>=0){const event=buffer.slice(0,end);buffer=buffer.slice(end+2);const json=event.split('\n').find(line=>line.startsWith('data: '));if(event.startsWith('event: screen')&&json)value.events.push({frame:JSON.parse(json.slice(6)),wire:value.wireBytes,time:performance.now()});}};
 const req=get(url,{headers:{'Accept-Encoding':encoding}},res=>{
  response=res;assert.equal(res.statusCode,200);value.encoding=res.headers['content-encoding']||'identity';
  if(value.encoding==='gzip'){decoder=createGunzip();decoder.on('data',consume);decoder.on('error',error=>{if(!value.closed)value.error=error;});}
  res.on('data',chunk=>{value.wireBytes+=chunk.length;if(decoder)decoder.write(chunk);else consume(chunk);});
  res.on('error',error=>{if(!value.closed)value.error=error;});
 });req.on('error',error=>{if(!value.closed)value.error=error;});
 value.close=()=>{value.closed=true;req.destroy();response?.destroy();decoder?.destroy();};collectors.push(value);return value;
}
try{
 const [a,b]=await Promise.all([start('A'),start('B')]);await request(a,'/api/peers',{address:b.url});
 const state=await request(b,'/api/state'),id=state.sessions[0].session.id;
 for(const [label,gateway,node]of [['direct',b,null],['relayed',a,b.id]]){
  const route='/api/terminal/stream?'+new URLSearchParams({session:id,...(node?{node}:{})});
  const identity=collect(gateway.url+route,'identity'),gzip=collect(gateway.url+route,'gzip');
  await until(()=>identity.events.length&&gzip.events.length||identity.error||gzip.error,'Both first SSE frames');
  assert.equal(identity.error,null);assert.equal(gzip.error,null);assert.equal(identity.encoding,'identity');assert.equal(gzip.encoding,'gzip');
  const first=identity.events[0].frame,compressed=gzip.events[0].frame;
  assert.equal(compressed.screen,first.screen);assert.deepEqual(compressed.keys,first.keys);assert.deepEqual(compressed.appearance,first.appearance);
  const marker=' STREAM-'+label+'-'+randomUUID(),started=performance.now();
  await request(gateway,'/api/input'+(node?'?node='+node:''),{requestID:randomUUID(),sessionID:id,revision:first.revision,kind:'text',text:marker});
  await until(()=>identity.events.some(e=>e.frame.screen?.includes(marker))&&gzip.events.some(e=>e.frame.screen?.includes(marker)),'Input echo without compression buffering');
  const echoed=gzip.events.find(e=>e.frame.screen?.includes(marker)),plainEcho=identity.events.find(e=>e.frame.screen?.includes(marker));
  assert.equal(echoed.frame.screen,plainEcho.frame.screen);assert.equal(echoed.frame.screen.split(marker).length-1,1);assert.deepEqual(echoed.frame.keys,plainEcho.frame.keys);
  assert.ok(gzip.events[0].wire<identity.events[0].wire/2,'Large original first screen should shrink on the wire');
  metrics.push({path:label,firstIdentityBytes:identity.events[0].wire,firstGzipBytes:gzip.events[0].wire,echoGzipMS:Math.round(echoed.time-started),echoIdentityMS:Math.round(plainEcho.time-started),echoIdentityBytes:plainEcho.wire-identity.events[0].wire,echoGzipBytes:echoed.wire-gzip.events[0].wire});
  identity.close();gzip.close();
  const refused=collect(gateway.url+route,'gzip;q=0, *;q=1');await until(()=>refused.events.length||refused.error,'gzip q=0 identity fallback');assert.equal(refused.error,null);assert.equal(refused.encoding,'identity');refused.close();
  checks.push(label+': exact screen/colors/controls, live echo once and explicit gzip refusal');
 }
 const {chromium,webkit}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
 for(const [name,engine]of [['chromium',chromium],['webkit',webkit]]){
  const browser=await engine.launch({headless:true,...(name==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
  try{
   const page=await browser.newPage({viewport:{width:390,height:844}});page.setDefaultTimeout(15000);let gzipResponse=false;
   page.on('pageerror',error=>errors.push(name+': '+error.message));page.on('response',async response=>{if(response.url().includes('/api/terminal/stream')&&(await response.allHeaders())['content-encoding']==='gzip')gzipResponse=true;});
   await page.goto(a.url+'#'+new URLSearchParams({node:b.id,session:id}));
   await page.waitForFunction(id=>latestFrame?.sessionID===id&&latestFrame.screen.includes('[합성 빌드 599]'),id);
   await until(()=>gzipResponse,name+' native EventSource gzip response');
   await page.evaluate(()=>{$('terminal-settings').open=true;});await page.locator('#compose-input').check();
   const marker=' BROWSER-'+name+'-'+randomUUID();await page.locator('#terminal-input').fill(marker);await page.locator('#send-input').click();
   await page.waitForFunction(marker=>latestFrame?.screen.includes(marker),marker);assert.equal(await page.evaluate(marker=>latestFrame.screen.split(marker).length-1,marker),1);
   checks.push(name+': real mobile page EventSource decompresses relayed SSE and explicit input echoes exactly once');
  }finally{await browser.close();}
 }
 assert.deepEqual(errors,[]);await writeFile(path.join(out,'stream-verification.json'),JSON.stringify({metrics,checks,errors,scope:'Synthetic originals, raw HTTP body bytes and Chromium/WebKit EventSource; browser leg gzip, native upstream identity; no user sessions'},null,2));console.log(JSON.stringify({metrics,checks,errors},null,2));
}finally{for(const c of collectors)c.close();for(const child of children)child.kill();await Promise.all(children.map(child=>child.exitCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));await rm(root,{recursive:true,force:true});}
