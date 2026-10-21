// Real browser/production assets, synthetic network only; never touches a user terminal.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const {chromium,webkit}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const baseline=process.argv.includes('--baseline'),useWebKit=process.argv.includes('--webkit'),engine=useWebKit?'webkit':'chromium';
const out=path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT||'dist/qa/session-list-stability');
const assets=path.resolve(process.env.AUTOAPPROVE_QA_ASSETS||'Sources/AutoApproveCore/Resources/RemoteWeb');
await mkdir(out,{recursive:true});
const release=JSON.parse(await readFile(assets+'/web-version.json','utf8'));
const view=(id,ended=false)=>({title:'합성 세션 '+id,phaseTitle:ended?'종료':'입력 대기',canRead:true,canApprove:false,canReveal:false,keys:[],
 session:{id,agent:'codex',pid:900001,started:'synthetic-'+id,tty:'/dev/fixture-'+id,cwd:'/fixture/'+id,terminal:'iterm',automatic:false,phase:ended?'ended':'idle',
 ...(ended?{interruption:{id:'synthetic-error-'+id,kind:'transport',detail:'합성 종료 기록',detectedAt:'2026-10-21T00:00:00Z'}}:{})}});
const localViews=[view('current'),view('old-local',true)],peerViews=[view('peer'),view('old-peer',true)];
localViews[1].session.interruption.acknowledgedAt='2026-10-21T00:01:00Z';
let sequence=0,pending=false,peer='online',ghostOnline=false,removeGhost=false;
const ghostIDs=Array.from({length:6},(_,index)=>'old-mac-'+index);
const makeNode=(id,online,sessions=[],loading=false)=>({id,name:id==='a'?'현재 합성 Mac':id==='b'?'다른 합성 Mac':'지난 연결 '+id,
 local:id==='a',online,release,...(loading?{loading:true}:{}),
 ...(online?{state:{id,name:id,release,snapshot:{paused:false,events:[]},sessions,historyDeferred:true}}:loading?{}:{error:'Synthetic offline'})});
const network=()=>({fixtureSequence:sequence,gatewayID:'a',gatewayRelease:release,partial:pending||peer==='pending',
 nodes:[makeNode('a',true,localViews),makeNode('b',peer==='online',peerViews,peer==='pending'),
  ...ghostIDs.filter(id=>!removeGhost||id!==ghostIDs[0]).map(id=>makeNode(id,id===ghostIDs[0]&&ghostOnline,[],pending&&!(id===ghostIDs[0]&&ghostOnline))),
  makeNode('new-pending',false,[],true)]});
