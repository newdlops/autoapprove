// Real browsers, exact Swift-generated vectors and controlled HTTP failures.
// All identities/output are synthetic. No user CLI or input request is used.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('vectors'),'Pass --vectors=emit.stdout from terminal-wire-check.mjs --v3');
const rows=(await readFile(option('vectors'),'utf8')).trim().split('\n').map(JSON.parse);assert.equal(rows.shift().version,3);
const engine=process.argv.includes('--webkit')?'webkit':'chromium';
const out=path.resolve(option('output')||'.runtime/terminal-wire-browser/'+engine);await mkdir(out,{recursive:true});
const full=rows.find(r=>r.case==='original-styled'&&r.index===0),frame=JSON.parse(Buffer.from(full.json,'base64'));
const ptyRows=rows.filter(r=>r.case==='pty-small'),outputs=ptyRows.map(r=>JSON.parse(Buffer.from(r.json,'base64')));
const descriptor={ptyID:outputs[0].ptyID,streamID:outputs[0].streamID,cwd:'/fixture/wire',program:'shell',pid:72001,tty:'/dev/fixture-pty',columns:80,rows:24};
const view={session:{id:frame.sessionID,agent:'codex',pid:72000,started:'synthetic-original',tty:'/dev/fixture-original',cwd:'/fixture/wire',terminal:'iterm',phase:'idle',automatic:false,queuedQuestions:[]},title:'비트 전송 검증',phaseTitle:'입력 대기',canRead:true,canReveal:false,keys:frame.keys};
let mode='slow',ptyMode='drain',inputResponse,ptyResponse,releaseFresh;
let transientFailures=0;
const originals=[],ptys=[],inputs=[],errors=[],checks=[],timers=new Set(),sockets=new Set();
const abortDiagnostics=[];let phase='initial';
const until=async(test,label)=>{const end=Date.now()+12000;while(!test()){assert.ok(Date.now()<end,label);await new Promise(resolve=>setTimeout(resolve,20));}};
const variable=value=>{const bytes=[];do{const b=value&127;value=Math.floor(value/128);bytes.push(b|(value?128:0));}while(value);return bytes;};
const fallback=(value,version=3,event=2)=>{const body=Buffer.from(JSON.stringify(value));return Buffer.concat([Buffer.from([65,65,version,128|event,...variable(body.length)]),body]);};
const mime=version=>version?'application/vnd.autoapprove.terminal-v'+version:'text/event-stream';
const keep=(res,body)=>{res.write(body);const timer=setInterval(()=>{if(!res.destroyed)res.write(body);},500);timers.add(timer);res.once('close',()=>{clearInterval(timer);timers.delete(timer);});};
const server=createServer(async(req,res)=>{
 try{
  const url=new URL(req.url,'http://fixture'),json=(status,value)=>{res.writeHead(status,{'Content-Type':'application/json'});res.end(JSON.stringify(value));};
  if(url.pathname==='/api/network')return json(200,{terminalWireVersion:3,updatedAt:new Date().toISOString(),nodes:[{id:'mac',name:'합성 Mac',local:true,online:true,state:{terminalWireVersion:3,release:{version:'0.2.180',build:207,api:1},snapshot:{paused:false,events:[]},sessions:[view]}}]});
  if(url.pathname==='/api/terminal')return json(503,{error:'Synthetic fallback read unavailable'});
  if(url.pathname==='/api/terminal/stream'){
   const version=Number(url.searchParams.get('wire'))||0;originals.push(version);
   if(mode==='downgrade'&&version){res.writeHead(200,{'Content-Type':mime(version)});res.end(Buffer.from([65,65,version,0,1,255]));return;}
   res.writeHead(200,{'Content-Type':mime(version),'Cache-Control':'no-store'});res.flushHeaders();
   const body=version?Buffer.from(version===3?full.binary:full.v2,'base64'):Buffer.from('event: screen\ndata: '+JSON.stringify(frame)+'\n\n');
   if(mode==='slow'){const timer=setTimeout(()=>{timers.delete(timer);if(!res.destroyed)keep(res,body);},5200);timers.add(timer);res.once('close',()=>{clearTimeout(timer);timers.delete(timer);});}
   else keep(res,body);return;
  }
  if(url.pathname==='/api/pty/stream'){
   const offset=url.searchParams.get('offset'),version=Number(url.searchParams.get('wire'))||0;ptys.push({offset,version});
   assert.equal(version,3);assert.equal(url.searchParams.get('pty'),descriptor.ptyID);assert.equal(url.searchParams.get('stream'),descriptor.streamID);
   if(ptyMode==='identity')return json(502,{error:'Synthetic owner identity changed',diagnostics:{failureKind:'identity'}});
   if(transientFailures-->0)return json(503,{error:'Synthetic transient unavailable'});
   res.writeHead(200,{'Content-Type':mime(version)});res.flushHeaders();ptyResponse=res;
   if(ptyMode==='drain'&&offset===null){res.end(Buffer.concat(ptyRows.slice(0,2).map(r=>Buffer.from(r.binary,'base64'))));return;}
   if(ptyMode==='drain'){releaseFresh=()=>res.write(Buffer.from(ptyRows[2].binary,'base64'));return;}
   if(ptyMode==='denied'){res.write(fallback({error:'Synthetic permission denied',retryable:false},3,3));return;}
   res.write(fallback({...outputs[2],offset:Number(offset),data:'',reset:offset===null,canInput:true}));return;
  }
  if(url.pathname==='/api/pty/input'){
   let body='';for await(const part of req)body+=part;inputs.push(JSON.parse(body));inputResponse=res;return;
  }
  if(url.pathname==='/api/pty/resize')return json(200,{message:'Synthetic resize'});
  if(url.pathname.startsWith('/api/pty'))return json(409,{error:'No synthetic source creation allowed'});
  if(url.pathname.startsWith('/api/'))return json(200,{});
  const file=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(!/^(index\.html|app\.(js|css)|terminal-wire\.js|pty\.js|favicon\.svg|vendor\/xterm(-fit)?\.(js|css))$/.test(file))return json(404,{});
  res.writeHead(200,{'Content-Type':file.endsWith('.html')?'text/html':file.endsWith('.css')?'text/css':'text/javascript'});res.end(await readFile(path.resolve('Sources/AutoApproveCore/Resources/RemoteWeb',file)));
 }catch(error){errors.push(String(error));res.destroy();}
});
server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
try{
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
 browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(12000);page.on('pageerror',e=>{
  const cancellation=engine==='webkit'&&['reload','select-pty'].includes(phase)&&/^\/127\.0\.0\.1:\d+\/api\/terminal(?:\/stream)?\?.+ due to access control checks\.$/.test(e.message);
  if(cancellation)abortDiagnostics.push({phase,message:e.message});else errors.push({phase,message:e.message});
 });
 await page.goto('http://127.0.0.1:'+server.address().port);await page.locator('.session-row').first().click();const start=performance.now();
 await page.waitForFunction(()=>terminalStream?.sseReady&&latestFrame?.cursor&&latestFrame?.appearance);
 assert.equal(originals.length,1,'A 5.2s first response must not be repeatedly cancelled');assert.ok(performance.now()-start>=4900);assert.equal(await page.evaluate(()=>terminalStream.source.version),3);
 checks.push('A slow 5.2s first packed snapshot arrives on the first source while fallback GETs fail');
 mode='downgrade';originals.length=0;phase='reload';await page.reload();await page.waitForFunction(()=>terminalStream?.sseReady);
 assert.deepEqual(originals.slice(0,3),[3,2,0]);assert.equal(await page.evaluate(()=>latestFrame.streamID),frame.streamID);
 checks.push('Malformed v3 and v2 fail closed, then legacy SSE restores the same original without creating a terminal');
 // Hold actual xterm completion across an EOF, so old queued permissions must
 // stay disabled and the retry offset must include every committed byte.
 await page.evaluate(async()=>{await loadTerminalLibraries();window.qaWrite=Terminal.prototype.write;Terminal.prototype.write=function(bytes,done){return qaWrite.call(this,bytes,()=>{if(!window.qaHeldWrite){window.qaHeldWrite=done;}else done?.();});};});
 phase='select-pty';await page.evaluate(d=>selectPTYDescriptor('mac',d),descriptor);
 await page.waitForFunction(()=>window.qaHeldWrite&&ptyClient?.reconnecting);await page.waitForTimeout(200);
 assert.equal(ptys.length,1);assert.equal(await page.evaluate(()=>ptyClient.ready),false);
 await page.evaluate(()=>{Terminal.prototype.write=qaWrite;const done=qaHeldWrite;window.qaHeldWrite=null;done();});
 await page.waitForFunction(()=>ptyClient?.offset!=null&&!ptyClient.writing&&ptyClient.outputQueue.length===0);
 await until(()=>releaseFresh,'Resumed PTY opens after rendering');
 assert.equal(ptys[1].offset,String(outputs[1].offset));assert.equal(await page.evaluate(()=>ptyClient.ready),false);
 releaseFresh();await page.waitForFunction(()=>ptyClient?.ready);phase='pty';
 assert.equal(await page.evaluate(()=>ptyClient.offset),outputs[2].offset);assert.equal(inputs.length,0);
 checks.push('PTY EOF drains the bounded xterm queue, resumes the committed offset and waits for fresh input permission');
 // Establish a quiet output-only recovery, then make one input result unknown.
 ptyMode='controls';const previousOpens=ptys.length;ptyResponse.destroy();await until(()=>ptys.length>previousOpens,'Quiet output reconnect');await page.waitForFunction(()=>ptyClient?.ready&&!ptyClient.reconnecting);await page.waitForFunction(()=>ptyClient.sourceReceived);
 await page.evaluate(()=>ptyClient.enqueue('SYNTHETIC-ONCE'));
 await until(()=>inputResponse,'Explicit synthetic input');
 const opens=ptys.length;ptyResponse.destroy();await page.waitForFunction(()=>ptyClient?.blocked);
 inputResponse.writeHead(200,{'Content-Type':'application/json'});inputResponse.end(JSON.stringify({accepted:true,sequence:inputs[0].sequence}));await page.waitForTimeout(600);
 assert.equal(inputs.length,1);assert.equal(ptys.length,opens);assert.equal(await page.evaluate(()=>ptyClient.ready),false);
 checks.push('A disconnect during an in-flight input blocks input, sends it once and performs no automatic replay');
 ptyMode='controls';transientFailures=3;const transientStart=ptys.length;
 await page.evaluate(async()=>{stopPTY();await ensurePTY();});await page.waitForFunction(()=>ptyClient?.ready);
 assert.equal(ptys.length-transientStart,4);assert.ok(ptys.slice(transientStart).every(v=>v.version===3));assert.equal(inputs.length,1);
 checks.push('Temporary 503 opens use bounded retries and retain v3 compression without replaying input');
 for(const failure of ['identity','denied']){
  ptyMode=failure;const before=ptys.length;await page.evaluate(async()=>{stopPTY();await ensurePTY();});await page.waitForFunction(()=>ptyClient?.blocked);await page.waitForTimeout(400);
  assert.equal(ptys.length-before,1);assert.equal(await page.evaluate(()=>ptyClient.ready),false);
 }
 checks.push('Changed owner identity and nonretryable permissions stop automatic retries and keep input disabled');
 for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.setViewportSize({width,height});if(width>=760)await page.evaluate(()=>terminalFocus(true));await page.screenshot({path:path.join(out,name+'.png')});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
 }
 await page.evaluate(()=>{stopPTY();stopTerminalStream();});
 const vectors=['original-cursor','original-append','original-styled','original-dense','pty-log'].map(name=>({name,v2:Buffer.concat(rows.filter(r=>r.case===name).map(r=>Buffer.from(r.v2,'base64'))).toString('base64'),v3:Buffer.concat(rows.filter(r=>r.case===name).map(r=>Buffer.from(r.binary,'base64'))).toString('base64')}));
 const benchmark=await page.evaluate(vectors=>{
  const results=[];
  for(const vector of vectors){
   const bytes=Object.fromEntries([2,3].map(version=>[version,Uint8Array.from(atob(vector['v'+version]),c=>c.charCodeAt(0))]));
   const times={2:[],3:[]},repeats=vector.name==='original-dense'?16:256;let checksum=0;
   for(let round=0;round<9;round++)for(const version of round%2?[3,2]:[2,3]){
    const start=performance.now();for(let count=0;count<repeats;count++){const parser=new AutoApproveTerminalWire.Parser(true,version);parser.push(bytes[version],event=>{checksum+=(event.value.sequence||event.value.offset||event.value.extra?.runs?.length||0);});parser.finish();}
    if(round>1)times[version].push(performance.now()-start);
   }
   const v2=times[2].sort((a,b)=>a-b)[3],v3=times[3].sort((a,b)=>a-b)[3];results.push({name:vector.name,v2MS:v2,v3MS:v3,ratio:v3/v2,checksum,samples:7,framesPerSample:64*repeats});
  }return results;
 },vectors);
 assert.ok(benchmark.filter(v=>v.name==='pty-log').every(v=>v.ratio<1.15),'Unchanged PTY decoding regressed');
 assert.deepEqual(errors,[]);const report={passed:true,engine,checks,originals,ptys,inputPosts:inputs.length,benchmark,errors,abortDiagnostics,scope:'Real browser, Swift-generated vectors, synthetic loopback HTTP failures and emulated viewports; no physical phone or user CLI'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{await browser?.close();for(const t of timers){clearTimeout(t);clearInterval(t);}for(const s of sockets)s.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
