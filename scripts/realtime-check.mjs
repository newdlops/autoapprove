// Real Core owner/gateway and browser; synthetic originals and controls only.
import assert from 'node:assert/strict';
import {createServer,request} from 'node:http';
import {readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import {fixtureSuite,json,wait,until} from './terminal-continuity-fixture.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const baseline=process.argv.includes('--baseline'),out=path.resolve(option('output')||'.runtime/realtime-check'),build=path.resolve(option('build')||'.build/release');
const suite=await fixtureSuite(out,build),checks=[],latency=[],counts={requests:0,bytes:0,wireBytes:0},sockets=new Set();let server,browser;
try{
 const owner=await suite.start('owner'),gateway=await suite.start('gateway');
 assert.equal((await json(gateway.url+'/api/peers',{address:owner.url})).status,200);
 server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://fixture');if(url.pathname==='/app.js'){
   res.writeHead(200,{'Content-Type':'text/javascript'});res.end(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/app.js'));return;
  }
  if(url.pathname==='/api/network'){counts.requests++;counts.wireBytes+=Buffer.byteLength(req.method+' '+req.url+' HTTP/1.1\r\n'+req.rawHeaders.map((v,i)=>i%2?v+'\r\n':v+': ').join('')+'\r\n');}
  const upstream=request(gateway.url+req.url,{method:req.method,headers:{...req.headers,host:new URL(gateway.url).host,...(req.headers.origin?{origin:gateway.url}:{})}},response=>{
   if(url.pathname==='/api/network')counts.wireBytes+=Buffer.byteLength('HTTP/'+response.httpVersion+' '+response.statusCode+' '+response.statusMessage+'\r\n'+response.rawHeaders.map((v,i)=>i%2?v+'\r\n':v+': ').join('')+'\r\n');
   res.writeHead(response.statusCode,response.headers);response.on('data',chunk=>{if(url.pathname==='/api/network'){counts.bytes+=chunk.length;counts.wireBytes+=chunk.length;}res.write(chunk);});response.on('end',()=>res.end());response.on('error',()=>res.destroy());
  });upstream.on('error',()=>res.destroy());res.on('close',()=>upstream.destroy());req.pipe(upstream);
 });server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright'),engine=process.argv.includes('--webkit')?'webkit':'chromium';
 browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const page=await browser.newPage({viewport:{width:390,height:844}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto('http://127.0.0.1:'+server.address().port);await page.waitForFunction(id=>typeof nodes!=='undefined'&&nodes.find(n=>n.id===id)?.online,owner.id);
 for(const node of [gateway,owner])for(const paused of [true,false,true]){
  await wait(350);const start=performance.now();await suite.control(node,{paused});
  await page.waitForFunction(({id,paused})=>nodes.find(n=>n.id===id)?.state?.snapshot.paused===paused,{id:node.id,paused},{timeout:10000});
  const ms=performance.now()-start;latency.push({route:node===gateway?'local':'peer',ms:Math.round(ms)});if(!baseline)assert.ok(ms<700,'Changed inventory must arrive without a polling interval');
 }
 checks.push('Local and relayed inventory changes reach the rendered list');
 await wait(1000);const idleBefore={...counts},readsBefore=(await suite.observe(owner)).reads;await wait(16500);const idle={requests:counts.requests-idleBefore.requests,bodyBytes:counts.bytes-idleBefore.bytes,httpBytes:counts.wireBytes-idleBefore.wireBytes,sourceReads:(await suite.observe(owner)).reads-readsBefore,seconds:16.5};
 if(!baseline){assert.ok(idle.requests<=3);assert.equal(idle.bodyBytes,0);assert.equal(await page.locator('#refresh').isEnabled(),true);}
 checks.push(baseline?'Legacy idle list uses periodic conditional requests':'Idle list uses held conditional reads with empty-body confirmation');
 if(!baseline){const before=await page.evaluate(()=>lastNetworkStartedAt),at=performance.now();await page.getByRole('button',{name:'상태 새로고침'}).click();await page.waitForFunction(before=>connected&&lastNetworkStartedAt>before,before);assert.ok(performance.now()-at<1500);checks.push('Manual refresh supersedes a held read and completes a fresh response');}
 // A real original source event arriving inside the live cache lifetime must
 // invalidate that cached observation rather than postpone the changed frame.
 const state=(await json(owner.url+'/api/state')).value,session=state.sessions[0].session.id,controller=new AbortController();
 const response=await fetch(owner.url+'/api/terminal/stream?'+new URLSearchParams({session,wire:'3',delta:'1',compact:'1'}),{signal:controller.signal});assert.equal(response.status,200);
 const window={},context=vm.createContext({window,TextDecoder,TextEncoder,Uint8Array,DataView,BigInt,Number,Map,Set,URL,atob,btoa});vm.runInContext(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/terminal-wire.js','utf8'),context);
 const parser=new window.AutoApproveTerminalWire.Parser(false,3),events=[],reader=response.body.getReader();let stopped=false;
 const pump=(async()=>{try{while(!stopped){const {value,done}=await reader.read();if(done)return;parser.push(value,e=>events.push(e));}}catch(e){if(!stopped)throw e;}})();
 await until(()=>events.some(e=>e.type==='screen'),'Initial terminal frame');const terminal=[],terminalReadsBefore=(await suite.observe(owner)).reads;
 for(let n=0;n<6;n++){
  const mark='REALTIME-'+n,start=performance.now(),from=events.length;await suite.control(owner,{append:'\n'+mark,notify:true});
  await until(()=>events.slice(from).some(e=>e.type==='screen'&&(e.value.screen||e.value.screenPatch?.text||'').includes(mark)),'Changed terminal output',5000);
  const ms=performance.now()-start;terminal.push(Math.round(ms));if(!baseline)assert.ok(ms<350,'A fresh source event cannot reuse the previous screen');await wait(20);
 }
 stopped=true;controller.abort();await reader.cancel().catch(()=>{});await pump;
 checks.push('Fresh source notifications deliver changed native screens');
 const terminalSourceReads=(await suite.observe(owner)).reads-terminalReadsBefore;
 if(!baseline){
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});const count=counts.requests;await wait(1500);assert.equal(counts.requests,count);
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));});await page.waitForFunction(()=>connected);checks.push('Background cancels the wait; foreground resumes normally');
 }
 for(const[name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.screenshot({path:path.join(out,engine+'-'+name+'.png')});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);}
 assert.equal((await suite.observe(owner)).inputs.length,0);assert.deepEqual(errors,[]);
 const report={passed:true,baseline,engine,latency,terminalMS:terminal,terminalSourceReads,idle,checks,errors,inputPosts:0,scope:'Real browser and Core on synthetic sources; HTTP header/body bytes exclude TCP overhead; no physical-device latency or user input'};await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{await browser?.close();for(const s of sockets)s.destroy();server?.closeAllConnections();if(server)await new Promise(resolve=>server.close(resolve));await suite.stop();}
