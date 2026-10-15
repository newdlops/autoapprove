// Actual Swift owners/gateways and compressed SSE. Synthetic originals only.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {get} from 'node:http';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import {createHash,randomUUID} from 'node:crypto';
import {createGunzip} from 'node:zlib';
import {StringDecoder} from 'node:string_decoder';
import path from 'node:path';
const option=name=>process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('binary'),'Pass a compiled network-preview fixture with --binary');
const binary=path.resolve(option('binary')),gatewayBinary=path.resolve(option('gateway-binary')||binary),baseline=process.argv.includes('--baseline');
const output=path.resolve(option('output')||'dist/qa/scroll-stream.json');await mkdir(path.dirname(output),{recursive:true});
const root=await mkdtemp('/private/tmp/aa-scroll-stream-'),children=[],collectors=[],checks=[],metrics=[],errors=[],browserWarnings=[];
const selectLines=(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/index.html','utf8')).split('\n').flatMap((line,index)=>line.includes('<select')?[index+1]:[]);
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,ms=15000){const deadline=performance.now()+ms;while(!test()){assert.ok(performance.now()<deadline,label);await wait(15);}}
async function start(label,executable,scroll){
 const child=spawn(executable,[path.join(root,label),label,'--direct-only',...(scroll?['--scroll-payload']:[])],{stdio:['ignore','pipe','pipe']});children.push(child);let lines='',stderr='',ready;
 child.stdout.on('data',part=>{lines+=part;for(const line of lines.split('\n'))if(line.startsWith('{'))try{const value=JSON.parse(line);if(value.url)ready=value;}catch{}});child.stderr.on('data',part=>stderr+=part);
 await until(()=>ready||child.exitCode!==null||child.signalCode!==null,'Swift fixture startup: '+stderr,20000);assert.ok(ready,stderr);return ready;
}
async function request(owner,route,body){
 const response=await fetch(owner.url+route,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(15000)});
 const value=await response.json();assert.equal(response.status,200,JSON.stringify(value));return value;
}
function collect(url){
 const state={events:[],wire:0,error:null,closed:false};let response,decoder,buffer='',previous;const utf8=new StringDecoder('utf8');
 const consume=bytes=>{try{
  buffer+=utf8.write(bytes);let boundary;
  while((boundary=buffer.indexOf('\n\n'))>=0){
   const event=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);const line=event.split('\n').find(row=>row.startsWith('data: '));if(!line)continue;
   assert.ok(!event.startsWith('event: failure'),line);const update=JSON.parse(line.slice(6));let frame=update;
   if(update.screenCopy){
    const p=update.screenCopy;assert.equal(update.screen,undefined);assert.equal(update.screenPatch,undefined);assert.equal(p.baseRevision,previous.revision);assert.equal(p.baseLength,previous.screen.length);assert.equal(update.streamID,previous.streamID);
    frame={...update,screen:p.head+previous.screen.slice(p.start,p.start+p.count)+p.tail,appearance:update.appearanceUnchanged?previous.appearance:update.appearance};assert.equal(frame.screen.length,p.length);
   }else if(update.screenPatch){
    const p=update.screenPatch;assert.equal(p.baseRevision,previous.revision);assert.equal(p.baseLength,previous.screen.length);
    frame={...update,screen:previous.screen.slice(0,p.prefix)+p.text+previous.screen.slice(p.baseLength-p.suffix),appearance:update.appearanceUnchanged?previous.appearance:update.appearance};assert.equal(frame.screen.length,p.length);
   }else if(typeof update.screen!=='string'){assert.equal(update.revision,previous.revision);frame={...update,screen:previous.screen,appearance:previous.appearance};}
   previous=frame;state.events.push({frame,update,wire:state.wire});
  }
  assert.ok(buffer.length<2_000_128);
 }catch(error){state.error=error;}};
 const req=get(url,{headers:{'Accept-Encoding':'gzip'}},res=>{
  response=res;if(res.statusCode!==200){state.error=new Error('SSE status '+res.statusCode);return;}
  assert.equal(res.headers['content-encoding'],'gzip');decoder=createGunzip();decoder.on('data',consume);decoder.on('error',error=>{if(!state.closed)state.error=error;});
  res.on('data',chunk=>{state.wire+=chunk.length;decoder.write(chunk);});res.on('error',error=>{if(!state.closed)state.error=error;});
 });req.on('error',error=>{if(!state.closed)state.error=error;});
 state.close=()=>{state.closed=true;req.destroy();response?.destroy();decoder?.destroy();};collectors.push(state);return state;
}
let serial=1000;
const marker=number=>String(number).padStart(5,'0')+' 합성 Codex';
try{
 const owner=await start('owner',binary,true),gateway=await start('gateway',gatewayBinary,false);await request(gateway,'/api/peers',{address:owner.url});
 const sessionID=(await request(owner,'/api/state')).sessions[0].session.id;
 for(const [label,node,target]of (process.argv.includes('--browser-only')?[]:[['direct',owner,null],['relayed',gateway,owner.id]])){
  const route='/api/terminal/stream?'+new URLSearchParams({session:sessionID,...(target?{node:target}:{})});
  const legacy=collect(node.url+route+'&delta=1'),copy=collect(node.url+route+'&delta=1&copy=1'),all=[legacy,copy];
  await until(()=>all.every(c=>c.events.length)||all.some(c=>c.error),'First complete frames');all.forEach(c=>{assert.equal(c.error,null);assert.equal(typeof c.events[0].update.screen,'string');assert.equal(c.events[0].update.screenCopy,undefined);});
  const times=[];
  for(let index=0;index<8;index++){
   const current=await request(owner,'/api/terminal?'+new URLSearchParams({session:sessionID})),next=serial,started=performance.now();serial+=3;
   await request(node,'/api/input'+(target?'?node='+target:''),{requestID:randomUUID(),sessionID,revision:current.revision,kind:'text',text:'SCROLL-'+(index%4<2?'DOWN':'UP')+'-'+label+'-'+index});
   await until(()=>all.every(c=>c.events.at(-1)?.frame.screen.includes(marker(next)))||all.some(c=>c.error),'Both stream formats apply the next scroll');
   all.forEach(c=>assert.equal(c.error,null));const full=await request(owner,'/api/terminal?'+new URLSearchParams({session:sessionID}));
   for(const c of all){const f=c.events.at(-1).frame;for(const field of ['screen','keys','appearance','cursor','question','streamID'])assert.deepEqual(f[field],full[field]);assert.equal(f.screen.split(marker(next)).length-1,1);}
   times.push(Math.round(performance.now()-started));
  }
  const legacyWire=legacy.wire-legacy.events[0].wire,copyWire=copy.wire-copy.events[0].wire,copies=copy.events.filter(e=>e.update.screenCopy).length;
  assert.equal(legacy.events.filter(e=>e.update.screenCopy).length,0,'Unnegotiated clients must never receive a copy');
  if(baseline)assert.equal(copies,0);else{assert.ok(copies>=8);assert.ok(copyWire<legacyWire*0.3,'Scroll reuse must reduce actual compressed traffic beyond the old delta + gzip');}
  metrics.push({path:label,scrolls:8,legacyChangedWireBytes:legacyWire,copyChangedWireBytes:copyWire,copies,elapsedMs:times});all.forEach(c=>c.close());
  const fresh=collect(node.url+route+'&delta=1&copy=1');await until(()=>fresh.events.length||fresh.error,'Full reconnect baseline');assert.equal(fresh.error,null);assert.equal(typeof fresh.events[0].update.screen,'string');assert.equal(fresh.events[0].update.screenCopy,undefined);fresh.close();
  checks.push(label+': negotiated scrolling preserves exact text/colors/cursor/keys/question and reconnects with a full screen');
 }
 if(!process.argv.includes('--no-browser')){
  const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
  for(const name of ['chromium','webkit']){
   const browser=await playwright[name].launch({headless:true,...(name==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
   try{
    const page=await browser.newPage({viewport:{width:390,height:844}});let phase='navigation';const consoleErrors=[];page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(name+': '+error.message));
    await page.addInitScript(()=>{window.qaCSP=[];document.addEventListener('securitypolicyviolation',e=>window.qaCSP.push({directive:e.effectiveDirective,source:e.sourceFile,line:e.lineNumber,blocked:e.blockedURI}));});
    page.on('console',message=>{if(message.type()==='error')consoleErrors.push({phase,text:message.text(),url:message.location().url});});
    page.on('response',response=>{if(response.status()>=400)errors.push(name+': HTTP '+response.status()+' '+new URL(response.url()).pathname);});
    await page.goto(gateway.url+'#'+new URLSearchParams({node:owner.id,session:sessionID}));await page.waitForFunction(()=>terminalStream?.sseReady&&terminalStream.frame);
    phase='settings';await page.evaluate(()=>{$('terminal-settings').open=true;});await page.locator('#compose-input').check();
    const first=serial;serial+=3;phase='fill';await page.locator('#terminal-input').fill('SCROLL-DOWN-BROWSER-'+name);phase='submit';await page.locator('#send-input').click();
    await page.waitForFunction(text=>latestFrame?.screen.includes(text),marker(first));await page.waitForFunction(()=>terminalStream?.sseReady&&terminalStream.frame&&!inputInFlight);
    await page.evaluate(()=>{window.qaCopies=0;terminalStream.source.addEventListener('screen',event=>{if(JSON.parse(event.data).screenCopy)window.qaCopies++;});});
    const current=await request(owner,'/api/terminal?'+new URLSearchParams({session:sessionID})),next=serial;serial+=3;
    await request(owner,'/api/input',{requestID:randomUUID(),sessionID,revision:current.revision,kind:'text',text:'SCROLL-UP-EXTERNAL-'+name});
    await page.waitForFunction(text=>latestFrame?.screen.includes(text),marker(next));if(!baseline)await page.waitForFunction(()=>window.qaCopies>0);
    const latest=await request(owner,'/api/terminal?'+new URLSearchParams({session:sessionID}));assert.equal(await page.evaluate(()=>latestFrame.screen),latest.screen);assert.deepEqual(await page.evaluate(()=>latestFrame.appearance),latest.appearance);
    assert.equal(await page.locator('.terminal-run').first().evaluate(element=>getComputedStyle(element).color),'rgb(135, 215, 255)');
    const violations=await page.evaluate(()=>window.qaCSP);
    // This WebKit build also reports one style-src-attr warning per native
    // <select> on a minimal page with no application JS or style attribute.
    // Preserve CSP; separate only that reproduced parser-time diagnostic.
    const nativeSelectWarnings=name==='webkit'&&violations.length>0&&violations.length<=selectLines.length&&new Set(violations.map(v=>v.line)).size===violations.length&&violations.every(v=>v.directive==='style-src-attr'&&v.blocked==='inline'&&v.source===''&&selectLines.includes(v.line))&&consoleErrors.length===violations.length&&consoleErrors.every(e=>e.phase==='navigation'&&e.text.startsWith('Refused to apply a stylesheet'))&&await page.locator('select[style]').count()===0;
    if(nativeSelectWarnings)browserWarnings.push({engine:name,type:'Native select CSP diagnostic reproduced without application JS',count:violations.length,lines:violations.map(v=>v.line)});
    else {errors.push(...consoleErrors.map(e=>name+': '+JSON.stringify(e)));if(violations.length)errors.push(name+': CSP details '+JSON.stringify(violations));}
    checks.push(name+': real relayed EventSource displays negotiated scroll copies with original colors after one explicit input');
   }finally{await browser.close();}
  }
 }
 assert.deepEqual(errors,[]);
 const report={baseline,ownerSHA256:createHash('sha256').update(await readFile(binary)).digest('hex'),gatewaySHA256:createHash('sha256').update(await readFile(gatewayBinary)).digest('hex'),metrics,checks,errors,browserWarnings,
  scope:'Actual Swift Core and gzip SSE, same controlled synthetic originals on direct/relayed routes; changed response-body bytes after the first screen, not all app traffic or physical phone/VPN measurements'};
 await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{
 collectors.forEach(c=>c.close());for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();
 await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));await rm(root,{recursive:true,force:true});
}
