// Real Chromium + synthetic original-terminal API; no user's CLI is touched.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import path from 'node:path';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const output=path.resolve('dist/qa/original-terminal');await mkdir(output,{recursive:true});
const keys=['text','submit','characters','enter','escape','interrupt','up','down','left','right','backspace','delete','home','end','tab'];
const sources=['original','other'].map((id,index)=>({session:{id,agent:index?'claude':'codex',pid:4200+index,started:'fixed-start-'+id,tty:'/dev/fixture-'+id,cwd:'/fixture/shared-terminal',terminal:'iterm',hostName:'원래 Mac 터미널',phase:'idle',automatic:true,detail:'동일한 원래 터미널',queuedQuestions:[]},title:index?'두 번째 원래 터미널':'Mac과 같은 터미널',phaseTitle:'입력 대기',canRead:true,canApprove:true,canReveal:false,keys}));
const state=new Map(sources.map(view=>[view.session.id,{screen:'원래 Mac 터미널\nREADY> ',revision:0,stream:'original-stream-'+view.session.id,cursor:null}]));
let release={version:'0.2.42',build:49,api:1},online=true,failNext=false,inputDelay=30;
let networkFail=false,streamAvailable=true,clockOffset=0,pauseHeartbeats=false;
let nextInputGate=null;
const inputGates=new Set();
function holdNextInput(){assert.equal(nextInputGate,null);let resolve;const promise=new Promise(done=>{resolve=done;});const gate={promise,release:()=>{inputGates.delete(gate);resolve();}};inputGates.add(gate);nextInputGate=gate;return gate;}
const clients=new Set(),operations=[],receipts=new Map(),requests={pty:0,stream:0,poll:0};
const oldCopies=[];
const checks=[],screenshots=[],errors=[],latencies=[];
const expectedTransportErrors=[];let transportFault=false;
const network=()=>({updatedAt:new Date().toISOString(),nodes:[{id:'original-mac',name:'원래 Mac',local:true,online,state:{release,snapshot:{paused:false,events:[]},sessions:[...sources.filter(view=>view.session.phase!=='ended'),...oldCopies]}}]});
function update(id,full=true){const value=state.get(id);return {sessionID:id,revision:String(value.revision),streamID:value.stream,observedAt:new Date(Date.now()+clockOffset).toISOString(),keys,cursor:value.cursor||{offset:value.screen.length,padding:0,visible:true,style:'block',blink:false},...(full?{screen:value.screen}:{} )};}
function push(id,full=true){for(const client of clients)if(client.id===id)client.res.write('event: screen\ndata: '+JSON.stringify(update(id,full))+'\n\n');}
function macOutput(id,value){const item=state.get(id);item.screen=value;item.revision++;push(id);}
const server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://localhost');
  const json=(status,data)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(data));};
  try{
    if(url.pathname==='/api/network')return networkFail?json(503,{error:'기기 목록 조회 일시 중단'}):json(200,network());
    if(url.pathname==='/api/pty'){requests.pty++;return json(409,{error:'기존 터미널에서 새 프로세스를 만들면 안 됩니다.'});}
    if(url.pathname==='/api/terminal/stream'){
      requests.stream++;const id=url.searchParams.get('session');
      if(!streamAvailable)return json(503,{error:'일시적인 화면 연결 중단'});
      assert.equal(url.searchParams.get('node'),'original-mac');assert.ok(state.has(id));
      if(sources.find(view=>view.session.id===id).session.phase==='ended')return json(410,{error:'원래 터미널이 종료되었습니다.'});
      res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store','Connection':'keep-alive'});res.flushHeaders();
      const client={id,res};clients.add(client);push(id);
      const heartbeat=setInterval(()=>{if(!pauseHeartbeats)push(id,false);},2000);
      res.on('close',()=>{clearInterval(heartbeat);clients.delete(client);});return;
    }
    if(url.pathname==='/api/terminal'){requests.poll++;return json(200,update(url.searchParams.get('session')));}
    if(url.pathname==='/api/input'){
      let data='';for await(const part of req)data+=part;const input=JSON.parse(data);
      assert.equal(url.searchParams.get('node'),'original-mac');assert.ok(state.has(input.sessionID));
      if(receipts.has(input.requestID))return json(200,receipts.get(input.requestID));
      const source=state.get(input.sessionID);assert.equal(input.streamID,source.stream);
      operations.push(input);macOutput(input.sessionID,source.screen+(input.kind==='characters'?input.text:'\nPHONE:'+input.kind+':'+input.text));
      const fail=failNext,gate=nextInputGate;failNext=false;nextInputGate=null;await(gate?gate.promise:new Promise(resolve=>setTimeout(resolve,inputDelay)));
      if(fail)return json(503,{error:'입력 결과를 확인하지 못했습니다. 원래 터미널을 확인해주세요.'});
      const receipt={message:'원래 터미널에 전달했습니다.'};receipts.set(input.requestID,receipt);return json(200,receipt);
    }
    if(url.pathname==='/api/action')return json(200,{message:'변경했습니다.'});
    const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
    if(!['index.html','app.js','app.css','pty.js','vendor/xterm.js','vendor/xterm-fit.js','vendor/xterm.css','favicon.svg'].includes(name))return json(404,{error:'not found'});
    const file=await readFile(path.join('Sources/AutoApproveCore/Resources/RemoteWeb',name));
    res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});res.end(file);
  }catch(error){json(500,{error:error.message});}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const url='http://127.0.0.1:'+server.address().port;
