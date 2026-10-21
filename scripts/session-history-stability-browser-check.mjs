// Real browsers and product assets; synthetic inventories/receipts only.
// No original session, terminal input, screen capture or system setting is used.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const {chromium,webkit}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const baseline=process.argv.includes('--baseline'),engine=process.argv.includes('--webkit')?'webkit':'chromium';
const assets=path.resolve(process.env.AUTOAPPROVE_QA_ASSETS||'Sources/AutoApproveCore/Resources/RemoteWeb');
const out=path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT||'dist/qa/session-history-stability');
await mkdir(out,{recursive:true});
const release=JSON.parse(await readFile(assets+'/web-version.json','utf8'));
const view=(id,errorID)=>({title:errorID?'지난 합성 세션':'현재 합성 세션',phaseTitle:errorID?'종료':'입력 대기',canRead:false,canApprove:false,canReveal:false,keys:[],
 session:{id,agent:'codex',pid:900001,started:'synthetic-'+id,tty:'/dev/fixture-'+id,cwd:'/fixture/'+id,terminal:'iterm',automatic:false,phase:errorID?'ended':'idle',
 ...(errorID?{interruption:{id:errorID,kind:'transport',detail:'합성 종료 오류',detectedAt:'2026-10-21T00:00:00Z'}}:{})}});
const current=view('current'),past=view('past','error-1');
const localViews=[current],peerViews=[past],ghosts=Array.from({length:8},(_,i)=>'old-mac-'+i);
const node=(id,sessions)=>({id,name:id==='a'?'현재 Mac':'다른 Mac',local:id==='a',online:true,release,
 state:{id,name:id,release,snapshot:{paused:false,events:[]},sessions,historyDeferred:true}});
let sequence=0,failRead=false,holdNext=false,staleStarted,releaseStale,releaseFull,fullGate;
const network=initial=>({fixtureSequence:sequence,updatedAt:new Date().toISOString(),gatewayID:'a',gatewayRelease:release,partial:initial,
 nodes:[node('a',localViews),node('b',peerViews),...ghosts.map(id=>({id,name:'지난 연결 '+id,local:false,online:false,release,...(initial?{loading:true}:{error:'Synthetic offline'})}))]});
