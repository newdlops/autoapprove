// Actual Core HTTP/SSE, gzip wire bytes and browsers; only synthetic originals.
import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm,stat} from 'node:fs/promises';
import {get} from 'node:http';
import {createGunzip} from 'node:zlib';
import {StringDecoder} from 'node:string_decoder';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
import path from 'node:path';
const build=path.resolve('.build/release'),out=path.resolve('.runtime/performance/stream-093'),cache=path.resolve('.build/cache/StreamPayload');
await mkdir(out,{recursive:true});await mkdir(cache,{recursive:true});
const binary=path.join(out,'StreamPayloadPreview');
const objects=(await readdir(build+'/AutoApproveCore.build')).filter(name=>name.endsWith('.swift.o')).map(name=>build+'/AutoApproveCore.build/'+name);
if(process.argv.includes('--reuse-preview')){
 const modified=(await stat(binary)).mtimeMs;for(const input of [...objects,'Tests/fixtures/network-preview.swift'])assert.ok((await stat(input)).mtimeMs<=modified,'Fixture binary is stale; run without --reuse-preview');
}else execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:300000});
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
 const value={wireBytes:0,events:[],failures:[],encoding:null,error:null,closed:false};let response,decoder,buffer='',previous;const utf8=new StringDecoder('utf8');
 const consume=bytes=>{buffer+=utf8.write(bytes);let end;while((end=buffer.indexOf('\n\n'))>=0){const event=buffer.slice(0,end);buffer=buffer.slice(end+2);const json=event.split('\n').find(line=>line.startsWith('data: '));if(event.startsWith('event: failure')&&json)value.failures.push(JSON.parse(json.slice(6)));if(event.startsWith('event: screen')&&json){
  const update=JSON.parse(json.slice(6));let frame=update;
  if(update.screenPatch){const p=update.screenPatch;assert.equal(p.baseRevision,previous.revision);assert.equal(p.baseLength,previous.screen.length);assert.equal(update.streamID,previous.streamID);frame={...update,screen:previous.screen.slice(0,p.prefix)+p.text+previous.screen.slice(p.baseLength-p.suffix),appearance:update.appearanceUnchanged?previous.appearance:update.appearance};assert.equal(frame.screen.length,p.length);}
  else if(typeof update.screen!=='string'){assert.equal(update.revision,previous.revision);frame={...update,screen:previous.screen,appearance:previous.appearance};}
  previous=frame;value.events.push({frame,update,wire:value.wireBytes,time:performance.now()});
 }}};
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
  const identity=collect(gateway.url+route,'identity'),gzip=collect(gateway.url+route,'gzip'),delta=collect(gateway.url+route+'&delta=1','gzip');
  const all=[identity,gzip,delta];await until(()=>all.every(c=>c.events.length)||all.some(c=>c.error),'All first SSE frames');
  all.forEach(c=>assert.equal(c.error,null));assert.equal(identity.encoding,'identity');assert.equal(gzip.encoding,'gzip');assert.equal(delta.encoding,'gzip');
  const first=identity.events[0].frame;
  for(const c of [gzip,delta]){assert.equal(c.events[0].frame.screen,first.screen);assert.deepEqual(c.events[0].frame.keys,first.keys);assert.deepEqual(c.events[0].frame.appearance,first.appearance);assert.equal(c.events[0].update.screenPatch,undefined);}
  const latencies=[];
  for(let index=0;index<8;index++){
   const marker=' STREAM-'+label+'-'+index+'-'+randomUUID(),started=performance.now();
   await request(gateway,'/api/input'+(node?'?node='+node:''),{requestID:randomUUID(),sessionID:id,revision:delta.events.at(-1).frame.revision,kind:'text',text:marker});
   try{await until(()=>all.every(c=>c.events.some(e=>e.frame.screen?.includes(marker)))||all.some(c=>c.error||c.failures.length),'Live input echo on all stream formats');}
   catch(error){console.error(JSON.stringify({path:label,index,collectors:all.map(c=>({events:c.events.length,bytes:c.wireBytes,lastRevision:c.events.at(-1)?.frame.revision,echo:c.events.at(-1)?.frame.screen?.includes(marker),failures:c.failures,error:String(c.error)}))}));throw error;}
   all.forEach(c=>{assert.equal(c.error,null);assert.deepEqual(c.failures,[]);});const echoed=delta.events.find(e=>e.frame.screen?.includes(marker)),plainEcho=identity.events.find(e=>e.frame.screen?.includes(marker));
   assert.equal(echoed.frame.screen,plainEcho.frame.screen);assert.equal(echoed.frame.screen.split(marker).length-1,1);assert.deepEqual(echoed.frame.keys,plainEcho.frame.keys);assert.deepEqual(echoed.frame.appearance,plainEcho.frame.appearance);
   assert.ok(echoed.update.screenPatch,'Small changes on the same original should use a patch');assert.equal(echoed.update.screen,undefined);
   latencies.push(Math.round(echoed.time-started));
  }
  const changedFull=gzip.wireBytes-gzip.events[0].wire,changedDelta=delta.wireBytes-delta.events[0].wire;
  assert.ok(changedDelta<changedFull*0.3,'Delta + gzip should reduce repeated large screen traffic beyond gzip alone');
  metrics.push({path:label,firstIdentityBytes:identity.events[0].wire,firstGzipBytes:gzip.events[0].wire,firstDeltaGzipBytes:delta.events[0].wire,edits:8,changedGzipBytes:changedFull,changedDeltaGzipBytes:changedDelta,deltaEchoMS:latencies,patches:delta.events.filter(e=>e.update.screenPatch).length});
  all.forEach(c=>c.close());
  const fresh=collect(gateway.url+route+'&delta=1','gzip');await until(()=>fresh.events.length||fresh.error,'Reconnection starts with full screen');assert.equal(fresh.error,null);assert.equal(typeof fresh.events[0].update.screen,'string');assert.equal(fresh.events[0].update.screenPatch,undefined);fresh.close();
  const refused=collect(gateway.url+route,'gzip;q=0, *;q=1');await until(()=>refused.events.length||refused.error,'gzip q=0 identity fallback');assert.equal(refused.error,null);assert.equal(refused.encoding,'identity');refused.close();
  checks.push(label+': full/patch/gzip exact screen/colors/controls, 8 echoes once, full reconnect and explicit gzip refusal');
  await writeFile(path.join(out,'stream-progress.json'),JSON.stringify({metrics,checks,status:'HTTP passed; browser checks pending'},null,2));
 }
 const {chromium,webkit}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
 for(const [name,engine]of [['chromium',chromium],['webkit',webkit]]){
  const browser=await engine.launch({headless:true,...(name==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
  try{
   const page=await browser.newPage({viewport:{width:390,height:844}});page.setDefaultTimeout(15000);let gzipResponse=false;
   page.on('pageerror',error=>errors.push(name+': '+error.message));page.on('response',async response=>{if(response.url().includes('/api/terminal/stream')&&(await response.allHeaders())['content-encoding']==='gzip')gzipResponse=true;});
   await page.goto(a.url+'#'+new URLSearchParams({node:b.id,session:id}));
   await page.waitForFunction(id=>latestFrame?.sessionID===id&&latestFrame.screen.includes('[합성 빌드 599]')&&terminalStream?.sseReady&&terminalStream.frame,id);
   await until(()=>gzipResponse,name+' native EventSource gzip response');
   await page.evaluate(()=>{$('terminal-settings').open=true;});await page.locator('#compose-input').check();
   const marker=' BROWSER-'+name+'-'+randomUUID();await page.locator('#terminal-input').fill(marker);await page.locator('#send-input').click();
   await page.waitForFunction(marker=>latestFrame?.screen.includes(marker),marker);assert.equal(await page.evaluate(marker=>latestFrame.screen.split(marker).length-1,marker),1);
   // Composed submission deliberately reopens its stream. Observe the new
   // baseline, then simulate another viewer's fixture input while it stays live.
   await page.waitForFunction(()=>terminalStream?.sseReady&&terminalStream.frame&&!inputInFlight);
   await page.evaluate(()=>{window.qaPatches=0;terminalStream.source.addEventListener('screen',event=>{if(JSON.parse(event.data).screenPatch)window.qaPatches++;});});
   const current=await request(b,'/api/terminal?'+new URLSearchParams({session:id})),outputMarker=' FIXTURE-OUTPUT-'+randomUUID();
   await request(b,'/api/input',{requestID:randomUUID(),sessionID:id,revision:current.revision,kind:'text',text:outputMarker});
   await page.waitForFunction(marker=>latestFrame?.screen.includes(marker),outputMarker);
   await page.waitForFunction(()=>window.qaPatches>0);assert.ok(await page.evaluate(()=>latestFrame.appearance.runs.length>0));
   checks.push(name+': real mobile page EventSource applies relayed gzip patches and explicit input echoes once with original colors');
  }finally{await browser.close();}
 }
 assert.deepEqual(errors,[]);await writeFile(path.join(out,'stream-verification.json'),JSON.stringify({metrics,checks,errors,scope:'Synthetic originals, raw HTTP body bytes; comparison is current full gzip versus negotiated patch gzip; native upstream negotiates gzip; no user sessions'},null,2));console.log(JSON.stringify({metrics,checks,errors},null,2));
}finally{for(const c of collectors)c.close();for(const child of children)child.kill();await Promise.all(children.map(child=>child.exitCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));await rm(root,{recursive:true,force:true});}
