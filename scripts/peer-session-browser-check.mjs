// Two browser origins and synthetic originals; no user CLI or external network.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const baseline=process.argv.includes('--baseline'),out=path.resolve('dist/qa/peer-session');await mkdir(out,{recursive:true});
const release=JSON.parse(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/web-version.json','utf8'));
const keys=['text','submit','characters','backspace','enter','left','right','up','down','tab','escape','interrupt'];
const ids=['a','b'],pending=new Set(),offline=new Set(),removed=new Set(),blocked=new Set(),delays=new Map(),clients=new Set(),timers=new Set();
const views=new Map(ids.map(owner=>[owner,[1,2].map(index=>({title:`검증 원본 ${owner.toUpperCase()} ${index}`,phaseTitle:'입력 대기',canRead:true,canReveal:false,canApprove:false,keys,
 session:{id:`${owner}-${index}`,agent:index===1?'codex':'claude',pid:8100+ids.indexOf(owner)*10+index,started:`original-${owner}-${index}`,tty:`/dev/fixture-${owner}-${index}`,cwd:`/fixture/${owner}`,terminal:'iterm',phase:'idle',automatic:false,queuedQuestions:[]}}))]));
const frames=new Map([...views.values()].flat().map(view=>[view.session.id,{sessionID:view.session.id,revision:'1',sequence:1,streamID:'original-'+view.session.id,screen:'검증 원본 화면 '+view.session.id+'\nREADY> ',keys,observedAt:new Date().toISOString()}]));
const posts=[],errors=[],fixtureErrors=[],checks=[],screenshots=[],counts={streams:0,polls:0};let activeReads=0,peakReads=0;
const state=gateway=>({gatewayID:gateway,gatewayRelease:release,updatedAt:new Date().toISOString(),partial:pending.size>0,nodes:ids.map(id=>{
 const base={id,name:id==='a'?'검증 Mac A':'길고 긴 표시 이름의 검증 Mac B',local:id===gateway,online:true,release};
 if(id!==gateway&&pending.has(id))return {...base,online:false,loading:true};
 if(id!==gateway&&offline.has(id))return {...base,online:false,error:'Synthetic inventory read timed out'};
 const port=servers[ids.indexOf(id)].address().port;
 return {...base,state:{id,name:base.name,release,webURLs:['http://127.0.0.1:'+port],webPort:port,snapshot:{paused:false,events:[]},historyDeferred:true,sessions:views.get(id).filter(view=>!removed.has(view.session.id))}};
})});
const servers=ids.map(gateway=>createServer(async(req,res)=>{
 const url=new URL(req.url,'http://localhost'),json=(status,value)=>{if(!res.destroyed){res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));}};
 try {
 if(url.pathname==='/api/network')return json(200,state(gateway));
 if(url.pathname==='/api/history')return json(200,[]);
 const owner=url.searchParams.get('node')||gateway,id=url.searchParams.get('session');
 if(url.pathname==='/api/terminal/stream'||url.pathname==='/api/terminal'){
  if(!views.get(owner)?.some(view=>view.session.id===id)||removed.has(id))return json(404,{error:'Synthetic original ended'});
  if(blocked.has(owner))return json(503,{error:'Synthetic original transport temporarily unavailable'});
  if(url.pathname==='/api/terminal'){
   counts.polls++;activeReads++;peakReads=Math.max(peakReads,activeReads);let finished=false;
   const done=()=>{if(!finished){finished=true;activeReads--;}};res.on('close',done);
   await new Promise(resolve=>setTimeout(resolve,delays.get(owner)||0));done();return json(200,frames.get(id));
  }
  counts.streams++;res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});res.flushHeaders();
  const client={gateway,owner,id,res};clients.add(client);
  const send=()=>{if(!res.destroyed)res.write('event: screen\ndata: '+JSON.stringify(frames.get(id))+'\n\n');};
  const first=setTimeout(()=>{timers.delete(first);send();const interval=setInterval(send,250);timers.add(interval);client.interval=interval;},delays.get(owner)||0);timers.add(first);
  res.on('close',()=>{clearTimeout(first);clearInterval(client.interval);timers.delete(first);timers.delete(client.interval);clients.delete(client);});return;
 }
 if(req.method==='POST'){
  let body='';for await(const part of req)body+=part;const payload=JSON.parse(body);
  posts.push({gateway,node:owner,path:url.pathname,...payload});
  assert.ok(views.get(owner)?.some(view=>view.session.id===payload.sessionID));
  if(payload.relay)assert.equal(payload.streamID,frames.get(payload.sessionID).streamID);
  else assert.equal(payload.revision,frames.get(payload.sessionID).revision);
  return json(200,{message:'Synthetic input received'});
 }
 if(url.pathname.startsWith('/api/'))return json(200,{});
 const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
 if(name==='index.html'&&url.searchParams.has('webNode')&&url.searchParams.get('webNode')!==gateway)return json(409,{error:'Synthetic owner changed'});
 if(!['index.html','app.js','app.css','favicon.svg'].includes(name))return json(404,{error:'not found'});
 res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});res.end(await readFile(path.resolve('Sources/AutoApproveCore/Resources/RemoteWeb',name)));
 } catch(error) {fixtureErrors.push(error.message);json(500,{error:error.message});}
}));
for(const server of servers)await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
try{
 browser=await chromium.launch({headless:true,...(process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 for(const [gatewayIndex,gateway] of ids.entries()){
  const remote=ids.find(id=>id!==gateway),session=remote+'-1';pending.clear();offline.clear();removed.clear();delays.clear();delays.set(remote,1800);
  const page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true,isMobile:true});page.setDefaultTimeout(7000);page.on('pageerror',error=>errors.push(error.message));
  await page.goto('http://127.0.0.1:'+servers[gatewayIndex].address().port);await page.getByRole('button',{name:new RegExp('검증 원본 '+remote.toUpperCase()+' 1')}).click();
  await page.waitForFunction(id=>terminalStream?.sessionID===id&&!latestFrame,session);
  pending.add(remote);await page.evaluate(()=>refreshNetwork());
  const retained=await page.evaluate(id=>!!terminalStream&&terminalStream.sessionID===id&&allSessions.filter(item=>item.node.id===id[0]).length===2,session);
  if(baseline){assert.equal(retained,false,'Expected to reproduce the pre-fix pending-inventory disconnect');await page.screenshot({path:path.join(out,'baseline-disconnect.png')});checks.push('Reproduced: pending peer inventory cancels the original before its first frame');await page.close();break;}
  assert.equal(retained,true,'Pending peer inventory must preserve its sessions and original read subscription before the first frame');
  await page.waitForFunction(id=>latestFrame?.sessionID===id,session);delays.set(remote,0);
  checks.push(gateway+' → '+remote+': initial read survives partial inventory without changing owner');
  const frame=frames.get(session);frame.screen='새 원본 출력 '+session+'\nREADY> ';frame.sequence++;frame.revision=String(frame.sequence);
  await page.waitForFunction(()=>$('terminal-screen').textContent.includes('새 원본 출력'));
  await page.evaluate(()=>{$('terminal-settings').open=true;});await page.locator('#compose-input').check();await page.locator('#terminal-input').fill('보존할 원본 초안 한글 🙂');
  await page.evaluate(()=>refreshNetwork());assert.equal(await page.locator('#terminal-input').inputValue(),'보존할 원본 초안 한글 🙂');
  assert.equal(await page.locator('.session-row').count(),4);assert.equal(await page.locator('#session-ended').isVisible(),false);
  const target=new URL(await page.locator('#terminal-direct-page').getAttribute('href'));assert.equal(target.searchParams.get('webNode'),remote);
  assert.equal(new URLSearchParams(target.hash.slice(1)).get('session'),session);
  const [popup]=await Promise.all([page.waitForEvent('popup'),page.locator('#terminal-direct-page').click()]);
  popup.on('pageerror',error=>errors.push(error.message));await popup.waitForLoadState('domcontentloaded');
  await popup.waitForFunction(id=>latestFrame?.sessionID===id&&selectedItem.node.local,session);
  assert.equal(await popup.evaluate(()=>selectedItem.node.id),remote);assert.equal(posts.length,gatewayIndex);await popup.close();
  const mismatch=new URL(target);mismatch.searchParams.set('webNode','wrong-owner');assert.equal((await page.request.get(mismatch.href)).status(),409);
  assert.equal(await page.locator('#terminal-input').inputValue(),'보존할 원본 초안 한글 🙂');
  checks.push(gateway+' → '+remote+': direct original page verifies owner and same session while leaving the draft in its first tab');
  const invalid=await page.evaluate(()=>['https://10.70.212.6:8765/','http://8.8.8.8:8765/','http://user:password@10.70.212.6:8765/','javascript:alert(1)','http://127.0.0.1:8765/'].map(address=>originalPageURL({...selectedItem,node:{...selectedItem.node,local:false,state:{...selectedItem.node.state,webURLs:[address],webPort:8765}}},'http://10.70.212.30:8765/')));
  assert.ok(invalid.every(value=>value===null));
  await page.evaluate(()=>terminalFocus(false));await page.screenshot({path:path.join(out,gateway+'-pending-inventory.png')});screenshots.push(gateway+'-pending');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  pending.delete(remote);offline.add(remote);await page.evaluate(()=>refreshNetwork());
  assert.equal(await page.evaluate(()=>latestFrame?.sessionID),session);assert.equal(await page.locator('#session-ended').isVisible(),false);
  assert.equal(await page.locator('#terminal-input').inputValue(),'보존할 원본 초안 한글 🙂');assert.equal(posts.length,gatewayIndex);
  checks.push(gateway+' → '+remote+': independent original and draft survive pending/failed inventory; no input replay');
  for(const [name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
   await page.setViewportSize({width,height});await page.screenshot({path:path.join(out,gateway+'-'+name+'-inventory-outage.png')});screenshots.push(gateway+'-'+name);
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  }
  await page.locator('#terminal-direct-page').focus();offline.delete(remote);await page.evaluate(()=>refreshNetwork());
  assert.equal(await page.evaluate(()=>document.activeElement===$('terminal-direct-page')&&!$('terminal-direct-page').hidden),true,'Recovery must not remove a keyboard-focused navigation link');
  await page.locator('#send-input').click();await page.waitForFunction(()=>!inputInFlight);
  assert.equal(posts.length,gatewayIndex+1);assert.equal(posts.at(-1).node,remote);assert.equal(posts.at(-1).sessionID,session);
  checks.push(gateway+' → '+remote+': one explicit input reaches the exact original after recovery');
  removed.add(session);await page.waitForFunction(()=>!loadingNetwork);await page.evaluate(()=>refreshNetwork());assert.equal(await page.evaluate(()=>terminalStream),null);assert.equal(await page.evaluate(()=>$('session-ended').hidden),false);
  assert.match(await page.locator('#terminal-live').textContent(),/세션 종료/);
  assert.equal(await page.locator('#session-phase').textContent(),'종료');
  checks.push(gateway+' → '+remote+': confirmed online session removal still terminates the read');
  assert.equal(await page.locator('#terminal-direct-page').isVisible(),false);await page.locator('#session-ended').scrollIntoViewIfNeeded();
  await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});await page.screenshot({path:path.join(out,gateway+'-ended-dark.png')});screenshots.push(gateway+'-ended-dark');
  const next=remote+'-2';blocked.add(remote);
  await page.getByRole('button',{name:new RegExp('검증 원본 '+remote.toUpperCase()+' 2')}).click();
  await page.waitForFunction(()=>terminalStream?.pollFailures>0);
  pending.add(remote);await page.waitForFunction(()=>!loadingNetwork);await page.evaluate(()=>refreshNetwork());
  assert.equal(await page.evaluate(()=>latestFrame),null);assert.match(await page.locator('#terminal-live').textContent(),/첫 화면 연결 지연/);
  assert.equal(await page.locator('#terminal-direct-page').isVisible(),true);assert.equal(posts.length,gatewayIndex+1);
  await page.setViewportSize({width:390,height:844});await page.evaluate(()=>terminalFocus(true));await page.screenshot({path:path.join(out,gateway+'-first-frame-outage.png')});screenshots.push(gateway+'-first-outage');
  blocked.delete(remote);pending.delete(remote);
  await page.waitForFunction(id=>latestFrame?.sessionID===id,next);assert.equal(posts.length,gatewayIndex+1);
  checks.push(gateway+' → '+remote+': failed first terminal read survives pending inventory, exposes direct recovery and resumes without input');
  await page.close();
 }
 assert.deepEqual(errors,[]);assert.deepEqual(fixtureErrors,[]);assert.ok(peakReads<=2);
 const report={baseline,result:'PASS',checks,screenshots,counts,peakReads,inputPOSTs:posts.length,errors,scope:'Two actual browser origins with synthetic inventory, original HTTP/SSE and explicit input; no user sessions'};
 await writeFile(path.join(out,baseline?'baseline-report.json':'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{
 await browser?.close();for(const timer of timers){clearTimeout(timer);clearInterval(timer);}for(const client of clients)client.res.destroy();
 for(const server of servers){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
}
