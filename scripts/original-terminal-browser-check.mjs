// Real Chromium + synthetic original-terminal API; no user's CLI is touched.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const output=path.resolve('dist/qa/original-terminal');await mkdir(output,{recursive:true});
const keys=['text','submit','characters','enter','escape','interrupt','up','down','left','right','backspace','delete','home','end','tab'];
const sources=['original','other'].map((id,index)=>({session:{id,agent:index?'claude':'codex',pid:4200+index,started:'fixed-start-'+id,tty:'/dev/fixture-'+id,cwd:'/fixture/shared-terminal',terminal:'iterm',hostName:'원래 Mac 터미널',phase:'idle',automatic:true,detail:'동일한 원래 터미널',queuedQuestions:[]},title:index?'두 번째 원래 터미널':'Mac과 같은 터미널',phaseTitle:'입력 대기',canRead:true,canApprove:true,canReveal:false,keys}));
const state=new Map(sources.map(view=>[view.session.id,{screen:'원래 Mac 터미널\nREADY> ',revision:0,stream:'original-stream-'+view.session.id,cursor:null}]));
let release={version:'0.2.42',build:49,api:1},online=true,failNext=false,inputDelay=30;
const clients=new Set(),operations=[],receipts=new Map(),requests={pty:0,stream:0,poll:0};
const oldCopies=[];
const checks=[],screenshots=[],errors=[],latencies=[];
const network=()=>({updatedAt:new Date().toISOString(),nodes:[{id:'original-mac',name:'원래 Mac',local:true,online,state:{release,snapshot:{paused:false,events:[]},sessions:[...sources.filter(view=>view.session.phase!=='ended'),...oldCopies]}}]});
function update(id,full=true){const value=state.get(id);return {sessionID:id,revision:String(value.revision),streamID:value.stream,observedAt:new Date().toISOString(),keys,cursor:value.cursor||{offset:value.screen.length,padding:0,visible:true,style:'block',blink:false},...(full?{screen:value.screen}:{} )};}
function push(id,full=true){for(const client of clients)if(client.id===id)client.res.write('event: screen\ndata: '+JSON.stringify(update(id,full))+'\n\n');}
function macOutput(id,value){const item=state.get(id);item.screen=value;item.revision++;push(id);}
const server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://localhost');
  const json=(status,data)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(data));};
  try{
    if(url.pathname==='/api/network')return json(200,network());
    if(url.pathname==='/api/pty'){requests.pty++;return json(409,{error:'기존 터미널에서 새 프로세스를 만들면 안 됩니다.'});}
    if(url.pathname==='/api/terminal/stream'){
      requests.stream++;const id=url.searchParams.get('session');
      assert.equal(url.searchParams.get('node'),'original-mac');assert.ok(state.has(id));
      if(sources.find(view=>view.session.id===id).session.phase==='ended')return json(410,{error:'원래 터미널이 종료되었습니다.'});
      res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store','Connection':'keep-alive'});res.flushHeaders();
      const client={id,res};clients.add(client);push(id);
      const heartbeat=setInterval(()=>push(id,false),2000);
      res.on('close',()=>{clearInterval(heartbeat);clients.delete(client);});return;
    }
    if(url.pathname==='/api/terminal'){requests.poll++;return json(200,update(url.searchParams.get('session')));}
    if(url.pathname==='/api/input'){
      let data='';for await(const part of req)data+=part;const input=JSON.parse(data);
      assert.equal(url.searchParams.get('node'),'original-mac');assert.ok(state.has(input.sessionID));
      if(receipts.has(input.requestID))return json(200,receipts.get(input.requestID));
      const source=state.get(input.sessionID);assert.equal(input.streamID,source.stream);
      operations.push(input);macOutput(input.sessionID,source.screen+'\nPHONE:'+input.kind+':'+input.text);
      const fail=failNext;failNext=false;await new Promise(resolve=>setTimeout(resolve,inputDelay));
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
  page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{if(message.type()==='error'&&!message.text().includes('status of 503'))errors.push(message.text());});
  async function ready(){await page.waitForFunction(()=>latestFrame?.sessionID==='original'&&!$('terminal-keyboard-toggle').disabled);}
  async function count(value){await page.waitForFunction(value=>window.qaOperationCount>=value,value);}
  async function capture(name){await page.screenshot({path:path.join(output,name+'.png')});screenshots.push(name);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);}
  await page.exposeFunction('qaOperations',()=>operations.length);
  await page.addInitScript(()=>{setInterval(async()=>{window.qaOperationCount=await window.qaOperations();},30);});
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
  for(let i=0;i<100;i++)macOutput('original','BURST-'+i+'\nREADY> ');
  await page.waitForFunction(()=>$('terminal-screen').textContent.includes('BURST-99'));assert.equal(await page.evaluate(()=>!!terminalPending),false);
  checks.push('compact controls retain screen and burst rendering retains only latest pending frame');
  await page.locator('#terminal-screen').click();await page.keyboard.type('PHONE-SAME');await count(1);await page.keyboard.press('ArrowLeft');await count(2);await page.keyboard.press('ArrowRight');await count(3);
  assert.deepEqual(operations.slice(0,3).map(input=>[input.sessionID,input.kind]),[['original','characters'],['original','left'],['original','right']]);
  assert.equal(await page.locator('#automatic').isChecked(),true);assert.equal(await page.locator('#terminal-input').isVisible(),false);
  checks.push('phone characters and arrows target original session while automation stays ON');
  const beforeFailure=operations.length;inputDelay=350;failNext=true;await page.keyboard.type('UNCERTAIN');await count(beforeFailure+1);await page.keyboard.type('QUEUED');await page.waitForFunction(()=>!directMode&&!!inputFailure);await page.waitForTimeout(450);
  assert.equal(operations.length,beforeFailure+1);assert.match(await page.locator('#terminal-input').inputValue(),/UNCERTAIN.*QUEUED/);await capture('mobile-uncertain-input');
  checks.push('uncertain input preserves failed/queued text and never replays');
  const beforeStream=requests.stream;await page.evaluate(()=>terminalStream.source.dispatchEvent(new Event('error')));
  await page.waitForFunction(()=>!latestFrame&&$('terminal-retry').hidden===false);await page.waitForTimeout(600);assert.equal(requests.stream,beforeStream);assert.equal(operations.length,beforeFailure+1);
  await capture('mobile-stream-error');await page.locator('#terminal-retry').click();await page.waitForFunction(()=>latestFrame?.sessionID==='original');assert.equal(requests.pty,0);assert.equal(operations.length,beforeFailure+1);
  checks.push('stream failure stops input and explicit retry never forks or replays');
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
    await page.locator('#terminal-screen').click();const before=operations.length,marker='VIEW-'+name;await page.keyboard.type(marker);await count(before+1);await page.waitForFunction(marker=>$('terminal-screen').textContent.includes(marker),marker);
    assert.equal(operations.at(-1).sessionID,'original');assert.equal(await page.locator('#automatic').isChecked(),true);await page.waitForTimeout(150);await capture(name+'-same-terminal');
  }
  checks.push('mobile/tablet/desktop screen taps send directly to the same original with automation ON');
  online=false;await page.evaluate(()=>refreshNetwork());await page.waitForTimeout(100);assert.equal(clients.size,0);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),true);
  online=true;release={version:'0.2.41',build:48,api:1};await page.evaluate(()=>refreshNetwork());await page.evaluate(()=>refreshFrame());await page.waitForFunction(()=>!!latestFrame);assert.ok(requests.poll>0);assert.equal(clients.size,0);assert.equal(requests.pty,0);
  checks.push('disconnect disables original input and older peers retain polling without fork offers');
  sources[0].session.phase='ended';oldCopies.push({...sources[0],session:{...sources[0].session,id:'pty:legacy-copy',pid:4300,tty:'/dev/fixture-copy',phase:'idle'},ptyID:'legacy-copy',pty:{ptyID:'legacy-copy',streamID:'legacy-copy-stream',pid:4300,tty:'/dev/fixture-copy',cwd:'/fixture/copied-terminal',program:'codex',columns:80,rows:24}});
  await page.evaluate(()=>{history.replaceState(null,'','#node=original-mac&session=original&pty=legacy-copy');});await page.reload();await page.locator('.session-row').first().waitFor();await page.waitForTimeout(150);assert.equal(requests.pty,0);assert.equal(await page.locator('#session-count').innerText(),'2개');assert.equal(await page.evaluate(()=>selectedItem),null);
  checks.push('ended source and stale original+copy bookmark never revive, fork, or substitute the copied CLI');
  assert.deepEqual(errors,[]);await writeFile(path.join(output,'report.json'),JSON.stringify({checks,screenshots,errors,requests,macPushLatencyMs:latencies,scope:'Chromium + synthetic original HTTP/SSE fixture; no physical phone or native Mac key delivery'},null,2)+'\n');
  console.log(JSON.stringify({result:'PASS',checks,screenshots,errors,requests,macPushLatencyMs:latencies}));
}catch(error){
  const detail=await page?.evaluate(()=>({key:selectedKey,frame:latestFrame,directMode,directQueue,inputFailure,composeMode,keyboard:document.activeElement?.id,keyboardDisabled:$('terminal-keyboard').disabled,screen:$('terminal-screen').textContent})).catch(()=>null);
  await page?.screenshot({path:path.join(output,'failure.png')}).catch(()=>{});await writeFile(path.join(output,'failure.json'),JSON.stringify({stage,error:error.message,operations,detail},null,2));throw error;
}finally{await browser?.close();for(const client of clients)client.res.end();await new Promise(resolve=>server.close(resolve));}
