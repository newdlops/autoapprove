// Real browser and Core, with a loopback proxy that can hold an already-open
// stream, delay reads and lose an input response. Only synthetic originals.
import assert from 'node:assert/strict';
import {createServer,request} from 'node:http';
import {readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fixtureSuite,until,wait} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const out=path.resolve(option('output')||'dist/qa/terminal-continuity-browser');
const webRoot=path.resolve(option('web-root')||'Sources/AutoApproveCore/Resources/RemoteWeb');
const baseline=process.argv.includes('--baseline'),engine=process.argv.includes('--webkit')?'webkit':'chromium';
const suite=await fixtureSuite(out,path.resolve(option('core-build')||'.build/release')),checks=[],metrics=[],errors=[];
let browser,server,readDelay=0,failReads=false,loseInput=false;
const counts={streams:0,reads:0,inputs:0,ptys:0},streamQueries=[],held=new Set(),streams=new Map();
try{
 const owner=await suite.start('owner');
 server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://fixture');
  const stream=url.pathname==='/api/terminal/stream',read=url.pathname==='/api/terminal';
  if(stream)streamQueries.push({revision:url.searchParams.get('revision'),stream:url.searchParams.get('stream'),compact:url.searchParams.get('compact'),wire:url.searchParams.get('wire')});
  if(read)counts.reads++;
  if(url.pathname==='/api/input')counts.inputs++;
  if(url.pathname.startsWith('/api/pty'))counts.ptys++;
  // Load the exact current UI while the linked Core controls all API behavior.
  if(['/','/index.html','/app.js','/app.css','/terminal-wire.js'].includes(url.pathname)){
   const file=url.pathname==='/'?'index.html':url.pathname.slice(1);
   const body=await readFile(path.join(webRoot,file));
   res.writeHead(200,{'Content-Type':file.endsWith('.html')?'text/html':file.endsWith('.css')?'text/css':'text/javascript','Cache-Control':'no-store'});res.end(body);return;
  }
  if((read||stream)&&readDelay)await wait(readDelay);
  if(res.destroyed)return;
  if((read||stream)&&failReads){res.writeHead(503,{'Content-Type':'application/json'});res.end('{"error":"Synthetic LAN outage"}');return;}
  const target=new URL(req.url,owner.url),headers={...req.headers,host:target.host,'accept-encoding':'identity'};
  if(headers.origin)headers.origin=owner.url;
  const number=stream?++counts.streams:0;
  const upstream=request(target,{method:req.method,headers},response=>{
   const drop=url.pathname==='/api/input'&&loseInput;if(drop)loseInput=false;
   if(!drop)res.writeHead(response.statusCode,response.headers);
   else {res.writeHead(200,{'Content-Type':'application/json','Content-Length':'256'});res.flushHeaders();}
   if(stream){
    streams.set(number,res);
    const version=response.headers['content-type']?.endsWith('terminal-v3')?3:response.headers['content-type']?.endsWith('terminal-v2')?2:0;
    const timer=setInterval(()=>{if(held.has(number)&&!res.destroyed)res.write(version?Buffer.from([65,65,version,4,0]):': proxy-alive-is-not-source-alive\n\n');},500);
    response.on('data',chunk=>{if(!held.has(number)&&!res.destroyed)res.write(chunk);});
    res.on('close',()=>{clearInterval(timer);streams.delete(number);upstream.destroy();});
   }else response.on('data',chunk=>{if(!drop&&!res.destroyed)res.write(chunk);});
   response.on('end',()=>{if(drop)res.destroy();else res.end();});response.on('error',()=>res.destroy());
  });
  upstream.on('error',()=>{if(!res.headersSent)res.writeHead(502);res.end();});res.on('close',()=>upstream.destroy());req.pipe(upstream);
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
 browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true,isMobile:true});page.setDefaultTimeout(10000);page.on('pageerror',e=>errors.push(e.message));
 await page.goto('http://127.0.0.1:'+server.address().port);await page.locator('.session-row').first().click();
 await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh());
 if(!baseline)assert.equal(await page.evaluate(()=>terminalStream.source.version),3,'Actual Core must negotiate v3 without a silent format fallback');
 const initial=await page.evaluate(()=>({screen:latestFrame.screen,revision:latestFrame.revision,streamID:latestFrame.streamID}));
 await page.waitForTimeout(500);
 await page.evaluate(()=>{window.qaPaints=0;window.qaPulses=0;window.qaScreens=0;window.qaRender=renderTerminal;renderTerminal=(...args)=>{qaPaints++;return qaRender(...args);};terminalStream.source.addEventListener('alive',()=>qaPulses++);terminalStream.source.addEventListener('screen',()=>qaScreens++);});
 const idleReads=counts.reads;
 if(!baseline){
  await page.waitForTimeout(2600);const idle=await page.evaluate(()=>({paints:qaPaints,pulses:qaPulses,screens:qaScreens}));assert.equal(idle.paints,0,JSON.stringify(idle));assert.ok(idle.pulses>0);assert.equal(counts.reads,idleReads);assert.equal(await page.evaluate(()=>terminalFrameFresh()),true);
  checks.push('Fresh compact liveness maintains input freshness without terminal repaints or HTTP fallback');
  await page.evaluate(()=>terminalState('pending','전달 중…'));
  await page.waitForFunction(()=>$('terminal-live').dataset.state==='live');
  assert.equal(await page.evaluate(()=>qaPaints),0);
  checks.push('A fresh idle pulse restores the live connection label after a non-visible pending action without repainting output');
 }
 await page.evaluate(()=>{$('terminal-settings').open=true;});await page.locator('#compose-input').check();await page.locator('#terminal-input').fill('보존할 초안🙂');
 await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});
 await until(()=>streams.size===0,'Background closes network reads');
 if(!baseline){assert.equal(await page.evaluate(()=>terminalWarm?.frame.revision),initial.revision);assert.equal(await page.evaluate(()=>terminalFrameFresh()),false);}
 await suite.control(owner,{append:'\nBACKGROUND-OUTPUT-🙂'});
 readDelay=350;const before=counts.streams,start=performance.now();
 const immediate=await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));return {screen:latestFrame?.screen,fresh:terminalFrameFresh(),disabled:$('send-input').disabled};});
 if(!baseline){assert.equal(immediate.screen,initial.screen);assert.equal(immediate.fresh,false);assert.equal(immediate.disabled,true);}
 await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh()&&latestFrame.screen.includes('BACKGROUND-OUTPUT-🙂'));readDelay=0;
 assert.ok(counts.streams>before);assert.equal(await page.locator('#terminal-input').inputValue(),'보존할 초안🙂');
 if(!baseline){assert.equal(streamQueries.at(-1).revision,initial.revision);assert.equal(streamQueries.at(-1).stream,initial.streamID);}
 metrics.push({case:'Background restore with 350ms delayed reads',ms:Math.round(performance.now()-start)});
 checks.push(baseline?'Legacy phone return obtains a fresh full frame and retains its draft':'Phone return retains its last text and draft, keeps stale input disabled, then resumes from the same original revision');
 // Socket and proxy keep sending bytes, but the source events stop. A source
 // watchdog must reopen this stream independently of successful fallback GETs.
 await page.waitForTimeout(1700);const heldNumber=counts.streams,seen=counts.streams,halfOpenStart=performance.now();held.add(heldNumber);
 await until(()=>counts.streams>seen,'Half-open stream must be replaced',baseline?11000:8500);
 await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh());
 const halfOpenMS=Math.round(performance.now()-halfOpenStart);metrics.push({case:'Half-open stream with misleading proxy comments',ms:halfOpenMS});
 if(!baseline)assert.ok(halfOpenMS<7500);
 checks.push('Source silence replaces a half-open stream even while proxy comments and fallback reads keep arriving');
 if(!baseline){
  const reads=counts.reads,opens=counts.streams;
  await page.evaluate(()=>window.qaOldSource=terminalStream.source);
  await page.evaluate(()=>{const value={streamID:'another-original',revision:latestFrame.revision,sequence:999999,observedAt:new Date().toISOString()};if(qaOldSource.emit)qaOldSource.emit({type:'alive',value});else qaOldSource.dispatchEvent(new MessageEvent('alive',{data:JSON.stringify(value)}));});
  await until(()=>counts.streams>opens&&counts.reads>reads,'An invalid pulse triggers full resync');await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh());
  checks.push('An invalid liveness source cannot refresh controls and triggers a full read of the selected original');
  await page.evaluate(()=>{terminalStream.retries=5;reconnectTerminalStream(terminalStream);});const online=performance.now();
  await page.evaluate(()=>window.dispatchEvent(new Event('online')));await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh());
  assert.ok(performance.now()-online<1800);checks.push('Online notification wakes a long reconnect backoff immediately');
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));terminalWarm.until=performance.now()-1;});
  readDelay=300;const expired=await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));return {frame:latestFrame,warm:terminalWarm,fresh:terminalFrameFresh()};});
  assert.equal(expired.frame,null);assert.equal(expired.warm,null);assert.equal(expired.fresh,false);
  await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh());readDelay=0;assert.equal(streamQueries.at(-1).revision,null);
  checks.push('Expired page-memory state is discarded and starts with a fresh full basis');
  const back=counts.streams;await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});await until(()=>streams.size===0,'Freeze closes the source');
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}));});
  await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh());assert.ok(counts.streams>back);
  checks.push('Back-forward cache pageshow restores the exact original without relying on a visibility event');
 }
 failReads=true;for(const res of streams.values())res.destroy();await page.waitForFunction(()=>terminalStream?.pollFailures>0);
 assert.equal(await page.locator('#terminal-input').inputValue(),'보존할 초안🙂');
 await page.screenshot({path:path.join(out,engine+'-recovering.png')});failReads=false;
 await page.evaluate(()=>window.dispatchEvent(new Event('online')));await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh());
 await page.locator('#terminal-input').fill('EXPLICIT-ONCE-🙂');await page.locator('#send-input').click();await page.waitForFunction(()=>latestFrame.screen.includes('EXPLICIT-ONCE-🙂')&&!inputInFlight);
 assert.equal(counts.inputs,1);assert.equal((await suite.observe(owner)).inputs.length,1);
 await page.locator('#terminal-input').fill('UNCERTAIN-ONCE-🙂');loseInput=true;await page.locator('#send-input').click();
 await page.waitForFunction(()=>!inputInFlight&&latestFrame.screen.includes('UNCERTAIN-ONCE-🙂'));
 await page.evaluate(()=>{window.dispatchEvent(new Event('offline'));window.dispatchEvent(new Event('online'));});await page.waitForFunction(()=>terminalStream?.sseReady&&terminalFrameFresh());await page.waitForTimeout(600);
 assert.equal(counts.inputs,2);assert.equal((await suite.observe(owner)).inputs.length,2);assert.equal(await page.locator('#terminal-input').inputValue(),'UNCERTAIN-ONCE-🙂');
 if(!baseline)assert.ok(await page.evaluate(()=>inputFailure.includes('입력 전달 결과를 확인하지 못했습니다')));
 checks.push('Explicit input reaches the original once; a delivered input with a lost response remains uncertain and is not replayed');
 await page.locator('#feedback').waitFor({state:'hidden',timeout:16000});
 for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.setViewportSize({width,height});if(width>=760)await page.evaluate(()=>terminalFocus(true));await page.screenshot({path:path.join(out,engine+'-'+name+'.png')});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
 }
 assert.equal(counts.ptys,0);assert.deepEqual(errors,[]);
 const report={baseline,engine,checks,metrics,counts,errors,scope:'Actual Core, real browser and loopback failures, emulated viewports; no physical phone or user terminal'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{
 await browser?.close();for(const res of streams.values())res.destroy();server?.closeAllConnections();if(server)await new Promise(resolve=>server.close(resolve));await suite.stop();
}
