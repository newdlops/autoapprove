// Real browsers + synthetic originals. No user CLI or installed app is used.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const engine=process.argv.includes('--webkit')?'webkit':'chromium';
const out=path.resolve(process.argv.find(arg=>arg.startsWith('--output='))?.slice(9)||'dist/qa/terminal-delta');await mkdir(out,{recursive:true});
const keys=['text','submit','characters','enter','escape','interrupt','up','down','left','right','backspace','tab','choice'];
const head='원본 터미널 · 합성 데이터\n'+Array.from({length:90},(_,i)=>`[검사 ${i}] /fixture/한글/project · 색상과 출력 그대로`).join('\n')+'\n';
const initial=head+'READY> 🙂 e\u0301\n';
const views=['one','two'].map((id,i)=>({session:{id,agent:i?'claude':'codex',pid:7100+i,started:'fixture-start-'+id,tty:'/dev/fixture-'+id,cwd:'/fixture/project',terminal:'iterm',phase:'idle',automatic:true,queuedQuestions:[]},title:'변경분 검증 '+id,canRead:true,canReveal:false,keys}));
const frames=new Map(views.map(view=>[view.session.id,{sessionID:view.session.id,streamID:'original-'+view.session.id,revision:'1',sequence:1,observedAt:new Date().toISOString(),screen:initial,keys,appearance:{runs:[{offset:0,length:6,fg:'#87d7ff',bold:true}]},cursor:{offset:initial.length-1,padding:0,visible:true,style:'block',blink:false}}]));
const clients=new Set(),timers=new Set(),checks=[],errors=[],posts=[],requests={stream:0,fullReads:0,conditionalReads:0,pty:0};
let online=true,loseInputResponse=false;
async function until(test,label){const end=performance.now()+8000;while(!test()){assert.ok(performance.now()<end,label);await new Promise(resolve=>setTimeout(resolve,20));}}
function send(client,update){client.res.write('event: screen\ndata: '+JSON.stringify(update)+'\n\n');}
function edit(id,position,removed,text,extra={}){
 const before=frames.get(id),screen=before.screen.slice(0,position)+text+before.screen.slice(position+removed);
 const next={...before,...extra,screen,revision:String(before.sequence+1),sequence:before.sequence+1,observedAt:new Date().toISOString()};frames.set(id,next);
 const {screen:_,appearance,...fields}=next;
 const patch={...fields,screenPatch:{baseRevision:before.revision,baseLength:before.screen.length,prefix:position,suffix:before.screen.length-position-removed,text,length:screen.length},...(appearance===before.appearance?{appearanceUnchanged:true}:{appearance})};
 for(const client of clients)if(client.id===id)send(client,patch);
 return next;
}
function malformed(id,patch){for(const client of clients)if(client.id===id)send(client,{...frames.get(id),revision:'invalid-'+frames.get(id).sequence,screen:undefined,screenPatch:patch});}
const state=()=>({updatedAt:new Date().toISOString(),nodes:[{id:'mac',name:'변경분 QA Mac',local:true,online,state:{release:{version:'0.2.94',build:118,api:1},snapshot:{paused:false,events:[]},sessions:views}}]});
const server=createServer(async(req,res)=>{
 const url=new URL(req.url,'http://localhost'),json=(status,value)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
 if(url.pathname==='/api/network')return json(200,state());
 if(url.pathname==='/api/terminal/stream'){
  requests.stream++;assert.equal(url.searchParams.get('delta'),'1');if(!online)return json(503,{error:'synthetic connection outage'});
  res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});res.flushHeaders();
  const client={id:url.searchParams.get('session'),res};clients.add(client);send(client,frames.get(client.id));
  const timer=setInterval(()=>{const {screen,appearance,...controls}=frames.get(client.id);send(client,controls);},2000);timers.add(timer);
  res.on('close',()=>{clearInterval(timer);timers.delete(timer);clients.delete(client);});return;
 }
 if(url.pathname==='/api/terminal'){
  requests[url.searchParams.has('revision')?'conditionalReads':'fullReads']++;
  return online?json(200,frames.get(url.searchParams.get('session'))):json(503,{error:'synthetic read outage'});
 }
 if(url.pathname==='/api/input'){
  let body='';for await(const part of req)body+=part;const input=JSON.parse(body);posts.push(input);
  const before=frames.get(input.sessionID);assert.equal(input.revision,before.revision,JSON.stringify({kind:input.kind,text:input.text,posts:posts.length}));
  edit(input.sessionID,before.screen.length,0,'\n[입력] '+(input.text||input.kind));
  if(loseInputResponse){loseInputResponse=false;res.writeHead(200,{'Content-Type':'application/json','Content-Length':10000});res.write('{"message":"');setTimeout(()=>res.destroy(),30);return;}
  return json(200,{message:'검증용 입력 전달 완료'});
 }
 if(url.pathname.startsWith('/api/pty')){requests.pty++;return json(409,{error:'No new terminal allowed'});}
 if(url.pathname.startsWith('/api/'))return json(200,{});
 const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
 if(!['index.html','app.js','app.css','favicon.svg'].includes(name))return json(404,{});
 res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});res.end(await readFile(path.join('Sources/AutoApproveCore/Resources/RemoteWeb',name)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
try{
 browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true,isMobile:true});page.setDefaultTimeout(8000);page.on('pageerror',error=>errors.push(error.message));
 await page.goto('http://127.0.0.1:'+server.address().port);await page.locator('.session-row').first().click();await page.waitForFunction(()=>terminalStream?.sseReady&&latestFrame?.sessionID==='one');
 async function exact(frame){await page.waitForFunction(frame=>latestFrame?.revision===frame.revision&&latestFrame.screen===frame.screen&&$('terminal-screen').textContent===frame.screen,frame);}
 const initialStreams=requests.stream;
 let frame=edit('one',head.length+9,0,'한글·🙂·e\u0301');await exact(frame);assert.deepEqual(await page.evaluate(()=>latestFrame.appearance),frame.appearance);
 assert.equal(requests.stream,initialStreams,'A valid Unicode patch must apply without reconnecting');
 checks.push('UTF-16 insertion preserves exact text, combining characters and original appearance');
 await page.evaluate(()=>{window.qaRAF=requestAnimationFrame;window.requestAnimationFrame=()=>999999;});
 for(const text of [' 첫 변화',' 두 번째',' 세 번째']){const f=frames.get('one');frame=edit('one',f.screen.length,0,text);}
 await exact(frame);await page.evaluate(()=>window.requestAnimationFrame=window.qaRAF);checks.push('Multiple patches before paint use the prior SSE frame, including suspended animation callbacks');
 frame=edit('one',head.length,0,'질문 대기 · ',{question:{id:'question-1',question:'검증할 환경을 고르세요.',options:['개발','검증'],selected:0},cursor:{offset:head.length,padding:0,visible:true,style:'bar',blink:false}});await exact(frame);
 await page.locator('#terminal-questions').click();await page.getByRole('radio',{name:'검증',exact:true}).check();
 assert.equal(await page.getByRole('radio',{name:'검증',exact:true}).isChecked(),true);await page.locator('#close-interaction').click();
 assert.deepEqual(await page.evaluate(()=>latestFrame.cursor),frame.cursor);assert.deepEqual(await page.evaluate(()=>latestFrame.question.options),['개발','검증']);checks.push('Questions, selection UI, input controls and cursor remain current in a patch');
 frame=edit('one',frames.get('one').screen.length,0,'\n색상 제거',{appearance:undefined,question:undefined,keys});await exact(frame);
 assert.equal(await page.evaluate(()=>latestFrame.appearance),undefined);assert.equal(await page.evaluate(()=>latestFrame.question),undefined);checks.push('Missing current optional appearance and question clear their previous values');
 await page.evaluate(()=>{$('terminal-settings').open=true;});await page.locator('#compose-input').check();await page.locator('#terminal-input').fill('전송하지 않은 초안🙂');
 const beforeReads=requests.fullReads,beforeStreams=requests.stream,stable=frames.get('one');
 malformed('one',{baseRevision:'missing-base',baseLength:stable.screen.length,prefix:0,suffix:0,text:'MUST-NOT-RENDER',length:20});
 await until(()=>requests.fullReads>beforeReads&&requests.stream>beforeStreams,'Missing patch base must cause a full read and new subscription');
 await page.waitForFunction(()=>terminalStream?.sseReady&&!terminalStream.reconnecting);
 assert.ok(requests.fullReads>beforeReads);assert.ok(requests.stream>beforeStreams);assert.equal(await page.locator('#terminal-input').inputValue(),'전송하지 않은 초안🙂');assert.ok(!(await page.locator('#terminal-screen').textContent()).includes('MUST-NOT-RENDER'));
 checks.push('A missing patch base automatically reopens a full screen on the same original and preserves the draft');
 const split=stable.screen.indexOf('🙂')+1;
 const failures=[{prefix:-1,suffix:0,text:'bad',length:2},{prefix:0,suffix:stable.screen.length+1,text:'',length:stable.screen.length+1},{prefix:0,suffix:0,text:'\ud800',length:1},{prefix:split,suffix:stable.screen.length-split,text:'x',length:stable.screen.length+1}];
 for(const invalid of failures){const f=frames.get('one'),reads=requests.fullReads;malformed('one',{baseRevision:f.revision,baseLength:f.screen.length,...invalid});await until(()=>requests.fullReads>reads,'Malformed patch must trigger a fresh full read');await page.waitForFunction(()=>terminalStream?.sseReady&&!terminalStream.reconnecting);}
 checks.push('Invalid ranges and malformed surrogate replacements never alter the display and recover automatically');
 // An independently newer HTTP display must not replace the SSE patch baseline.
 const wire=frames.get('one');await page.evaluate(frame=>applyTerminalFrame({...frame,revision:'newer-http',sequence:frame.sequence+10,screen:frame.screen+'\nHTTP-AHEAD'}),wire);
 frame=edit('one',wire.screen.length,0,'\nWIRE-ONE');await page.waitForTimeout(80);
 assert.ok((await page.locator('#terminal-screen').textContent()).includes('HTTP-AHEAD'));
 for(let i=0;i<11;i++)frame=edit('one',frames.get('one').screen.length,0,'\nWIRE-'+i);
 await exact(frame);checks.push('A newer HTTP fallback cannot corrupt the separate SSE baseline; later valid patches catch up');
 const streamCount=requests.stream;online=false;for(const c of [...clients])c.res.destroy();await page.waitForFunction(()=>terminalStream?.pollFailures>0);
 assert.equal(await page.locator('#terminal-input').inputValue(),'전송하지 않은 초안🙂');assert.ok(await page.locator('#terminal-screen').textContent());
 await page.screenshot({path:path.join(out,engine+'-recovering.png')});online=true;await page.waitForFunction(()=>terminalStream?.sseReady&&!terminalStream.reconnecting);assert.ok(requests.stream>streamCount);
 checks.push('A real socket/read outage retains screen and draft, then recovers without replaying input');
 const beforeOfflineScreen=await page.locator('#terminal-screen').textContent();
 await page.context().setOffline(true);await page.waitForFunction(()=>terminalStream?.offline&&terminalStream.reconnecting);
 const pausedRequests={stream:requests.stream,reads:requests.fullReads+requests.conditionalReads};
 await page.waitForTimeout(900);assert.equal(requests.stream,pausedRequests.stream);assert.equal(requests.fullReads+requests.conditionalReads,pausedRequests.reads);
 assert.equal(await page.locator('#terminal-screen').textContent(),beforeOfflineScreen);assert.equal(await page.locator('#terminal-input').inputValue(),'전송하지 않은 초안🙂');assert.equal(await page.locator('#send-input').isDisabled(),true);
 await page.screenshot({path:path.join(out,engine+'-offline.png')});const resumed=performance.now();
 await page.context().setOffline(false);await page.waitForFunction(()=>terminalStream?.sseReady&&!terminalStream.reconnecting);
 assert.ok(performance.now()-resumed<2000,'Link restoration must reconnect immediately without waiting for backoff');assert.equal(posts.length,0);
 checks.push('Browser offline/online events pause terminal retries, preserve screen/draft and reconnect immediately without input');
 await page.evaluate(()=>window.dispatchEvent(new Event('offline')));await page.waitForFunction(()=>terminalStream?.offline);
 await page.waitForFunction(()=>terminalStream?.sseReady&&!terminalStream.offline&&!terminalStream.reconnecting,null,{timeout:4000});assert.equal(posts.length,0);
 checks.push('A false offline hint recovers through a bounded LAN read without requiring an online event');
 // The link can return without the browser reporting offline first.
 await page.evaluate(()=>{terminalStream.retries=4;reconnectTerminalStream(terminalStream);});
 const backoffRequests=requests.stream;
 await page.evaluate(()=>window.dispatchEvent(new Event('online')));
 // A real online event while recovering should wake the queued read retry.
 await page.waitForFunction(()=>terminalStream?.sseReady&&!terminalStream.reconnecting,null,{timeout:2000});
 assert.ok(requests.stream>backoffRequests);checks.push('Online notification also wakes an existing long read-subscription backoff');
 await page.locator('#terminal-input').fill('EXPLICIT-ONCE🙂');await page.locator('#send-input').click();await page.waitForFunction(()=>latestFrame.screen.includes('EXPLICIT-ONCE🙂'));
 assert.equal(posts.length,1);assert.equal(posts[0].sessionID,'one');checks.push('One explicit input after recovery reaches the same original exactly once');
 await page.waitForFunction(()=>!inputInFlight&&terminalFrameFresh());loseInputResponse=true;
 await page.locator('#terminal-input').fill('UNCERTAIN-ONCE🙂');await page.locator('#send-input').click();
 await page.waitForFunction(()=>!inputInFlight&&latestFrame.screen.includes('UNCERTAIN-ONCE🙂'));
 assert.equal(posts.length,2);assert.equal(await page.locator('#terminal-input').inputValue(),'UNCERTAIN-ONCE🙂');
 await page.evaluate(()=>{window.dispatchEvent(new Event('offline'));window.dispatchEvent(new Event('online'));});await page.waitForFunction(()=>terminalStream?.sseReady&&!terminalStream.reconnecting);await page.waitForTimeout(600);
 assert.equal(posts.length,2);assert.equal(await page.evaluate(()=>latestFrame.screen.split('UNCERTAIN-ONCE🙂').length-1),1);checks.push('A delivered input with a lost HTTP response remains uncertain and is never replayed by recovery');
 await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});await page.waitForTimeout(80);
 await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));});await page.waitForFunction(()=>terminalStream?.sseReady&&latestFrame?.sessionID==='one');checks.push('Background/foreground starts with a new full SSE baseline');
 await page.locator('#terminal-back').click();await page.locator('.session-row').nth(1).click();await page.waitForFunction(()=>terminalStream?.sseReady&&latestFrame?.sessionID==='two');
 checks.push('Session switch starts from the selected original without old patch or draft leakage');
 await page.locator('#feedback').waitFor({state:'hidden',timeout:16000});
 for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.setViewportSize({width,height});if(width>=760)await page.evaluate(()=>terminalFocus(true));await page.screenshot({path:path.join(out,engine+'-'+name+'.png')});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
 }
 assert.equal(requests.pty,0);assert.equal(posts.length,2);assert.deepEqual(errors,[]);
 const report={engine,checks,requests,posts:posts.length,errors,scope:'Real browsers, synthetic originals and socket failures; no user sessions or physical phone'};await writeFile(path.join(out,engine+'.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
}finally{await browser?.close();for(const timer of timers)clearInterval(timer);for(const c of clients)c.res.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
