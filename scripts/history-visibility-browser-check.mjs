// Actual dashboard code in real browsers; only synthetic sessions and read requests.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {gzipSync} from 'node:zlib';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const engine=process.argv.includes('--webkit')?'webkit':'chromium',baseline=process.argv.includes('--baseline');
const out=path.resolve(process.argv.find(arg=>arg.startsWith('--output='))?.slice(9)||'dist/qa/history-visibility');
await mkdir(out,{recursive:true});
const keys=['text','submit','characters','enter','escape','up','down','left','right'];
const views=Array.from({length:20},(_,i)=>({session:{id:'original+'+i+'한글🙂',agent:'codex',pid:8100+i,started:'fixture-'+i,tty:'/dev/fixture-'+i,cwd:'/fixture/history',terminal:'iterm',phase:'idle',automatic:true,queuedQuestions:[]},title:'처리 내역 검증 '+i,canRead:true,canReveal:false,keys}));
let seed=0x3249876;
const request=Array.from({length:360},()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed.toString(16).padStart(8,'0');}).join(' ')+'\n한글 🙂 e\u0301';
const eventsFor=(id,revision=0)=>Array.from({length:12},(_,i)=>({id:id+'-event-'+i,date:'2026-10-16T01:00:00Z',sessionID:id,summary:'합성 승인 기록 '+revision+' / '+i,outcome:'승인 전달 '+revision,source:'QA fixture',request:request+'\n'+i}));
const stats={historyRequests:0,historyBytes:0,historyAborts:0,network:0,posts:0,pty:0},checks=[],errors=[],waiters=new Set(),clients=new Set();
let mode='normal',revision=0,legacy=false,inline=false,empty=false;
const state=()=>({updatedAt:new Date().toISOString(),nodes:[{id:'mac+한글',name:'기록 QA Mac',local:true,online:true,state:{release:{version:legacy?'0.2.60':'0.2.99',build:legacy?75:123,api:1},historyDeferred:!inline,snapshot:{paused:false,events:inline?views.flatMap(view=>eventsFor(view.session.id)):[]},sessions:views}}]});
const server=createServer(async(req,res)=>{
 const url=new URL(req.url,'http://localhost');
 const json=(status,value)=>{const body=Buffer.from(JSON.stringify(value));res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(body);};
 if(req.method!=='GET'){stats.posts++;return json(409,{error:'This check must never write to a terminal'});}
 if(url.pathname==='/api/network'){
  stats.network++;const tag='"history-'+legacy+'-'+inline+'"';
  if(req.headers['if-none-match']===tag){res.writeHead(304,{ETag:tag});return res.end();}
  res.setHeader('ETag',tag);return json(200,state());
 }
 if(url.pathname==='/api/history'||url.pathname==='/api/state'){
  stats.historyRequests++;assert.equal(url.searchParams.get('node'),'mac+한글');
  const id=url.searchParams.get('session')||views[0].session.id;
  assert.ok(views.some(view=>view.session.id===id));
  if(mode==='hold')await new Promise(resolve=>{waiters.add(resolve);res.once('close',()=>{if(!res.writableEnded)stats.historyAborts++;waiters.delete(resolve);resolve();});});
  if(res.destroyed)return;
  if(mode==='error')return json(503,{error:'합성 기록 읽기 실패'});
  const events=empty?[]:eventsFor(id,revision);
  const value=url.pathname==='/api/state'?{snapshot:{events:[...views.flatMap(view=>eventsFor(view.session.id)),...eventsFor('unrelated')]}}:events;
  const body=gzipSync(Buffer.from(JSON.stringify(value)));stats.historyBytes+=body.length;
  res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store','Content-Encoding':'gzip'});return res.end(body);
 }
 if(url.pathname==='/api/terminal/stream'){
  const id=url.searchParams.get('session');res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});res.flushHeaders();
  const emit=()=>res.write('event: screen\ndata: '+JSON.stringify({sessionID:id,streamID:'fixture-'+id,revision:'1',sequence:1,observedAt:new Date().toISOString(),screen:'원본 터미널 · 기록 조회 검증\nREADY> 🙂',keys})+'\n\n');
  emit();const timer=setInterval(emit,1500);clients.add(res);res.once('close',()=>{clearInterval(timer);clients.delete(res);});return;
 }
 if(url.pathname==='/api/terminal')return json(200,{sessionID:url.searchParams.get('session'),streamID:'fixture',revision:'1',observedAt:new Date().toISOString(),screen:'원본 터미널\nREADY>',keys});
 if(url.pathname.startsWith('/api/pty')){stats.pty++;return json(409,{});}
 if(url.pathname.startsWith('/api/'))return json(200,{});
 const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
 if(!['index.html','app.js','app.css','favicon.svg'].includes(name))return json(404,{});
 res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});
 res.end(await readFile(path.join('Sources/AutoApproveCore/Resources/RemoteWeb',name)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));let browser;