const errors=[],checks=[],views=[],coldShifts=[],posts=[];
const server=createServer(async(req,res)=>{
 try{
  const url=new URL(req.url,'http://localhost');
  const json=(value,status=200)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
  if(url.pathname==='/api/network'){
   const initial=url.searchParams.has('initial'),value=network(initial);
   // Freeze the actual earlier representation before waiting for the receipt.
   const body=JSON.stringify(value);
   if(!initial&&fullGate)await fullGate;
   if(!initial&&holdNext){holdNext=false;await new Promise(resolve=>{releaseStale=resolve;staleStarted();});}
   res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(body);return;
  }
  if(req.method==='POST'){
   let body='';for await(const chunk of req)body+=chunk;const value=JSON.parse(body);posts.push(value);
   assert.equal(value.action,'read','No terminal input or automatic approval is permitted');
   if(failRead)return json({error:'합성 저장 실패'},503);
   const target=(url.searchParams.get('node')==='b'?peerViews:localViews).find(v=>v.session.id===value.sessionID);
   assert.equal(target?.session.interruption?.id,value.interruptionID);
   target.session.interruption.acknowledgedAt=new Date().toISOString();return json({message:'오류 확인 상태를 저장했습니다.'});
  }
  if(url.pathname.startsWith('/api/'))return json([]);
  const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(!['index.html','app.js','app.css','favicon.svg'].includes(name)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});
  res.end(await readFile(assets+'/'+name));
 }catch(error){errors.push('fixture: '+error.message);res.writeHead(500);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser,page;
const position=()=>page.evaluate(()=>$('workspace').getBoundingClientRect().top+scrollY);
async function refresh(){sequence++;await page.evaluate(async()=>{clearTimeout(networkTimer);await refreshNetwork();clearTimeout(networkTimer);});}
async function capture(name){await page.screenshot({path:path.join(out,engine+'-'+name+'.png'),fullPage:true});views.push(name);}
try{
 browser=await(engine==='webkit'?webkit:chromium).launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 for(const [label,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  page=await browser.newPage({viewport:{width,height},hasTouch:width<1000});page.setDefaultTimeout(12000);
  page.on('pageerror',error=>errors.push(error.message));
  page.on('console',message=>{if(message.type()==='error'&&!message.text().includes('503'))errors.push('console: '+message.text());});
  fullGate=new Promise(resolve=>releaseFull=resolve);
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.waitForFunction(()=>connected&&nodes.length===10);
  const before=await position();await capture(label+'-initial-pending');
  releaseFull();fullGate=null;
  await page.waitForFunction(()=>!loadingNetwork&&!nodes.some(node=>node.loading));await page.evaluate(()=>clearTimeout(networkTimer));
  const shift=(await position())-before;coldShifts.push(shift);
  if(baseline)assert.ok(Math.abs(shift)>1,'Expected the initial old Mac cards to move the workspace');
  else assert.ok(Math.abs(shift)<1,label+' cold-start layout shift '+shift+'px');
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  await capture(label+'-settled');
  if(label!=='desktop')await page.close();
 }
 checks.push(baseline?'Reproduced cold-start history cards moving the workspace at all three sizes':'Initial pending records and completed offline records keep the workspace at the same position at all three sizes');
 await page.setViewportSize({width:390,height:844});
 const currentRow=page.locator('#session-list .session-row').filter({hasText:'현재 합성 세션'}),handle=await currentRow.elementHandle();
 const started=new Promise(resolve=>staleStarted=resolve);holdNext=true;
 const refreshPending=refresh();await started;
 await page.locator('#interruption-list .interruption-read').click();
 await page.waitForFunction(()=>!interruptionReads.size&&interruptionRows.size===0);
 const clearedTop=await position();assert.equal(await page.locator('#session-list>li').count(),1);
 releaseStale();releaseStale=null;await refreshPending;
 const staleWarnings=await page.locator('#interruption-list>article').count();
 if(baseline){
  assert.equal(staleWarnings,1,'Expected the late response to revive the saved error');
  assert.equal(await page.locator('#session-list>li').count(),2);
 }else{
  assert.equal(staleWarnings,0,'A saved exact error must stay read after a late response');
  assert.equal(await page.locator('#session-list>li').count(),1);
  assert.ok(Math.abs((await position())-clearedTop)<1,'Late response moved the workspace after cleanup');
  assert.ok(await handle.evaluate(el=>el.isConnected));
 }
 await capture('late-response');
 checks.push(baseline?'Reproduced a late response reviving the read ended session and warning':'An inventory started before a successful read cannot revive its ended session or warning');
 if(!baseline){
  for(let i=0;i<6;i++){await currentRow.focus();await refresh();assert.ok(await handle.evaluate(el=>el.isConnected&&document.activeElement===el));assert.equal(await page.locator('#interruption-list>article').count(),0);}
  // Identical session/error IDs on another Mac must remain independent.
  localViews.push(view('past','error-1'));await refresh();assert.equal(await page.locator('#interruption-list>article').count(),1);
  localViews.pop();past.session.interruption={id:'error-2',kind:'transport',detail:'새 합성 오류',detectedAt:'2026-10-21T00:02:00Z'};
  await refresh();assert.equal(await page.locator('#interruption-list>article').count(),1);
  failRead=true;await page.locator('#interruption-list .interruption-read').click();
  await page.waitForFunction(()=>!interruptionReads.size);assert.equal(await page.locator('#interruption-list>article').count(),1);
  assert.equal(past.session.interruption.acknowledgedAt,undefined);failRead=false;
  await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});await capture('mobile-new-error-dark');
  await page.locator('#interruption-list .interruption-read').click();await page.waitForFunction(()=>!interruptionReads.size&&!loadingNetwork);
  await page.evaluate(()=>clearTimeout(networkTimer));assert.equal(await page.locator('#interruption-list>article').count(),0);
  await capture('mobile-cleared-dark');
  checks.push('Repeated refresh preserves row/focus; other Macs and newer error IDs remain visible; save failures keep the alert available for retry');
 }
 assert.deepEqual(errors,[]);
 const report={passed:true,baseline,engine,checks,views,coldShifts,staleWarnings,posts:posts.map(p=>({action:p.action,interruptionID:p.interruptionID})),errors,
  sourceSHA256:createHash('sha256').update(await readFile(assets+'/app.js')).digest('hex'),scope:'Synthetic network and exact product browser assets; no original terminal, input, capture or system settings.'};
 await writeFile(out+'/'+engine+'-report.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}catch(error){await writeFile(out+'/'+engine+'-failure.json',JSON.stringify({error:error.message,errors,checks,views,coldShifts},null,2)+'\n');throw error;}
finally{releaseFull?.();releaseStale?.();await browser?.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