const errors=[],checks=[],views=[],shifts=[],requests={network:0,notModified:0,posts:0},clients=new Set();
const server=createServer(async(req,res)=>{
 try{
  const url=new URL(req.url,'http://localhost');
  const json=value=>{res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
  if(url.pathname==='/api/network'){
   requests.network++;const value=network(),tag='W/"'+createHash('sha256').update(JSON.stringify(value)).digest('hex')+'"';
   const same=req.headers['if-none-match']===tag;if(same)requests.notModified++;
   res.writeHead(same?304:200,{'Content-Type':'application/json','Cache-Control':'no-store','ETag':tag,'X-AutoApprove-Observed-At':new Date().toISOString()});
   res.end(same?'':JSON.stringify({...value,updatedAt:new Date().toISOString()}));return;
  }
  if(req.method==='POST'){requests.posts++;return json({message:'Synthetic response'});}
  if(url.pathname==='/api/history')return json([]);
  if(url.pathname==='/api/terminal'||url.pathname==='/api/terminal/stream'){
   const frame={sessionID:url.searchParams.get('session'),screen:'합성 원본 출력\nREADY> ',keys:[],revision:'1',sequence:1,streamID:'synthetic-stream',observedAt:new Date().toISOString()};
   if(url.pathname==='/api/terminal')return json(frame);
   res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});res.flushHeaders();
   const send=()=>res.write('event: screen\ndata: '+JSON.stringify({...frame,observedAt:new Date().toISOString()})+'\n\n');
   send();const timer=setInterval(send,500);clients.add(res);res.once('close',()=>{clearInterval(timer);clients.delete(res);});return;
  }
  if(url.pathname.startsWith('/api/'))return json({});
  const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(!['index.html','app.js','app.css','favicon.svg'].includes(name)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});
  res.end(await readFile(assets+'/'+name));
 }catch(error){errors.push('fixture: '+error.message);res.writeHead(500);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser,page;
const snapshot=()=>page.evaluate(()=>({
 main:[...$('machines').children].filter(row=>row.classList.contains('machine')).map(row=>row.querySelector('.machine-name').textContent),
 offline:[...$('offline-machine-list').children].map(row=>row.querySelector('.machine-name').textContent),
 workspaceTop:$('workspace').getBoundingClientRect().top+scrollY,
 interruptionTitle:$('interruption-title').textContent,interruptions:interruptionRows.size,
 sessions:allSessions.map(item=>item.key),rowCount:rows.size,focus:document.activeElement?.className,
 overflow:document.documentElement.scrollWidth>innerWidth
}));
async function refresh({unchanged=false,button=true}={}){
 if(!unchanged)sequence++;
 await page.evaluate(()=>clearTimeout(networkTimer));
 if(button)await page.locator('#refresh').click();
 else await page.evaluate(async()=>{await refreshNetwork();clearTimeout(networkTimer);});
 await page.waitForFunction(value=>!loadingNetwork&&networkValidation.value?.fixtureSequence===value,sequence);
 await page.evaluate(()=>clearTimeout(networkTimer));
}
async function capture(name){
 await page.locator('#feedback').waitFor({state:'hidden',timeout:8000});
 await page.evaluate(()=>{scrollTo(0,0);return new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
 await page.screenshot({path:path.join(out,engine+'-'+name+'.png'),fullPage:true});views.push(name);
}
async function captureVisibleList(name){
 await page.locator('#session-list .session-row').first().scrollIntoViewIfNeeded();
 await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 const rect=await page.locator('#session-list .session-row').first().boundingBox();
 assert.ok(rect&&rect.y>=0&&rect.y<844,'The first session must be in the actual mobile viewport');
 await page.screenshot({path:path.join(out,engine+'-'+name+'.png')});views.push(name);
}
function stablePosition(before,after){const shift=after.workspaceTop-before.workspaceTop;shifts.push(shift);assert.ok(Math.abs(shift)<1,'Workspace shifted '+shift+'px');}
try{
 browser=await(useWebKit?webkit:chromium).launch({headless:true,...(!useWebKit&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true});page.setDefaultTimeout(12000);page.on('pageerror',error=>errors.push(error.message));
 page.on('console',message=>{if(message.type()==='error')errors.push('console: '+message.text());});
 page.on('requestfailed',request=>{if(!new URL(request.url()).pathname.startsWith('/api/'))errors.push('asset: '+request.url());});
 await page.goto('http://127.0.0.1:'+server.address().port);
 await page.waitForFunction(()=>connected&&!loadingNetwork);await page.evaluate(()=>clearTimeout(networkTimer));
 const before=await snapshot();assert.equal(before.offline.length,6);assert.equal(before.interruptions,1);
 await capture('initial');
 pending=true;peer='pending';await refresh();
 const during=await snapshot();
 if(baseline){
  assert.ok(during.main.length>before.main.length,'Expected old offline Macs to jump back into the main layout');
  assert.ok(during.sessions.length>new Set(during.sessions).size,'Expected a retained interruption to duplicate during a pending peer read');
  assert.ok(Math.abs(during.workspaceTop-before.workspaceTop)>100,'Expected the session workspace to shift visibly');
  await capture('reproduced-jump');
  await writeFile(out+'/'+engine+'-baseline.json',JSON.stringify({reproduced:true,before,during,requests,views,errors,sourceSHA256:createHash('sha256').update(await readFile(assets+'/app.js')).digest('hex')},null,2)+'\n');
  console.log(JSON.stringify({baseline:true,reproduced:true,workspaceShift:during.workspaceTop-before.workspaceTop,duplicateEntries:during.sessions.length-new Set(during.sessions).size,views}));
 }else{
  assert.deepEqual(during.main,before.main);assert.deepEqual(during.offline,before.offline);
  stablePosition(before,during);
  assert.equal(during.sessions.length,new Set(during.sessions).size);assert.equal(during.interruptionTitle,'중단된 세션 1개');
  checks.push('Previously offline Macs stay in the collapsed region during refresh; current sessions and interruption count stay unique');
  const row=page.locator('#session-list .session-row').filter({hasText:'합성 세션 old-peer'});
  const handle=await row.elementHandle();await row.focus();
  for(let index=0;index<6;index++){
   await refresh({button:false});const value=await snapshot();
   assert.equal(value.sessions.length,new Set(value.sessions).size);assert.equal(value.interruptionTitle,'중단된 세션 1개');
   stablePosition(before,value);assert.ok(await handle.evaluate(el=>el.isConnected&&document.activeElement===el));
  }
  await refresh({unchanged:true,button:false});assert.ok(requests.notModified>0);
  checks.push('Six partial refreshes and a 304 preserve row identity, keyboard focus, unique records and workspace position');
  await page.locator('#offline-machine-count').click();assert.equal(await page.locator('#offline-machines').evaluate(el=>el.open),true);
  const expanded=await snapshot();await refresh();stablePosition(expanded,await snapshot());
  pending=false;await refresh();stablePosition(expanded,await snapshot());
  pending=true;await refresh();stablePosition(expanded,await snapshot());await capture('expanded-pending');
  await page.locator('#list-cleanup>summary').click();await page.locator('#clean-offline-macs').click();
  await page.waitForFunction(()=>!nodes.some(node=>node.id.startsWith('old-mac-')));await page.evaluate(()=>clearTimeout(networkTimer));
  await page.locator('#restore-cleanup').click();await page.waitForFunction(()=>nodes.some(node=>node.id.startsWith('old-mac-')));await page.evaluate(()=>clearTimeout(networkTimer));
  assert.equal((await snapshot()).offline.length,6);assert.ok(!(await snapshot()).main.some(name=>name.includes('old-mac-')));
  checks.push('Expanded state and cleanup/restore keep confirmed offline placement even while reads remain pending');
  ghostOnline=true;peer='online';pending=false;await refresh();
  assert.equal((await snapshot()).offline.length,5);assert.ok((await snapshot()).main.some(name=>name.includes(ghostIDs[0])));
  removeGhost=true;await refresh();assert.ok(await page.evaluate(()=>![...machineRows.values()].some(row=>row.textContent.includes('old-mac-0'))));
  checks.push('A real online confirmation restores the Mac immediately; source removal frees its DOM record');
  for(const [name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
   await page.setViewportSize({width,height});await page.locator('#offline-machine-count').evaluate(el=>el.parentElement.open=false);
   await page.evaluate(()=>scrollTo(0,0));const stable=await snapshot();pending=true;await refresh();
   const value=await snapshot();stablePosition(stable,value);assert.equal(value.overflow,false);
   await capture(name+'-pending');pending=false;await refresh();
  }
  await page.setViewportSize({width:390,height:844});await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});
  await capture('mobile-dark');
  await captureVisibleList('mobile-dark-list-scrolled');
  await page.emulateMedia({colorScheme:'light',reducedMotion:'reduce'});await captureVisibleList('mobile-list-scrolled');
  await page.locator('#session-list .session-row').filter({hasText:'합성 세션 current'}).click();await page.waitForFunction(()=>latestFrame?.sessionID==='current');
  await page.locator('#terminal-back').click();assert.ok(await page.locator('#session-list').isVisible());
  checks.push('Mobile/tablet/desktop, expanded records, dark/reduced-motion and normal session open/back flow remain usable');
  assert.equal(requests.posts,0);assert.deepEqual(errors,[]);
  await writeFile(out+'/'+engine+'-report.json',JSON.stringify({passed:true,engine,checks,views,requests,errors,workspaceShifts:shifts,maxWorkspaceShift:Math.max(...shifts.map(Math.abs)),sourceSHA256:createHash('sha256').update(await readFile(assets+'/app.js')).digest('hex'),scope:'Synthetic network and production browser UI; no original CLI input, capture or settings.'},null,2)+'\n');
  console.log(JSON.stringify({engine,checks,views,requests,errors,maxWorkspaceShift:Math.max(...shifts.map(Math.abs))}));
 }
}catch(error){await writeFile(out+'/'+engine+'-failure.json',JSON.stringify({error:error.message,state:page?await snapshot().catch(()=>null):null,errors,requests},null,2)+'\n');throw error;}
finally{await browser?.close();for(const response of clients)response.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
