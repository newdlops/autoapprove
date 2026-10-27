// Real browser, production Core and synthetic frames. Adds latency only to
// screen GETs; no desktop capture, posted OS input or user terminal access.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/transport-stability-194/frames');
const latency=Number(option('latency')||120),seconds=Number(option('seconds')||4),engine=process.argv.includes('--webkit')?'webkit':'chromium';
assert.ok(latency>=0&&latency<=1000&&seconds>=2&&seconds<=15);await mkdir(out,{recursive:true,mode:0o700});
const root=await mkdtemp('/private/tmp/aa-frame-rate-'),sockets=new Set(),errors=[],wireRows=[];let fixture,browser,server,origin,phase,rows=[];
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,label){const end=Date.now()+20000;while(!await check()){assert.ok(Date.now()<end,label);await delay(20);}}
const median=values=>values.toSorted((a,b)=>a-b)[Math.floor(values.length/2)];
try{
 const cache=path.resolve('.build/cache/ScreenTransportPreview');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/ScreenControlFixture.swift','Tests/fixtures/screen-control-preview.swift','-o',root+'/Preview'],{stdio:'inherit',timeout:180000});
 fixture=spawn(root+'/Preview',[root],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',part=>stderr+=part);
 let ready;await until(async()=>{assert.equal(fixture.exitCode,null,stderr);try{ready=JSON.parse(await readFile(root+'/ready.json','utf8'));return true;}catch{return false;}},'Synthetic fixture startup');
 const upstreamURL=new URL(ready.base),headersFor=headers=>{const result={...headers,host:upstreamURL.host};if(result.origin===origin)result.origin=upstreamURL.origin;return result;};
 server=http.createServer(async(req,res)=>{
  const frame=req.url.startsWith('/api/test-screen'),wire=frame&&phase?{at:Date.now(),phase}:null;
  if(wire)wireRows.push(wire);if(frame)await delay(latency/2);
  const upstream=http.request(new URL(req.url,ready.base),{method:req.method,headers:headersFor(req.headers)},async reply=>{
   if(wire){wire.status=reply.statusCode;wire.bytes=Number(reply.headers['content-length']||0);wire.encoding=reply.headers['content-encoding']||'identity';}
   if(frame)await delay(latency/2);res.writeHead(reply.statusCode,reply.headers);reply.pipe(res);
  });upstream.on('error',()=>{if(!res.headersSent)res.writeHead(502);res.end();});req.pipe(upstream);
 });
 server.on('connection',socket=>{sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});
 server.on('upgrade',(req,socket,head)=>{
  const upstream=net.connect(Number(upstreamURL.port),upstreamURL.hostname);sockets.add(upstream);upstream.on('close',()=>sockets.delete(upstream));
  upstream.once('connect',()=>{upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n`+Object.entries(headersFor(req.headers)).map(([key,value])=>`${key}: ${value}`).join('\r\n')+'\r\n\r\n');if(head.length)upstream.write(head);socket.pipe(upstream);upstream.pipe(socket);});
  upstream.on('error',()=>socket.destroy());socket.on('error',()=>upstream.destroy());socket.on('close',()=>upstream.destroy());
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));origin='http://127.0.0.1:'+server.address().port;
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await playwright[engine].launch({headless:true,...(engine==='chromium'?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined}:{})});
 const page=await browser.newPage({viewport:{width:1440,height:900}});page.on('pageerror',error=>errors.push(error.message));
 page.on('request',request=>{if(phase&&new URL(request.url()).pathname==='/api/test-screen')rows.push({phase,request,at:Date.now()});});
 page.on('response',response=>{const row=rows.find(value=>value.request===response.request());if(row){row.status=response.status();row.bytes=Number(response.headers()['content-length']||0);row.encoding=response.headers()['content-encoding']||'identity';}});
 await page.goto(origin);await page.locator('#global-screens').click();await page.waitForFunction(()=>document.getElementById('test-screen-image').naturalWidth===960);
 await page.waitForFunction(()=>!!window.AutoApproveInputChannel);await page.locator('#toggle-screen-control').click();await page.waitForFunction(()=>screenControl?.active&&!screenControlBusy);
 await delay(Math.max(750,latency*3+300)); // Let the control toolbar settle before measuring a static image.
 if(process.argv.includes('--wheel-burst')){
  const baseline=process.argv.includes('--baseline');
  const native=async()=>{try{return (await readFile(root+'/screen-events.ndjson','utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);}catch{return [];}};
  const scroll=async delta=>page.locator('#test-screen-image').evaluate(async(image,delta)=>{
   const r=image.getBoundingClientRect(),x=r.x+r.width/2,y=r.y+r.height/2;
   for(let index=0;index<1000;){for(let count=0;count<16&&index<1000;count++,index++)image.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,clientX:x,clientY:y,deltaX:0,deltaY:delta}));await new Promise(requestAnimationFrame);}
  },delta);
  await scroll(0.2);await page.waitForFunction(()=>!screenControl?.active||!screenControl.queue.length&&!screenControl.channel?.pendingCount&&!screenControl.moveTimer);
  const fractional=(await native()).filter(event=>event.type===22),fractionalPixels=0-fractional.reduce((sum,event)=>sum+event.deltaY,0);
  const before=(await native()).length;await scroll(1);await page.waitForFunction(()=>!screenControl?.active||!screenControl.queue.length&&!screenControl.channel?.pendingCount&&!screenControl.moveTimer);
  const integer=(await native()).slice(before).filter(event=>event.type===22),integerPixels=0-integer.reduce((sum,event)=>sum+event.deltaY,0),active=await page.evaluate(()=>screenControl?.active===true),error=await page.locator('#screen-control-error').textContent();
  if(baseline){assert.equal(fractionalPixels,0);assert.equal(active,false);assert.match(error,/너무 빠르게/);}
  else{assert.equal(fractionalPixels,200);assert.equal(integerPixels,1000);assert.equal(active,true);assert.ok(fractional.length<160&&integer.length<160);}
  assert.deepEqual(errors,[]);
  const report={passed:true,engine,mode:baseline?'baseline-regression-reproduction':'candidate',eventsPerPhase:1000,fractionalPixels,fractionalPackets:fractional.length,integerPixels,integerPackets:integer.length,controlActive:active,error:baseline?error:null,userDesktopPosts:0,scope:'Real browser DOM WheelEvents, actual HTTP/WebSocket/Core and synthetic Quartz sink; no physical trackpad, desktop input or public-route claim'};
  await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));await page.locator('#close-test-screen').click();
 }else{
 await page.evaluate(()=>{window.frameChanges=0;window.frameObserver=new MutationObserver(records=>window.frameChanges+=records.length);frameObserver.observe(document.getElementById('test-screen-image'),{attributes:true,attributeFilter:['src']});});
 phase='static';await delay(seconds*1000);phase=null;
 assert.equal(await page.evaluate(()=>screenControl?.active),true,'Static conditional frames must keep the native control lease fresh');
 const srcChanges=await page.evaluate(()=>{frameObserver.disconnect();return frameChanges;});
 const complete=wireRows.filter(value=>value.status),intervals=complete.slice(1).map((row,index)=>row.at-complete[index].at);
 assert.ok(complete.length>=5);assert.deepEqual(errors,[]);
 const metrics={requests:complete.length,notModified:complete.filter(row=>row.status===304).length,bodyBytes:complete.reduce((sum,row)=>sum+row.bytes,0),medianRequestIntervalMS:median(intervals),imageAssignments:srcChanges,encodings:[...new Set(complete.map(row=>row.encoding))]};
 await writeFile(out+'/observation.json',JSON.stringify({metrics,browserStatuses:rows.map(row=>row.status),lastFrame:await page.evaluate(()=>({notModified:sharedScreen.validation?.notModified,hasValidator:!!sharedScreen.validation?.etag})),syntheticEvents:(await readFile(root+'/screen-events.ndjson','utf8').catch(()=>'')).trim().split('\n').filter(Boolean).length},null,2));
 if(process.argv.includes('--expect-conditional')){assert.ok(metrics.notModified>=complete.length-1);assert.ok(srcChanges<=1,'Unchanged images must not be decoded again');assert.ok(metrics.medianRequestIntervalMS<Math.max(190,latency+70));}
 const report={passed:true,engine,simulatedFrameRTTMS:latency,seconds,metrics,errors,scope:'Real local browser/Core, static synthetic JPEG and screen control, controlled response delay; wire body bytes include actual HTTP gzip. No public-route performance or OS event delivery claim.'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
 await page.locator('#close-test-screen').click();
 }
}finally{
 await browser?.close();for(const socket of sockets)socket.destroy();if(server)await new Promise(resolve=>server.close(resolve));
 await writeFile(root+'/stop','stop').catch(()=>{});if(fixture){await Promise.race([new Promise(resolve=>fixture.once('exit',resolve)),delay(1000)]);if(fixture.exitCode===null)fixture.kill('SIGTERM');}
 await rm(root,{recursive:true,force:true});
}