let browser,page,stage='selection';
try{
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
  page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(12000);
  page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{
    if(message.type()!=='error'||message.text().includes('status of 503'))return;
    if(transportFault&&message.text().includes('net::ERR_INCOMPLETE_CHUNKED_ENCODING'))expectedTransportErrors.push(message.text());
    else errors.push(message.text());
  });
  async function ready(){await page.waitForFunction(()=>latestFrame?.sessionID==='original'&&!$('terminal-keyboard-toggle').disabled);}
  async function count(value){await page.waitForFunction(value=>window.qaOperationCount>=value,value);}
  async function drained(){await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);}
  async function capture(name){await page.screenshot({path:path.join(output,name+'.png')});screenshots.push(name);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);}
  await page.exposeFunction('qaOperations',()=>operations.length);
  await page.exposeFunction('qaStreams',()=>requests.stream);
  await page.addInitScript(()=>{setInterval(async()=>{window.qaOperationCount=await window.qaOperations();window.qaStreamCount=await window.qaStreams();},30);});
  await page.goto(url);await page.locator('.session-row').first().click();await ready();
  assert.equal(requests.pty,0,'Selecting an existing original must create zero PTYs');
  assert.equal(requests.stream,1);assert.equal(requests.poll,0);
  const identity=await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty,count:allSessions.length}));
  assert.deepEqual(identity,{id:'original',pid:4200,tty:'/dev/fixture-original',count:2});
  assert.equal(await page.locator('#pty-dialog').isVisible(),false);assert.equal(await page.locator('#continue-pty').count(),0);
  await page.reload();await ready();assert.equal(requests.pty,0);assert.deepEqual(await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty,count:allSessions.length})),identity);
  await page.evaluate(()=>{history.replaceState(null,'','#node=original-mac&session=original&pty=legacy-copy');restoreSelection();});await ready();assert.equal(await page.evaluate(()=>selectedItem.session.id),'original');assert.equal(requests.pty,0);
  checks.push('original selection and reload retain session/PID/TTY/count with zero PTY creation');
  for(let i=0;i<5;i++){const marker='MAC-PUSH-'+i,started=Date.now();macOutput('original','Mac의 같은 화면\n'+marker+'\nREADY> ');await page.waitForFunction(marker=>$('terminal-screen').textContent.includes(marker),marker);latencies.push(Date.now()-started);}
  assert.ok(Math.max(...latencies)<600);assert.equal(requests.poll,0);checks.push('Mac-side pushed output arrives without terminal polling');
  const frameBefore=await page.evaluate(()=>latestFrame.screen);state.get('original').cursor={offset:0,padding:0,visible:true,style:'bar',blink:false};push('original',false);
  await page.waitForFunction(()=>latestFrame?.cursor?.offset===0);assert.equal(await page.evaluate(()=>latestFrame.screen),frameBefore);
  stage='Codex source cursor and composer above a long footer';
  const composerPrefix='Working · 원본 Codex\n'+Array.from({length:30},(_,i)=>'원본 출력 '+i).join('\n')+'\n› ';
  const footer='\n'+Array.from({length:35},(_,i)=>'Codex 상태 '+i).join('\n');
  const draft='한글🧪abcdef';
  state.get('original').cursor={offset:(composerPrefix+draft).length,padding:0,visible:true,style:'bar',blink:false};
  macOutput('original',composerPrefix+draft+footer);
  await page.waitForFunction(()=>!$('terminal-cursor').hidden&&latestFrame?.screen.includes('한글🧪abcdef'));
  const preBounds=await page.locator('#terminal-screen').boundingBox(),atEnd=await page.locator('#terminal-cursor').boundingBox();
  assert.ok(atEnd.y>=preBounds.y&&atEnd.y+atEnd.height<=preBounds.y+preBounds.height+2,'Follow keeps the real Codex composer visible above its footer');
  const unchanged=await page.locator('#terminal-screen').textContent();
  state.get('original').cursor.offset-=3;push('original',false);
  await page.waitForFunction(offset=>$('terminal-cursor').dataset.offset===String(offset),state.get('original').cursor.offset);
  const left=await page.locator('#terminal-cursor').boundingBox();assert.ok(left.x<atEnd.x);
  assert.equal(await page.locator('#terminal-screen').textContent(),unchanged,'Cursor-only frames must preserve exact original input and output');
  await page.evaluate(()=>{$('follow').checked=false;$('terminal-screen').scrollTop=0;});
  state.get('original').cursor.offset=(composerPrefix+draft).length;push('original',false);await page.waitForTimeout(100);
  assert.equal(await page.locator('#terminal-screen').evaluate(e=>e.scrollTop),0,'Follow OFF keeps the user scroll position');
  await page.evaluate(()=>{$('follow').checked=true;scheduleCursor();});await page.waitForFunction(()=>!$('terminal-cursor').hidden);
  state.get('original').cursor.visible=false;push('original',false);await page.waitForFunction(()=>$('terminal-cursor').hidden);
  state.get('original').cursor={offset:0,padding:0,visible:true,style:'bar',blink:false};
  checks.push('Codex multiline Unicode composer and cursor-only left/right updates follow the original above a long footer; OFF and hidden state stay truthful');
  for(let i=0;i<100;i++)macOutput('original','BURST-'+i+'\nREADY> ');
  await page.waitForFunction(()=>$('terminal-screen').textContent.includes('BURST-99'));assert.equal(await page.evaluate(()=>!!terminalPending),false);
  checks.push('compact controls retain screen and burst rendering retains only latest pending frame');
  await page.locator('#terminal-screen').click();await page.keyboard.type('PHONE-SAME');await drained();
  assert.equal(operations.map(input=>input.text).join(''),'PHONE-SAME');assert.ok(operations.every(input=>input.sessionID==='original'&&input.kind==='characters'&&input.relay===true&&input.streamID==='original-stream-original'));
  const beforeArrows=operations.length;await page.keyboard.press('ArrowLeft');await drained();await page.keyboard.press('ArrowRight');await drained();
  assert.deepEqual(operations.slice(beforeArrows).map(input=>[input.sessionID,input.kind]),[['original','left'],['original','right']]);
  assert.equal(await page.locator('#automatic').isChecked(),true);assert.equal(await page.locator('#terminal-input').isVisible(),false);
  checks.push('phone characters and arrows target original session while automation stays ON');
  stage='inventory outage';
  const beforeInventory=operations.length,streamBeforeInventory=requests.stream;
  networkFail=true;await page.evaluate(()=>refreshNetwork());
  assert.equal(await page.locator('#terminal-keyboard').isDisabled(),false,'An inventory error must retain the healthy original keyboard');
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'terminal-keyboard');
  await page.keyboard.type('LIST-OUTAGE');await drained();
  assert.equal(operations.slice(beforeInventory).map(input=>input.text).join(''),'LIST-OUTAGE');
  assert.equal(requests.stream,streamBeforeInventory,'A healthy SSE must survive a failed independent inventory request');
  networkFail=false;await page.evaluate(()=>refreshNetwork());
  checks.push('inventory outage keeps the healthy SSE, keyboard focus and ordered input');
  stage='clock skew';clockOffset=-120000;push('original',false);
  await page.waitForFunction(()=>Date.now()-Date.parse(latestFrame.observedAt)>110000);
  assert.equal(await page.locator('#terminal-keyboard').isDisabled(),false,'Frame freshness must use local receipt time despite Mac/phone clock skew');
  const beforeClock=operations.length;await page.keyboard.type('CLOCK');await drained();
  assert.equal(operations.slice(beforeClock).map(input=>input.text).join(''),'CLOCK');clockOffset=0;
  checks.push('two-minute Mac/phone clock skew does not disable verified fresh input');
  stage='transport outage';
  const beforeReconnect=operations.length,streamBeforeReconnect=requests.stream;
  transportFault=true;streamAvailable=false;for(const client of [...clients])client.res.destroy();
  await page.waitForFunction(()=>$('terminal-live').textContent.includes('재연결'));
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'terminal-keyboard');
  await page.keyboard.type('RECOVER');await page.keyboard.press('ArrowLeft');
  await page.evaluate(()=>{
    const keyboard=$('terminal-keyboard');keyboard.dispatchEvent(new CompositionEvent('compositionstart'));
    keyboard.value=keyboardMarker+'한글🧪';keyboard.dispatchEvent(new InputEvent('input',{inputType:'insertCompositionText',data:'한글🧪',isComposing:true}));
  });
  await capture('mobile-reconnecting-composition');
  await page.waitForTimeout(6500);
  assert.equal(operations.length,beforeReconnect,'Unsent keys must wait through an outage longer than the input frame deadline');
  assert.equal(await page.evaluate(()=>directMode&&composing&&document.activeElement?.id==='terminal-keyboard'),true);
  await page.evaluate(()=>{$('terminal-keyboard').dispatchEvent(new CompositionEvent('compositionend',{data:'한글🧪'}));});
  await page.waitForFunction(()=>!composing&&directQueue.length>=3);
  await page.keyboard.press('Enter');streamAvailable=true;
  await page.waitForFunction(()=>terminalStream&&!terminalStream.reconnecting&&!!latestFrame);await drained();
  assert.deepEqual(operations.slice(beforeReconnect).map(input=>[input.kind,input.text]),[['characters','RECOVER'],['left',''],['characters','한글🧪'],['enter','']]);
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'terminal-keyboard');
  assert.ok(requests.stream-streamBeforeReconnect<=6,'Reconnect attempts must back off');
  transportFault=false;
  assert.equal(requests.pty,0);await capture('mobile-reconnected-input');
  checks.push('real socket loss backs off, retains focus/IME and resumes unsent Unicode/arrows/Enter once in order');
  stage='stalled SSE';const beforeStall=requests.stream;pauseHeartbeats=true;
  await page.waitForFunction(before=>qaStreamCount>before,beforeStall);pauseHeartbeats=false;
  await page.waitForFunction(()=>terminalStream&&!terminalStream.reconnecting&&!!latestFrame);
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'terminal-keyboard');
  assert.equal(clients.size,1);checks.push('silent open SSE is refreshed automatically without a second terminal or keyboard blur');
  stage='transient peer failure';const beforePeer=requests.stream;
  for(const client of [...clients]){client.res.write('event: failure\ndata: '+JSON.stringify({error:'상대 Mac의 연결이 일시 중단되었습니다.',retryable:true})+'\n\n');client.res.end();}
  await page.waitForFunction(before=>qaStreamCount>before&&!terminalStream?.reconnecting,beforePeer);
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'terminal-keyboard');
  assert.equal(await page.locator('#terminal-retry').isVisible(),false);
  checks.push('retryable upstream peer failure reconnects the same original without closing its keyboard');
  const beforeFailure=operations.length;failNext=true;const failureGate=holdNextInput();await page.keyboard.type('UNCERTAIN');await count(beforeFailure+1);await page.keyboard.type('QUEUED');failureGate.release();await page.waitForFunction(()=>!directMode&&!!inputFailure);await page.waitForTimeout(450);
  assert.equal(operations.length,beforeFailure+1);assert.equal(await page.locator('#terminal-input').inputValue(),'UNCERTAINQUEUED');await capture('mobile-uncertain-input');
  checks.push('uncertain input preserves failed/queued text and never replays');
  const beforeStream=requests.stream;await page.evaluate(()=>terminalStream.source.dispatchEvent(new MessageEvent('failure',{data:JSON.stringify({error:'원본 세션의 입력 권한이 해제되었습니다.'})})));
  await page.waitForFunction(()=>!latestFrame&&$('terminal-retry').hidden===false);await page.waitForTimeout(600);assert.equal(requests.stream,beforeStream);assert.equal(operations.length,beforeFailure+1);
  await capture('mobile-stream-error');await page.locator('#terminal-retry').click();await page.waitForFunction(()=>latestFrame?.sessionID==='original');assert.equal(requests.pty,0);assert.equal(operations.length,beforeFailure+1);
  checks.push('explicit server failure stops input and manual retry never forks or replays uncertain input');
  await page.locator('#terminal-back').click();await page.locator('.session-row').nth(1).click();await page.waitForFunction(()=>latestFrame?.sessionID==='other');await page.waitForTimeout(100);assert.equal([...clients].some(client=>client.id==='original'),false);
  await page.locator('#terminal-back').click();await page.locator('.session-row').first().click();await page.waitForFunction(()=>latestFrame?.sessionID==='original');
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});await page.waitForTimeout(100);assert.equal(clients.size,0);
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));});await page.waitForFunction(()=>latestFrame?.sessionID==='original');
  checks.push('selection and simulated hidden-tab transitions cancel only the frontend subscription');
  await page.locator('#terminal-input').fill('');await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').uncheck();await page.locator('#feedback').waitFor({state:'hidden',timeout:15000});
  for(const [name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
    stage=name;
    await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);
    await page.setViewportSize({width,height});await page.evaluate(enabled=>terminalFocus(enabled),width<760);
    await page.waitForTimeout(150);
    await page.locator('#terminal-screen').click();const before=operations.length,marker='VIEW-'+name;await page.keyboard.type(marker);await drained();
    const characters=operations.slice(before);assert.ok(characters.length>0&&characters.every(input=>input.sessionID==='original'&&input.kind==='characters'&&input.relay===true&&input.streamID==='original-stream-original'));assert.equal(characters.map(input=>input.text).join(''),marker);await page.waitForFunction(marker=>$('terminal-screen').textContent.includes(marker),marker);
    assert.equal(operations.at(-1).sessionID,'original');assert.equal(await page.locator('#automatic').isChecked(),true);await page.waitForTimeout(150);await capture(name+'-same-terminal');
  }
  checks.push('mobile/tablet/desktop screen taps send directly to the same original with automation ON');
  online=false;await page.evaluate(()=>refreshNetwork());await page.waitForTimeout(100);assert.equal(clients.size,1);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),false);
  checks.push('an inventory timeout retains the independently verified original stream and keyboard');
  online=true;release={version:'0.2.41',build:48,api:1};await page.evaluate(()=>refreshNetwork());await page.evaluate(()=>refreshFrame());await page.waitForFunction(()=>!!latestFrame);assert.ok(requests.poll>0);assert.equal(clients.size,0);assert.equal(requests.pty,0);
  checks.push('disconnect disables original input and older peers retain polling without fork offers');
  sources[0].session.phase='ended';oldCopies.push({...sources[0],session:{...sources[0].session,id:'pty:legacy-copy',pid:4300,tty:'/dev/fixture-copy',phase:'idle'},ptyID:'legacy-copy',pty:{ptyID:'legacy-copy',streamID:'legacy-copy-stream',pid:4300,tty:'/dev/fixture-copy',cwd:'/fixture/copied-terminal',program:'codex',columns:80,rows:24}});
  await page.evaluate(()=>{history.replaceState(null,'','#node=original-mac&session=original&pty=legacy-copy');});await page.reload();await page.locator('.session-row').first().waitFor();await page.waitForTimeout(150);assert.equal(requests.pty,0);assert.equal(await page.locator('#session-count').innerText(),'2개');assert.equal(await page.evaluate(()=>selectedItem),null);
  checks.push('ended source and stale original+copy bookmark never revive, fork, or substitute the copied CLI');
  assert.deepEqual(errors,[]);await writeFile(path.join(output,'report.json'),JSON.stringify({checks,screenshots,errors,expectedTransportErrors,requests,macPushLatencyMs:latencies,scope:'Chromium + synthetic original HTTP/SSE fixture; no physical phone or native Mac key delivery'},null,2)+'\n');
  await Promise.all(['failure.png','failure.json'].map(name=>rm(path.join(output,name),{force:true})));
  console.log(JSON.stringify({result:'PASS',checks,screenshots,errors,requests,macPushLatencyMs:latencies}));
}catch(error){
  const detail=await page?.evaluate(()=>({key:selectedKey,frame:latestFrame,directMode,directQueue,inputFailure,composeMode,keyboard:document.activeElement?.id,keyboardDisabled:$('terminal-keyboard').disabled,screen:$('terminal-screen').textContent})).catch(()=>null);
  await page?.screenshot({path:path.join(output,'failure.png')}).catch(()=>{});await writeFile(path.join(output,'failure.json'),JSON.stringify({stage,error:error.message,operations,detail},null,2));throw error;
}finally{for(const gate of inputGates)gate.release();await browser?.close();for(const client of clients)client.res.end();await new Promise(resolve=>server.close(resolve));}
