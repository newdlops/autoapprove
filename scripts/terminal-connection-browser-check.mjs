// Browser + synthetic original terminal. Never reads or inputs into a user's CLI.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const engine=process.argv.includes('--webkit')?'webkit':'chromium';
const output=path.resolve('dist/qa/terminal-connection');await mkdir(output,{recursive:true});
const keys=['characters','backspace','enter','left','right','up','down','home','end','tab','escape','interrupt'];
const views=['one','two'].map((id,index)=>({session:{id,agent:index?'claude':'codex',pid:7200+index,started:'original-'+id,tty:'/dev/fixture-'+id,cwd:'/fixture/terminal',terminal:'iterm',phase:'idle',automatic:true,queuedQuestions:[]},title:'연결 검증 '+id,phaseTitle:'입력 대기',canRead:true,canReveal:false,keys}));
const frames=new Map(views.map(v=>[v.session.id,{sessionID:v.session.id,revision:'1',sequence:1,streamID:'same-original-'+v.session.id,screen:'원본 터미널 · 한글 🧪\nREADY> ',keys,observedAt:new Date().toISOString()}]));
let streamMode='silent',getFail=false,getDelay=0,activeReads=0,maxReads=0;
const counts={stream:0,poll:0,input:0,pty:0},clients=new Set(),timers=new Set(),operations=[],errors=[],checks=[];
const state=()=>({updatedAt:new Date().toISOString(),nodes:[{id:'mac',name:'검증 Mac',local:true,online:true,state:{release:{version:'0.2.72',build:94,api:1},snapshot:{paused:false,events:[]},sessions:views}}]});
const server=createServer(async(req,res)=>{
 const url=new URL(req.url,'http://localhost');
 const json=(status,value)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
 if(url.pathname==='/api/network')return json(200,state());
 if(url.pathname==='/api/terminal/stream'){
  counts.stream++;if(streamMode==='error')return json(503,{error:'stream unavailable'});
  res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});res.flushHeaders();
  const c={id:url.searchParams.get('session'),res};clients.add(c);
  const send=()=>{if(streamMode==='live')res.write('event: screen\ndata: '+JSON.stringify(frames.get(c.id))+'\n\n');};send();
  const timer=setInterval(send,200);timers.add(timer);res.on('close',()=>{clearInterval(timer);timers.delete(timer);clients.delete(c);});return;
 }
 if(url.pathname==='/api/terminal'){
  counts.poll++;activeReads++;maxReads=Math.max(maxReads,activeReads);let done=false;
  const finish=()=>{if(!done){done=true;activeReads--;}};res.on('close',finish);
  const id=url.searchParams.get('session'),snapshot={...frames.get(id)};
  if(getDelay)await new Promise(resolve=>setTimeout(resolve,getDelay));finish();if(res.destroyed)return;
  if(getFail)return json(503,{error:'temporary network outage'});
  return json(200,snapshot);
 }
 if(url.pathname==='/api/input'){
  counts.input++;let body='';for await(const part of req)body+=part;
  const input=JSON.parse(body);operations.push(input);assert.equal(input.streamID,frames.get(input.sessionID).streamID);
  return json(200,{message:'fixture input received'});
 }
 if(url.pathname.startsWith('/api/pty')){counts.pty++;return json(409,{error:'No new source allowed'});}
 if(url.pathname.startsWith('/api/'))return json(200,{});
 const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
 if(!['index.html','app.js','app.css','favicon.svg'].includes(name))return json(404,{error:'not found'});
 res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});res.end(await readFile(path.resolve('Sources/AutoApproveCore/Resources/RemoteWeb',name)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
function change(id,text){const f=frames.get(id);f.revision=String(Number(f.revision)+1);f.sequence++;f.screen=text;f.observedAt=new Date().toISOString();}
try{
 browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true,isMobile:true});page.setDefaultTimeout(5000);page.on('pageerror',e=>errors.push(e.message));
 await page.goto('http://127.0.0.1:'+server.address().port);const start=performance.now();await page.locator('.session-row').first().click();
 await page.waitForFunction(()=>latestFrame?.sessionID==='one'&&$('terminal-screen').textContent.includes('READY>'),null,{timeout:2000});
 checks.push({case:'First screen arrives while SSE is open but completely silent',ms:Math.round(performance.now()-start)});
 assert.equal(counts.pty,0);assert.equal(counts.input,0);assert.ok(counts.poll>0);
 change('one','원본의 새 출력\nSILENT-STREAM-UPDATES\nREADY> ');await page.waitForFunction(()=>$('terminal-screen').textContent.includes('SILENT-STREAM-UPDATES'));
 checks.push({case:'Silent SSE still updates the same original through bounded GET reads'});
 streamMode='error';for(const c of clients)c.res.destroy();change('one','SSE-ERROR-UPDATE\nREADY> ');await page.waitForFunction(()=>$('terminal-screen').textContent.includes('SSE-ERROR-UPDATE'));
 for(let i=0;i<8;i++){await page.waitForTimeout(200);assert.equal(await page.evaluate(()=>terminalFrameFresh()),true,'Stream retries must retain a fresh HTTP connection');}
 checks.push({case:'Repeated SSE connection errors do not prevent live original output or invalidate successful HTTP reads'});
 getFail=true;await page.waitForFunction(()=>terminalStream?.pollFailures>0);assert.ok(await page.locator('#terminal-screen').textContent());getFail=false;change('one','NETWORK-RECOVERED\nREADY> ');
 await page.waitForFunction(()=>$('terminal-screen').textContent.includes('NETWORK-RECOVERED')&&!terminalStream?.reconnecting);checks.push({case:'Read outage preserves the last screen and recovers without source creation or input replay'});
 streamMode='live';for(const c of clients)c.res.destroy();await page.waitForFunction(()=>terminalStream?.sseReady===true);
 const readCount=counts.poll;await page.waitForTimeout(1100);assert.equal(counts.poll,readCount,'Healthy SSE stops fallback polling');checks.push({case:'Healthy stream takeover cancels fallback reads'});
 await page.evaluate(()=>{window.qaRealRAF=requestAnimationFrame;window.requestAnimationFrame=()=>999999;});
 change('one','ANIMATION-CALLBACK-SUSPENDED\nREADY> ');
 await page.waitForFunction(()=>$('terminal-screen').textContent.includes('ANIMATION-CALLBACK-SUSPENDED'),null,{polling:50,timeout:1500});
 assert.equal(await page.evaluate(()=>terminalFrameFresh()),true);await page.evaluate(()=>window.requestAnimationFrame=window.qaRealRAF);
 checks.push({case:'Visible terminal output and frame freshness continue even when animation callbacks never fire'});
 for(const c of clients)c.res.write('event: screen\ndata: '+JSON.stringify({...frames.get(c.id),sequence:0,revision:'stale',screen:'STALE-SSE-MUST-NOT-REPLACE'})+'\n\n');
 await page.waitForTimeout(100);assert.ok(!(await page.locator('#terminal-screen').textContent()).includes('STALE-SSE'));await page.waitForFunction(()=>terminalStream?.sseReady===true);
 checks.push({case:'An older SSE frame cannot overwrite the newer HTTP snapshot or its controls'});
 streamMode='error';for(const c of clients)c.res.destroy();await page.locator('#terminal-keyboard-toggle').click();await page.waitForFunction(()=>directMode);
 frames.get('one').keys=['text','submit','enter'];change('one','INPUT-PERMISSION-REMOVED\nREADY> ');
 await page.waitForFunction(()=>!directMode&&latestFrame.screen.includes('INPUT-PERMISSION-REMOVED'));assert.equal(counts.input,0);
 checks.push({case:'HTTP fallback detects removed input capability and stops direct mode without sending keys'});
 await page.evaluate(()=>window.qaOldSource=terminalStream.source);
 const oldFrame={...frames.get('one')};frames.get('one').keys=keys;frames.get('one').streamID='new-original-binding';change('one','ROTATED-BINDING\nREADY> ');
 await page.waitForFunction(()=>latestFrame?.streamID==='new-original-binding');
 await page.evaluate(frame=>window.qaOldSource?.dispatchEvent(new MessageEvent('screen',{data:JSON.stringify(frame)})),oldFrame);
 await page.waitForTimeout(100);assert.equal(await page.evaluate(()=>latestFrame.streamID),'new-original-binding');
 checks.push({case:'A changed original binding retires its old SSE so queued old events cannot rebind the screen'});
 streamMode='silent';getDelay=700;for(const c of clients)c.res.destroy();await page.waitForTimeout(100);await page.locator('#terminal-back').click();await page.locator('.session-row').nth(1).click();
 await page.waitForFunction(()=>latestFrame?.sessionID==='two');await page.waitForTimeout(800);assert.equal(await page.evaluate(()=>latestFrame.sessionID),'two');getDelay=0;
 checks.push({case:'Late responses from a previous selection cannot replace the new original'});
 await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});await page.waitForTimeout(250);assert.equal(clients.size,0);
 await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));});await page.waitForFunction(()=>latestFrame?.sessionID==='two');checks.push({case:'Phone background and foreground reconnect the same selection'});
 for(const[name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});if(width>=760)await page.evaluate(()=>terminalFocus(true));await page.screenshot({path:path.join(output,engine+'-'+name+'.png')});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);}
 assert.ok(maxReads<=2,'At most one fallback read per current selection; one cancelled server handler can finish');assert.equal(counts.input,0);assert.equal(counts.pty,0);assert.deepEqual(errors,[]);
 const report={engine,result:'PASS',checks,counts,maxReads,errors,scope:'Real browser, synthetic HTTP/SSE original; no physical phone or user-session input'};await writeFile(path.join(output,engine+'-report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{await browser?.close();for(const t of timers)clearInterval(t);for(const c of clients)c.res.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
