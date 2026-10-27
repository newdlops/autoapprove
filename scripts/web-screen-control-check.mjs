// Real browsers -> actual PIN gateway/HTTP/WebSocket -> production Quartz event
// construction. The native event sink and captured targets are synthetic only.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import https from 'node:https';
import http from 'node:http';
import net from 'node:net';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),engine=process.argv.includes('--webkit')?'webkit':'chromium';
const out=path.resolve(option('output')||'.runtime/screen-control-193/browser-'+engine);await mkdir(out,{recursive:true,mode:0o700});
const root=await mkdtemp('/private/tmp/aa-screen-control-'),sockets=new Set(),inputReplies=new Set(),errors=[],checks=[],packetKinds=[],captures=[];
let child,browser,proxy,origin,page;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,ms=12000){const end=Date.now()+ms;let last;while(Date.now()<end){try{const value=await test();if(value)return value;}catch(error){last=error;}await delay(40);}throw Error(label+': '+(last?.message||'timed out'));}
async function events(){try{return (await readFile(root+'/screen-events.ndjson','utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);}catch{return [];}}
const flag=async(name,on)=>on?writeFile(root+'/'+name,'synthetic fault'):rm(root+'/'+name,{force:true});
async function text(){try{return await readFile(root+'/typed.txt','utf8');}catch{return '';}}
try{
 const cache=path.resolve('.build/cache/ScreenControlPreview');await mkdir(cache,{recursive:true});const binary=root+'/ScreenControlPreview';
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/ScreenControlFixture.swift','Tests/fixtures/screen-control-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
 child=spawn(binary,[root],{stdio:['ignore','ignore','pipe']});let stderr='';child.stderr.on('data',d=>stderr+=d);
 const ready=await until(async()=>{assert.equal(child.exitCode,null,stderr);try{return JSON.parse(await readFile(root+'/ready.json','utf8'));}catch{return null;}},'Native fixture startup',25000);
 await writeFile(root+'/tls.cnf','[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=screen-control.tunnel-qa.invalid\n[v3]\nsubjectAltName=IP:127.0.0.1\n');
 execFileSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',root+'/tls.cnf','-keyout',root+'/key.pem','-out',root+'/cert.pem'],{stdio:'ignore'});
 const upstreamURL=new URL(ready.gateway);
 const headersFor=headers=>{const result={...headers,host:'screen-control.tunnel-qa.invalid'};if(result.origin===origin)result.origin='https://screen-control.tunnel-qa.invalid';return result;};
 proxy=https.createServer({key:await readFile(root+'/key.pem'),cert:await readFile(root+'/cert.pem')},(req,res)=>{
  const upstream=http.request(new URL(req.url,ready.gateway),{method:req.method,headers:headersFor(req.headers)},reply=>{res.writeHead(reply.statusCode,reply.headers);reply.pipe(res);});
  upstream.on('error',()=>{if(!res.headersSent)res.writeHead(502);res.end();});req.pipe(upstream);
 });
 proxy.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
 proxy.on('upgrade',(req,socket,head)=>{
  const upstream=net.connect(Number(upstreamURL.port),upstreamURL.hostname);sockets.add(upstream);upstream.once('close',()=>sockets.delete(upstream));
  inputReplies.add(upstream);upstream.once('close',()=>inputReplies.delete(upstream));
  upstream.once('connect',()=>{const headers=headersFor(req.headers);upstream.write(`${req.method} ${req.url} HTTP/1.1\r\n`+Object.entries(headers).map(([k,v])=>`${k}: ${v}`).join('\r\n')+'\r\n\r\n');if(head.length)upstream.write(head);socket.pipe(upstream);upstream.pipe(socket);});
  upstream.on('error',()=>socket.destroy());socket.on('error',()=>upstream.destroy());socket.on('close',()=>upstream.destroy());
 });
 await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));origin='https://'+proxy.address().address+':'+proxy.address().port;
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const context=await browser.newContext({ignoreHTTPSErrors:true,viewport:{width:1440,height:900}});page=await context.newPage();page.setDefaultTimeout(12000);
 page.on('pageerror',error=>errors.push(error.message));page.on('websocket',socket=>socket.on('framesent',event=>{const bytes=Buffer.from(event.payload);if(bytes.length>=8&&bytes[0]===65&&bytes[1]===73&&bytes[2]===1)packetKinds.push(bytes[3]);}));
 async function capture(name){assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/'+name+'.png',animations:'disabled'});captures.push(name);}
 async function imageBox(){return page.locator('#test-screen-image').evaluate(image=>{const r=image.getBoundingClientRect(),s=Math.min(r.width/image.naturalWidth,r.height/image.naturalHeight),w=image.naturalWidth*s,h=image.naturalHeight*s;return {x:r.x+(r.width-w)/2,y:r.y+(r.height-h)/2,width:w,height:h};});}
 async function point(x=.5,y=.5){const b=await imageBox();return {x:b.x+b.width*x,y:b.y+b.height*y};}
 async function openControl(){if(await page.locator('#toggle-screen-control').getAttribute('aria-pressed')!=='true'){await page.locator('#toggle-screen-control').click();await page.waitForFunction(()=>screenControl?.active&&!screenControlBusy);}}
 assert.equal((await context.request.post(origin+'/api/screen/control',{headers:{Origin:origin},data:{action:'begin',shareID:ready.display}})).status(),401);
 await page.goto(origin);await page.locator('#tunnel-key').fill('001234');await page.locator('#tunnel-login-submit').click();
 await page.locator('#global-screens').click();await page.waitForFunction(()=>document.getElementById('test-screen-image').naturalWidth===960);
 const foreign=await context.request.post(origin+'/api/screen/control',{headers:{Origin:'https://foreign.invalid'},data:{action:'begin',shareID:ready.display}});assert.equal(foreign.status(),403);
 const noLease=await context.request.post(origin+'/api/screen/input',{headers:{Origin:origin},data:{shareID:ready.display,controlID:'00000000-0000-4000-8000-000000000193',token:'not-a-capability',sequence:1,payload:'Bg=='}});assert.equal(noLease.status(),410);
 await page.locator('#test-screen-zoom').click();assert.equal(await page.locator('#test-screen-image').getAttribute('data-zoom'),'true');await page.locator('#test-screen-zoom').click();
 await page.keyboard.press('ArrowUp');await page.keyboard.type('view only');assert.equal((await events()).length,0);
 if(await page.locator('#test-screen-image').getAttribute('data-zoom')==='true')await page.locator('#test-screen-zoom').click();
 checks.push('Actual PIN and same-origin boundaries; view-only zoom and keyboard actions produce zero native events');
 await page.waitForFunction(()=>!!window.AutoApproveInputChannel);await openControl();
 assert.equal(await page.locator('#screen-control-panel').isVisible(),true);assert.equal(await page.locator('#test-screen-image').getAttribute('data-zoom'),'false');
 const second=await context.request.post(origin+'/api/screen/control',{headers:{Origin:origin},data:{action:'begin',shareID:ready.window}});assert.equal(second.status(),409);
 let p=await point();await page.mouse.click(p.x,p.y);
 const clicked=await until(async()=>{const list=await events();return list.find(e=>e.type===1);},'Native click');assert.ok(Math.abs(clicked.x+960)<1);assert.ok(Math.abs(clicked.y-340)<1);
 await page.locator('#screen-control-keyboard').fill('한글🙂e\u0301');await until(async()=>(await text())==='한글🙂e\u0301','Unicode into Quartz event sink');
 await page.locator('#screen-control-keyboard').focus();await page.keyboard.type('abc');await until(async()=>(await text())==='한글🙂e\u0301abc','Consecutive keyboard input');
 for(const [value,after]of [['조합',true],['한번',false]]){
  const before=await text();
  await page.locator('#screen-control-keyboard').evaluate((field,{value,after})=>{
   field.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));field.value=value;
   field.dispatchEvent(new InputEvent('input',{bubbles:true,data:value,inputType:'insertCompositionText',isComposing:after}));
   field.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:value}));
   if(after)field.dispatchEvent(new InputEvent('input',{bubbles:true,data:value,inputType:'insertText',isComposing:false}));
  },{value,after});
  await until(async()=>(await text())===before+value,'IME composition commits once');
  await page.waitForFunction(()=>!screenControlDrafts.has(screenDraftKey()));
 }
 await page.getByRole('button',{name:'Mac에서 전체 선택',exact:true}).click();await until(async()=>(await events()).some(e=>e.type===10&&e.keyCode===0&&(e.flags&0x100000)!==0),'Command shortcut');
 assert.ok(packetKinds.includes(8),'Screen input must traverse the actual binary WebSocket path');
 await page.locator('#screen-control-quality').waitFor({state:'visible'});
 checks.push('The new binary screen kind crosses actual WebSocket/PIN gateway, preserves negative-origin Retina coordinates, exact Unicode and shortcuts; only one controller owns a Mac');
 checks.push('Both browser composition event orders commit Korean once and remove accepted text from the page draft buffer');
 const dragStart=(await events()).length,a=await point(.3,.3),b=await point(.65,.6);
 await page.mouse.move(a.x,a.y);await page.mouse.down();await page.mouse.move(b.x,b.y,{steps:5});await page.mouse.up();
 await until(async()=>{const list=(await events()).slice(dragStart);return list.some(e=>e.type===6)&&list.some(e=>e.type===2);},'Native drag and release');
 await page.mouse.click(b.x,b.y,{button:'right'});await page.mouse.wheel(25,120);
 await until(async()=>(await events()).slice(dragStart).some(e=>e.type===22&&e.deltaX===-25&&e.deltaY===-120),'Native two-axis wheel');
 await page.mouse.dblclick(b.x,b.y);await until(async()=>(await events()).slice(dragStart).some(e=>e.type===1&&e.clickCount===2),'Native double click');
 checks.push('Normal browser drag, right-click, two-axis wheel, double-click and matching button-up reach production Quartz construction');
 for(const [label,width,height]of [['desktop',1440,900],['tablet',768,1024],['mobile',390,844]]){await page.setViewportSize({width,height});await capture('control-'+label);}
 await page.emulateMedia({colorScheme:'dark'});await capture('control-dark-mobile');await page.emulateMedia({colorScheme:'light'});
 await page.locator('#screen-control-keyboard').focus();await page.keyboard.press('Escape');await page.waitForFunction(()=>!screenControl?.active);
 assert.equal(await page.locator('#test-screen-dialog').isVisible(),true);assert.equal(await page.locator('#toggle-screen-control').getAttribute('aria-pressed'),'false');
 await flag('control-denied',true);await page.locator('#toggle-screen-control').click();await page.locator('#screen-control-error').waitFor({state:'visible'});assert.match(await page.locator('#screen-control-error').textContent(),/손쉬운 사용/);await capture('permission-mobile');await flag('control-denied',false);
 await openControl();
 p=await point(.5,.5);await page.mouse.move(p.x,p.y);const downCount=(await events()).filter(e=>e.type===1).length;await page.mouse.down();
 await until(async()=>(await events()).filter(e=>e.type===1).length>downCount,'Held mouse accepted');
 const beforeClose=(await events()).length;await page.evaluate(()=>screenControl.channel.socket.close());
 await until(async()=>(await events()).slice(beforeClose).some(e=>e.type===2),'Disconnect releases held mouse',8000);await page.mouse.up();
 await page.waitForFunction(()=>!screenControl?.active);const afterClose=(await events()).length;await delay(500);assert.equal((await events()).length,afterClose);
 checks.push('Escape exits control without trapping the dialog, permission errors stay view-only, and WebSocket loss releases held input without replay');
 await openControl();p=await point();await page.mouse.move(p.x,p.y);await page.mouse.down();
 await page.waitForFunction(()=>screenControl.channel.pendingCount===0&&screenControl.pressed.size===1);
 const silentBefore=(await events()).length,silentStart=Date.now();for(const socket of inputReplies)socket.pause();
 await page.waitForFunction(()=>!screenControl?.active);await page.mouse.up();
 await until(async()=>(await events()).slice(silentBefore).some(event=>event.type===2),'A silent input socket releases the held pointer',7000);
 assert.ok(Date.now()-silentStart<6500);assert.match(await page.locator('#screen-control-error').textContent(),/입력 연결|전달 결과/);
 checks.push('A silent actual WebSocket is detected by its pong deadline while HTTP frames remain fresh and releases a held native button without replay');
 await openControl();const sourceEvents=(await events()).length;await flag('source-changed',true);p=await point(.6,.4);await page.mouse.move(p.x,p.y);
 await page.waitForFunction(()=>!screenControl?.active);assert.equal((await events()).slice(sourceEvents).filter(e=>e.type===5).length,0);await flag('source-changed',false);
 checks.push('A changed native target identity rejects the next input before dispatch');
 await openControl();await page.locator('#close-test-screen').click();await until(async()=>{const reply=await context.request.post(origin+'/api/screen/control',{headers:{Origin:origin},data:{action:'begin',shareID:ready.display}});if(reply.status()!==200)return false;const grant=await reply.json();await context.request.post(origin+'/api/screen/control',{headers:{Origin:origin},data:{...grant,action:'end'}});return true;},'Closed viewer revokes its control lease');
 await page.locator('#global-screens').click();await page.waitForFunction(()=>document.getElementById('test-screen-image').complete&&document.getElementById('test-screen-image').naturalWidth===960);
 await openControl();await flag('capture-denied',true);await page.locator('#test-screen-error').waitFor({state:'visible'});
 await page.waitForFunction(()=>!screenControl?.active&&!document.getElementById('test-screen-image').hasAttribute('src'));
 await flag('capture-denied',false);await page.locator('#retry-test-screen').click();await page.waitForFunction(()=>document.getElementById('test-screen-image').naturalWidth===960);
 await openControl();await page.locator('#close-test-screen').click();
 checks.push('A valid frame validator cannot bypass revoked capture permission; explicit retry restores the image and permits a fresh control lease');
 await page.route('**/api/test-screen**',async route=>{const headers={...route.request().headers()};delete headers['if-none-match'];const response=await route.fetch({headers}),replyHeaders={...response.headers()};delete replyHeaders.etag;delete replyHeaders['content-encoding'];delete replyHeaders['content-length'];await route.fulfill({response,headers:replyHeaders,body:await response.body()});});
 await page.locator('#global-screens').click();await page.waitForFunction(()=>document.getElementById('test-screen-image').naturalWidth===960&&sharedScreen.validation?.etag==='');
 await openControl();await page.locator('#screen-control-keyboard').fill('이전 호스트 호환');await until(async()=>(await text()).endsWith('이전 호스트 호환'),'Host without conditional frame support');
 await page.locator('#close-test-screen').click();await page.unroute('**/api/test-screen**');
 checks.push('A host without frame validators keeps the sequential full-image and exact keyboard input behavior');
 await page.locator('#global-screens').click();await page.waitForFunction(()=>document.getElementById('test-screen-image').complete&&document.getElementById('test-screen-image').naturalWidth===960);
 await page.route('**/api/input/socket**',route=>route.abort());await page.evaluate(()=>{window.AutoApproveInputChannel=undefined;});
 const httpStart=(await events()).length;await openControl();assert.equal(await page.evaluate(()=>screenControl.channel==null),true);
 await page.locator('#screen-control-keyboard').fill('HTTP에서도 한 번');await until(async()=>(await text()).endsWith('HTTP에서도 한 번'),'Pre-send HTTP fallback');
 assert.equal((await events()).slice(httpStart).filter(e=>e.type===10&&e.text).map(e=>e.text).join(''),'HTTP에서도 한 번');
 await page.locator('#toggle-screen-control').click();
 checks.push('A route without WebSocket selects ordered HTTP before the first input and never duplicates the committed text');
 await page.unroute('**/api/input/socket**');
 const touchContext=await browser.newContext({ignoreHTTPSErrors:true,viewport:{width:390,height:844},hasTouch:true,isMobile:true});
 page=await touchContext.newPage();page.setDefaultTimeout(12000);page.on('pageerror',error=>errors.push(error.message));
 await page.goto(origin);await page.locator('#tunnel-key').fill('001234');await page.locator('#tunnel-login-submit').click();
 await page.locator('#global-screens').click();await page.waitForFunction(()=>document.getElementById('test-screen-image').naturalWidth===960);
 await page.waitForFunction(()=>!!window.AutoApproveInputChannel);await openControl();
 let start=(await events()).length;p=await point();await page.touchscreen.tap(p.x,p.y);
 await until(async()=>(await events()).slice(start).some(event=>event.type===2),'Touchscreen tap');
 assert.equal(await page.locator('#screen-control-keyboard').evaluate(field=>document.activeElement===field),false,'Tapping the image does not force the software keyboard');
 await page.locator('#screen-touch-secondary').tap();start=(await events()).length;p=await point(.6,.5);await page.touchscreen.tap(p.x,p.y);
 await until(async()=>(await events()).slice(start).some(event=>event.type===3),'Touchscreen secondary tap');
 await page.locator('#screen-touch-secondary').tap();
 async function touch(type,id,x,y){await page.locator('#test-screen-zoom').evaluate((surface,{type,id,x,y})=>surface.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerType:'touch',pointerId:id,button:0,buttons:type==='pointerup'?0:1,clientX:x,clientY:y})),{type,id,x,y});}
 start=(await events()).length;const t1=await point(.3,.35),t2=await point(.65,.65);
 await touch('pointerdown',101,t1.x,t1.y);await touch('pointermove',101,t2.x,t2.y);await delay(40);await touch('pointerup',101,t2.x,t2.y);
 await until(async()=>{const list=(await events()).slice(start);return list.some(event=>event.type===6)&&list.some(event=>event.type===2);},'Synthetic touch-pointer drag');
 start=(await events()).length;
 await touch('pointerdown',102,t1.x,t1.y);await touch('pointerdown',103,t2.x,t2.y);
 await touch('pointermove',102,t1.x,t1.y-25);await touch('pointermove',103,t2.x,t2.y-25);
 await touch('pointerup',102,t1.x,t1.y-25);await touch('pointerup',103,t2.x,t2.y-25);
 await until(async()=>(await events()).slice(start).some(event=>event.type===22&&event.deltaY!==0),'Synthetic two-finger scroll');
 await capture('touch-mobile');
 checks.push('Touch-capable mobile contexts accept actual touchscreen tap/right-tap without opening the keyboard; synthetic multi-pointer events verify drag and two-finger scroll');
 await page.locator('#stop-test-screen').tap();await page.waitForFunction(()=>sharedScreen===null);
 assert.equal(await page.locator('#toggle-screen-control').isVisible(),false);assert.equal(await page.locator('#test-screen-zoom').isDisabled(),true);
 checks.push('Ending the share revokes input and removes the control action and stale image interaction');
 const report={passed:true,engine,checks,errors,viewports:[[390,844],[768,1024],[1440,900]],binaryScreenPackets:packetKinds.filter(k=>k===8).length,nativeEvents:(await events()).length,screenshots:captures,userDesktopPosts:0,scope:'Real browser, actual PIN gateway and Core HTTP/WebSocket, real Quartz event objects inspected in a synthetic sink; no user desktop, process, account, or OS permission changed'};
 assert.deepEqual(errors,[]);await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}catch(error){
 const ui=await page?.evaluate(()=>({control:screenControl?.state,busy:screenControlBusy,error:document.getElementById('screen-control-error')?.textContent,status:document.getElementById('screen-control-status')?.textContent})).catch(()=>null);
 await page?.screenshot({path:out+'/failure.png',animations:'disabled'}).catch(()=>{});
 await writeFile(out+'/failure.json',JSON.stringify({error:error.message,checks,errors,ui,packetKinds,nativeEvents:(await events()).length},null,2));throw error;
}
finally{
 await writeFile(root+'/stop','stop').catch(()=>{});await browser?.close();for(const socket of sockets)socket.destroy();if(proxy)await new Promise(resolve=>proxy.close(resolve));
 if(child){await Promise.race([new Promise(resolve=>child.once('exit',resolve)),delay(1000)]);if(child.exitCode===null)child.kill('SIGTERM');}
 await rm(root,{recursive:true,force:true});
}