const release=()=>{mode='normal';for(const resolve of waiters)resolve();waiters.clear();};
const until=async(test,label)=>{const end=performance.now()+10000;while(!test()){assert.ok(performance.now()<end,label);await new Promise(resolve=>setTimeout(resolve,20));}};
try{
 browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true,isMobile:true});page.setDefaultTimeout(10000);page.on('pageerror',error=>errors.push(error.message));
 const back=async()=>{const compact=page.locator('#terminal-back');await (await compact.isVisible()?compact:page.locator('#back')).click();};
 await page.goto('http://127.0.0.1:'+server.address().port);await page.locator('.session-row').first().click();
 await page.waitForFunction(()=>terminalStream?.sseReady&&latestFrame?.screen.includes('READY>'));
 const started=performance.now();await page.waitForTimeout(13200);
 const focus={milliseconds:Math.round(performance.now()-started),requests:stats.historyRequests,gzipBodyBytes:stats.historyBytes};
 if(!baseline){assert.equal(focus.requests,0);assert.equal(focus.gzipBodyBytes,0);checks.push('13.2 seconds of active terminal focus performs no hidden history requests or body transfers');}
 if(!baseline){
  mode='hold';await page.locator('#terminal-focus').click();await page.locator('#history-section h3').scrollIntoViewIfNeeded();
  await until(()=>stats.historyRequests===1,'Opening history must start exactly one read');
  await page.locator('#history-status').filter({hasText:'불러오는 중'}).waitFor();assert.equal(await page.locator('#history').getAttribute('aria-busy'),'true');
  await page.locator('#history-status').scrollIntoViewIfNeeded();
  await page.screenshot({path:path.join(out,engine+'-loading.png')});
  release();await page.locator('#history details').first().waitFor();assert.equal(await page.locator('#history details').count(),12);
  assert.equal(await page.locator('#history').getAttribute('aria-busy'),'false');checks.push('Opening visible history loads exactly once with loading and completion states; exact Unicode source is retained');
  await page.locator('#history summary').first().click();await page.locator('#history summary').first().focus();
  const requests=stats.historyRequests;
  await page.evaluate(()=>{sessionHistories.get(selectedKey).at=0;void refreshNetwork();});
  await until(()=>stats.historyRequests>requests,'Visible history must remain fresh despite an unchanged network 304');
  await page.waitForFunction(()=>!historyRequest);
  assert.equal(await page.locator('#history details').first().getAttribute('open'),'');
  assert.equal(await page.evaluate(()=>document.activeElement===$('history').querySelector('summary')),true);
  checks.push('Visible history refreshes on network 304 without recreating unchanged rows or losing expanded state and keyboard focus');
  revision=1;await page.evaluate(()=>{sessionHistories.get(selectedKey).at=0;void refreshNetwork();});
  await page.locator('#history summary').first().filter({hasText:'승인 전달 1'}).waitFor();checks.push('A new approval event replaces the visible history on the same original');
  mode='error';await page.evaluate(()=>{sessionHistories.get(selectedKey).at=0;void refreshNetwork();});
  await page.locator('#history-retry').waitFor();assert.ok((await page.locator('#history-status').textContent()).includes('합성 기록 읽기 실패'));
  await page.locator('#history-retry').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,engine+'-error.png')});
  assert.equal(await page.locator('#history details').count(),12);
  empty=true;mode='hold';await page.locator('#history-retry').click();await page.waitForFunction(()=>!!historyRequest);
  assert.equal(await page.locator('#history-retry').isVisible(),false);release();await page.locator('#history-status').filter({hasText:'아직 처리 내역이 없습니다.'}).waitFor();
  assert.equal(await page.locator('#history details').count(),0);empty=false;checks.push('A failed refresh preserves the last records and offers one retry; a successful empty response clears the failure');
  mode='hold';await page.evaluate(()=>{sessionHistories.get(selectedKey).at=0;void refreshNetwork();});await page.waitForFunction(()=>!!historyRequest);
  await page.setViewportSize({width:390,height:350});await page.locator('#session-title').scrollIntoViewIfNeeded();
  await page.waitForFunction(()=>!historyInView&&!historyRequest);
  const offscreen=stats.historyRequests;await page.evaluate(()=>refreshNetwork());assert.equal(stats.historyRequests,offscreen);
  release();await page.setViewportSize({width:390,height:844});await page.locator('#history-section h3').scrollIntoViewIfNeeded();await page.locator('#history details').first().waitFor();
  checks.push('Scrolling history outside the preload margin cancels its pending read; scrolling back reloads records without treating cancellation as a fresh cache');
  mode='hold';await page.evaluate(()=>{sessionHistories.get(selectedKey).at=0;void refreshNetwork();});await page.waitForFunction(()=>!!historyRequest);
  const aborted=stats.historyAborts;await page.locator('#terminal-focus').click();await until(()=>stats.historyAborts>aborted,'Focus mode must cancel the hidden read');
  await page.waitForFunction(()=>!historyRequest);assert.equal(await page.evaluate(()=>[...sessionHistories.values()].some(value=>value.loading)),false);release();
  checks.push('Returning to terminal focus aborts an in-flight history read and clears its pending state');
  // Repeat with a fetch implementation that deliberately ignores AbortSignal.
  await page.evaluate(()=>{const original=window.fetch;window.fetch=(url,options)=>String(url).includes('/api/history')?original(url,{...options,signal:undefined}):original(url,options);});
  mode='hold';await page.locator('#terminal-focus').click();await page.locator('#history-section h3').scrollIntoViewIfNeeded();await page.waitForFunction(()=>!!historyRequest);
  const oldKey=await page.evaluate(()=>selectedKey);
  await back();await page.locator('.session-row').nth(1).click();
  release();await page.waitForTimeout(200);assert.notEqual(await page.evaluate(()=>selectedKey),oldKey);
  assert.equal(await page.evaluate(()=>sessionHistories.get(selectedKey)?.events?.length||0),0);
  checks.push('Late completion from an abandoned original cannot populate the newly selected session even if fetch ignores cancellation');
  // Visit more originals than the cache can retain. No writes or PTYs are used.
  for(let i=1;i<12;i++){
   if(i>1){await back();await page.locator('.session-row').nth(i).click();}
   await page.locator('#terminal-focus').click();await page.locator('#history-section h3').scrollIntoViewIfNeeded();
   await page.locator('#history details').first().waitFor();
   assert.ok((await page.locator('#history details').first().getAttribute('data-id')).startsWith(await page.evaluate(()=>selectedItem.session.id)));
  }
  assert.equal(await page.evaluate(()=>sessionHistories.size),8);assert.ok(await page.evaluate(()=>[...sessionHistories.values()].every(value=>(value.events?.length||0)<=12)));
  checks.push('Switching among many originals retains at most eight histories with twelve matching records each');
  // Backgrounding must cancel, without treating an aborted request as fresh.
  mode='hold';await page.evaluate(()=>{sessionHistories.get(selectedKey).at=0;void refreshNetwork();});await page.waitForFunction(()=>!!historyRequest);
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});
  // This fetch ignores abort by design; the generation guard still drops it.
  await page.waitForFunction(()=>!historyRequest);release();await page.waitForTimeout(100);
  await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));});
  await page.waitForFunction(()=>!historyRequest&&latestFrame);checks.push('Background/foreground invalidates pending history reads and resumes the selected original without writes');
  legacy=true;await page.evaluate(()=>refreshNetwork());await back();await page.locator('.session-row').nth(12).click();
  await page.locator('#terminal-focus').click();await page.locator('#history-section h3').scrollIntoViewIfNeeded();await page.locator('#history details').first().waitFor();
  assert.equal(await page.locator('#history details').count(),12);assert.ok(await page.evaluate(()=>sessionHistories.get(selectedKey).events.every(event=>event.sessionID===selectedItem.session.id)));
  checks.push('An old Mac using full-state history retains only the twelve matching records in the browser');
  inline=true;legacy=false;await page.evaluate(()=>refreshNetwork());await back();await page.locator('.session-row').first().click();
  const beforeInline=stats.historyRequests;await page.locator('#terminal-focus').click();await page.locator('#history-section h3').scrollIntoViewIfNeeded();await page.locator('#history details').first().waitFor();
  assert.equal(stats.historyRequests,beforeInline);checks.push('Inline history from compatible older inventories displays without a separate history request');
  for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
   await page.setViewportSize({width,height});await page.locator('#history-section h3').scrollIntoViewIfNeeded();await page.screenshot({path:path.join(out,engine+'-'+name+'.png')});
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  }
 }
 assert.equal(stats.posts,0);assert.equal(stats.pty,0);assert.deepEqual(errors,[]);
 const report={engine,baseline,focus,checks,stats,errors,scope:'Actual dashboard in real browsers, synthetic originals, gzip bodies; no user inputs, user content, physical phone or VPN fault injection'};
 await writeFile(path.join(out,engine+'.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{release();await browser?.close();for(const res of clients)res.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
