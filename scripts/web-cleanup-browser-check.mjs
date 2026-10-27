// Production web assets with synthetic Macs and messages. No real CLI or LAN.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const {chromium,webkit}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const useWebKit=process.argv.includes('--webkit'),engine=useWebKit?'webkit':'chromium';
const out=path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT || 'dist/qa/web-cleanup');await mkdir(out,{recursive:true});
const assets=path.resolve(process.env.AUTOAPPROVE_QA_ASSETS || 'Sources/AutoApproveCore/Resources/RemoteWeb'),release=JSON.parse(await readFile(assets+'/web-version.json'));
const keys=['characters','submit','message','enter','escape'],clients=new Set(),posts=[],errors=[],checks=[],views=[];
const question=(id,queued)=>({id,threadID:'synthetic-thread',title:(queued?'지난 답변 ':'새 질문 ')+id+(id==='old-0'?' · 긴 한글과 결합문자 e\u0301 🧪 제목 줄바꿈 확인'.repeat(5):''),options:['개발','시험'],...(queued?{reply:{phase:'queued',answer:'합성 답변 '+id,message:'답변을 접수했습니다.',queueID:'queue-'+id}}:{})});
const view=(id,extra={})=>({title:'합성 세션 '+id,phaseTitle:'입력 대기',canApprove:false,canReveal:false,canRead:true,keys,
  session:{id,agent:'codex',pid:id==='s0'?900001:900002,started:'synthetic-original-'+id,tty:'/dev/fixture-'+id,cwd:'/fixture/'+id,terminal:'iterm',phase:'idle',automatic:false,queuedQuestions:[],...extra}});
const risk={kind:'persistence',summary:'합성 자동 실행 등록',evidence:'synthetic-only'};
const safety=id=>({id,risk,phase:'guided',request:'실행하지 않은 합성 요청',message:'안전한 대안을 전달했습니다.'});
const interruption=id=>({id,kind:'transport',detail:'합성 이전 연결 오류',detectedAt:'2026-10-20T01:00:00Z'});
const aViews=[view('s0',{queuedQuestions:[question('pending',false),...Array.from({length:44},(_,i)=>question('old-'+i,true))],systemSafety:safety('risk-1'),notices:[{id:'notice',isSystemSafety:true,isRead:false}]}),view('s1')];
const oldView=view('old-session',{phase:'ended',interruption:interruption('error-1')});
let offline=false,removedGhost=false,holdReceipt=false,receiptResponse,holdMessage=false,messageResponse,notModified=0;
const node=(id,name,online,local,sessions,old=false)=>({id,name,online,local,release:old?{version:'0.2.80',build:100,api:1}:release,
  ...(online?{state:{id,name,release:old?{version:'0.2.80',build:100,api:1}:release,snapshot:{paused:false,events:[]},sessions,historyDeferred:true}}:{error:'합성 연결 끊김'})});
const network=()=>({gatewayID:'a',gatewayRelease:release,nodes:[node('a','현재 합성 Mac',true,true,aViews),node('b','구버전 합성 Mac · 긴 이름 확인',!offline,false,[oldView],true),
  ...(!removedGhost?[node('ghost','서버에서 제거될 합성 Mac',false,false,[])]:[]),{id:'loading',name:'조회 중인 합성 Mac',local:false,online:false,loading:true}]});
const server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://localhost');
  const json=(value,status=200)=>{res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
  if(url.pathname==='/api/network'){
    const value=network(),etag='W/"'+createHash('sha256').update(JSON.stringify(value)).digest('hex')+'"';
    const unchanged=req.headers['if-none-match']===etag;if(unchanged)notModified++;
    res.writeHead(unchanged?304:200,{'Content-Type':'application/json','Cache-Control':'no-store','ETag':etag,'X-AutoApprove-Observed-At':new Date().toISOString()});
    res.end(unchanged?'':JSON.stringify({...value,updatedAt:new Date().toISOString()}));return;
  }
  if(url.pathname==='/api/history')return json([]);
  if(url.pathname==='/api/codex/queue')return json({items:[],threadID:'synthetic-thread'});
  if(url.pathname==='/api/receipt'){
    const value={requestID:url.searchParams.get('request'),phase:'completed',status:200,result:{message:'합성 접수 확인'}};
    if(holdReceipt){receiptResponse=()=>json(value);return;}return json(value);
  }
  if(url.pathname==='/api/terminal' || url.pathname==='/api/terminal/stream'){
    const id=url.searchParams.get('session'),frame={sessionID:id,screen:'합성 원본 터미널\nREADY> ',keys,revision:'1',sequence:1,streamID:'synthetic-'+id,observedAt:new Date().toISOString()};
    if(url.pathname==='/api/terminal')return json(frame);
    res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});res.flushHeaders();
    const send=()=>res.write('event: screen\ndata: '+JSON.stringify({...frame,observedAt:new Date().toISOString()})+'\n\n');send();
    const timer=setInterval(send,1000);clients.add(res);res.once('close',()=>{clearInterval(timer);clients.delete(res);});return;
  }
  if(req.method==='POST'){
    let body='';for await(const part of req)body+=part;const value=JSON.parse(body);posts.push(value);
    if(value.action==='sendMessage' && holdMessage){messageResponse=()=>json({message:'합성 메시지 전달 확인'});return;}
    return json({ok:true,message:'합성 확인'});
  }
  if(url.pathname.startsWith('/api/'))return json({});
  const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(!['index.html','app.js','app.css','favicon.svg'].includes(name)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});res.end(await readFile(assets+'/'+name));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser,page;
try{
  browser=await(useWebKit?webkit:chromium).launch({headless:true,...(!useWebKit&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
  page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true});page.setDefaultTimeout(10000);page.on('pageerror',error=>errors.push(error.message));
  await page.addInitScript(()=>{
    if(sessionStorage.getItem('synthetic-seeded'))return;
    const deliveries={};for(let i=0;i<41;i++)deliveries['a/s0#archive-'+i]={requestID:'archive-'+i,nodeID:'a',sessionID:'s0',text:'지난 합성 메시지 '+i+'\n'+('긴 한글🧪 메시지 '.repeat(8)),phase:i%2?'accepted':'uncertain',receiptSettled:true};
    deliveries['a/s1']={requestID:'other',nodeID:'a',sessionID:'s1',text:'다른 세션 기록',phase:'accepted'};
    sessionStorage.setItem('autoapprove-message-drafts-v1',JSON.stringify({drafts:{'a/s0':'유지할 한글 초안 🧪'},deliveries}));sessionStorage.setItem('synthetic-seeded','true');
  });
  const base='http://127.0.0.1:'+server.address().port;
  async function refresh(){await page.locator('#refresh').click();await page.waitForFunction(()=>!loadingNetwork);}
  async function capture(name){await page.screenshot({path:out+'/'+engine+'-'+name+'.png'});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name+' horizontal overflow');views.push(name);}
  await page.goto(base);await page.waitForFunction(()=>!loadingNetwork && nodes.length===4);
  if(process.argv.includes('--measure-only')) {
    await page.locator('#session-list .session-row').filter({hasText:'합성 세션 s0'}).click();await page.waitForFunction(()=>terminalFrameFresh());await page.locator('#terminal-questions').click();
    const counts=await page.evaluate(()=>({dialogElements:$('interaction-dialog').querySelectorAll('*').length,questionEditors:$('questions').querySelectorAll('form').length,questionTextareas:$('questions').querySelectorAll('textarea').length,questionInputs:$('questions').querySelectorAll('input').length}));
    const report={engine,counts,queuedReplies:44,pendingQuestions:1,scope:'Actual rendered production DOM with identical synthetic fixture; not a CPU or whole-app measurement.'};
    await writeFile(out+'/'+engine+'-dom-counts.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
  } else {
  for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await capture(name+'-list-warnings');}
  await page.setViewportSize({width:390,height:844});
  removedGhost=true;await refresh();assert.equal(await page.locator('#machines .machine').count(),2);assert.equal(await page.locator('#offline-machine-list .machine').count(),1);assert.equal(await page.evaluate(()=>machineRows.has('ghost')),false);
  checks.push('A node removed by the server releases its existing DOM row and map entry');
  const read=page.locator('#interruption-list .interruption-read');assert.equal(await read.textContent(),'표시 정리');
  await page.evaluate(()=>{window.syntheticCleanupSet=Storage.prototype.setItem;Storage.prototype.setItem=function(key,...args){if(key==='autoapprove-web-cleanup-v1')throw new DOMException('synthetic quota','QuotaExceededError');return window.syntheticCleanupSet.call(this,key,...args);};});
  await read.click();assert.equal(await page.locator('#session-interruptions').isVisible(),true);assert.equal(await page.evaluate(()=>cleanup.warnings.size),0);
  await page.evaluate(()=>Storage.prototype.setItem=window.syntheticCleanupSet);
  await read.focus();await page.keyboard.press('Enter');assert.equal(await page.locator('#session-interruptions').isVisible(),false);assert.equal(posts.length,0);
  assert.notEqual(await page.evaluate(()=>document.activeElement.tagName),'BODY');
  await page.reload();await page.waitForFunction(()=>!loadingNetwork);assert.equal(await page.locator('#session-interruptions').isVisible(),false);
  oldView.session.interruption=interruption('error-2');await refresh();assert.equal(await read.count(),1);
  checks.push('Legacy errors clean locally, retain focus, survive reload and do not hide a newer error or send a fake read receipt');
  offline=true;await refresh();assert.equal(await page.locator('#offline-machines').evaluate(el=>el.open),false);await page.locator('#offline-machine-count').click();
  await page.locator('.machine').filter({hasText:'구버전 합성 Mac'}).getByRole('button',{name:/목록에서 정리/}).click();
  await page.waitForFunction(()=>!nodes.some(node=>node.id==='b'));assert.equal(await page.locator('#session-interruptions').isVisible(),false);
  await page.reload();await page.waitForFunction(()=>!loadingNetwork);assert.equal(await page.evaluate(()=>nodes.some(node=>node.id==='b')),false);
  assert.equal(await page.evaluate(()=>nodes.some(node=>node.id==='loading')),true);
  offline=false;await refresh();assert.equal(await page.evaluate(()=>nodes.some(node=>node.id==='b')),true);
  offline=true;await refresh();assert.equal(await page.evaluate(()=>nodes.some(node=>node.id==='b')),true);
  await page.locator('#list-cleanup>summary').click();await page.locator('#clean-offline-macs').click();await page.waitForFunction(()=>!nodes.some(node=>node.id==='b'));
  await refresh();assert.ok(notModified>0);assert.equal(await page.evaluate(()=>nodes.some(node=>node.id==='b')),false);
  await page.locator('#restore-cleanup').click();await page.waitForFunction(()=>nodes.some(node=>node.id==='b'));
  checks.push('Offline Mac cleanup is persistent through 304 and reload; loading/local Macs stay and exact online rediscovery restores its row');
  await page.locator('#clean-warnings').click();assert.equal(await page.locator('#system-safety').isVisible(),false);assert.equal(await page.locator('#session-interruptions').isVisible(),false);
  oldView.session.interruption=interruption('error-after-bulk');aViews[0].session.systemSafety=safety('risk-after-bulk');await refresh();
  await page.locator('#system-safety-list').getByRole('button',{name:'경고 표시 정리',exact:true}).click();assert.equal(await page.locator('#system-safety').isVisible(),false);
  aViews[0].session.systemSafety=safety('risk-2');await refresh();assert.equal(await page.locator('#system-safety').isVisible(),true);
  await page.locator('#session-list .session-row').filter({hasText:'합성 세션 s0'}).click();await page.waitForFunction(()=>terminalFrameFresh());
  await page.locator('#session-safety').getByRole('button',{name:'경고 표시 정리',exact:true}).click();assert.equal(await page.locator('#session-safety').isVisible(),false);
  await page.locator('#terminal-questions').click();assert.equal(await page.locator('#message-input').inputValue(),'유지할 한글 초안 🧪');
  assert.equal(await page.locator('#questions form').count(),1);assert.equal(await page.locator('#past-questions').evaluate(el=>el.open),false);assert.equal(await page.locator('#past-question-list>li').count(),10);
  await page.locator('#past-questions>summary').click();await page.locator('#past-question-list button').first().click();assert.match(await page.locator('#past-question-count').textContent(),/43/);
  await page.locator('#clear-past-questions').click();assert.equal(await page.locator('#past-questions').isVisible(),false);assert.equal(await page.locator('#questions form').count(),1);
  assert.equal(await page.locator('#message-input').inputValue(),'유지할 한글 초안 🧪');
  await page.reload();await page.waitForFunction(()=>!loadingNetwork && terminalFrameFresh());await page.locator('#terminal-questions').click();
  assert.equal(await page.locator('#past-questions').isVisible(),false);assert.equal(await page.locator('#questions form').count(),1);assert.equal(await page.locator('#message-input').inputValue(),'유지할 한글 초안 🧪');
  checks.push('New safety IDs reappear; 44 queued replies use at most 10 compact past records, while the live question and draft remain editable');
  await page.locator('#message-history>summary').click();assert.equal(await page.locator('#message-history-list>li').count(),10);
  await page.locator('#message-history-list button').first().click();assert.equal(await page.evaluate(()=>[...messageDeliveries.keys()].filter(key=>key.startsWith('a/s0#')).length),40);
  await page.locator('#undo-message-cleanup').click();assert.equal(await page.evaluate(()=>[...messageDeliveries.keys()].filter(key=>key.startsWith('a/s0#')).length),41);
  await page.evaluate(()=>{window.syntheticStorageSet=Storage.prototype.setItem;Storage.prototype.setItem=function(key,...args){if(key==='autoapprove-message-drafts-v1')throw new DOMException('synthetic quota','QuotaExceededError');return window.syntheticStorageSet.call(this,key,...args);};});
  await page.locator('#clear-message-history').click();assert.equal(await page.evaluate(()=>[...messageDeliveries.keys()].filter(key=>key.startsWith('a/s0#')).length),41);assert.match(await page.locator('#feedback').textContent(),/保存|저장하지 못/);
  assert.equal(await page.locator('#message-error').isVisible(),true);assert.match(await page.locator('#message-error').textContent(),/기록은 유지/);
  await page.evaluate(()=>Storage.prototype.setItem=window.syntheticStorageSet);
  await page.locator('#clear-message-history').click();assert.equal(await page.locator('#message-history').isVisible(),false);assert.equal(await page.evaluate(()=>messageDeliveries.get('a/s1').text),'다른 세션 기록');
  assert.equal(await page.locator('#message-input').inputValue(),'유지할 한글 초안 🧪');assert.equal(await page.evaluate(()=>document.activeElement.id),'undo-message-cleanup');
  await page.locator('#undo-message-cleanup').click();assert.equal(await page.evaluate(()=>[...messageDeliveries.keys()].filter(key=>key.startsWith('a/s0#')).length),41);
  checks.push('Individual/all message cleanup persists transactionally, can undo, keeps other sessions/drafts, and rolls back a quota failure');
  // Receipt started under the original key; new-message archives it, then cleanup removes it.
  holdReceipt=true;
  await page.evaluate(()=>{const value={requestID:'late-receipt',nodeID:'a',sessionID:'s0',text:'늦게 확인할 합성 메시지',phase:'uncertain'};messageDeliveries.set(selectedKey,value);messageUncertain.add(selectedKey);void checkMessageReceipt(selectedKey,value);updateInteractionControls();});
  await page.waitForFunction(()=>messageReceiptReads.has('late-receipt'));
  await page.locator('#new-message').click();await page.locator('#message-input').fill('새로운 초안은 유지 🧪');
  await page.locator('#message-history-list').getByRole('button',{name:'지난 메시지 기록 정리'}).last().click();
  for(let i=0;i<50&&!receiptResponse;i++)await new Promise(resolve=>setTimeout(resolve,20));assert.ok(receiptResponse);holdReceipt=false;receiptResponse();
  await page.waitForFunction(()=>!messageReceiptReads.has('late-receipt'));assert.equal(await page.evaluate(()=>[...messageDeliveries.values()].some(value=>value.requestID==='late-receipt')),false);
  assert.equal(await page.locator('#message-input').inputValue(),'새로운 초안은 유지 🧪');
  checks.push('A late receipt for a removed archive cannot resurrect it or clear a new draft');
  for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
    await page.setViewportSize({width,height});await page.locator('#message-history').evaluate(el=>el.open=true);
    await page.locator('#message-history-list').evaluate(el=>el.scrollTop=el.scrollHeight);
    await page.locator('#send-message').scrollIntoViewIfNeeded();await capture(name+'-message-records');
    const send=await page.locator('#send-message').boundingBox();assert.ok(send.y>=0 && send.y+send.height<=height && send.height>=44,name+' reachable send');
    assert.ok(await page.locator('#message-history-list').evaluate(el=>el.clientHeight<=121));
  }
  await page.setViewportSize({width:390,height:844});await page.locator('#clear-message-history').click();
  holdMessage=true;await page.locator('#send-message').click();await page.waitForFunction(()=>messageDeliveries.get(selectedKey)?.phase==='busy');
  await page.locator('#undo-message-cleanup').click();assert.equal(await page.evaluate(()=>messageDeliveries.get(selectedKey)?.phase),'busy');
  for(let i=0;i<50&&!messageResponse;i++)await new Promise(resolve=>setTimeout(resolve,20));assert.ok(messageResponse);holdMessage=false;messageResponse();
  await page.waitForFunction(()=>messageDeliveries.get(selectedKey)?.phase==='accepted');
  await page.locator('#clear-message-status').click();assert.equal(await page.evaluate(()=>messageDeliveries.has(selectedKey)),false);
  assert.equal(posts.filter(value=>value.action==='sendMessage').length,1);
  await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});await page.locator('#send-message').scrollIntoViewIfNeeded();await capture('mobile-dark-cleaned');
  assert.ok(posts.every(value=>['read','sendMessage'].includes(value.action)));assert.deepEqual(errors,[]);
  checks.push('Undo cannot overwrite an in-flight message; completed status cleanup sends no additional input');
  await writeFile(out+'/'+engine+'-report.json',JSON.stringify({engine,checks,views,javascriptErrors:errors,notModified,posts:posts.map(value=>({action:value.action,sessionID:value.sessionID})),scope:'Production browser assets and synthetic HTTP; no original terminal input, real browser history cleanup or system settings.'},null,2)+'\n');
  console.log(JSON.stringify({engine,checks,views,javascriptErrors:errors}));
  }
}catch(error){await writeFile(out+'/'+engine+'-failure.json',JSON.stringify({error:error.message,errors,state:page?await page.evaluate(()=>({nodes:nodes.map(node=>node.id),selectedKey,feedback:$('feedback').textContent,messageHistory:$('message-history-summary').textContent})).catch(()=>null):null},null,2));throw error;}
finally{await browser?.close();for(const res of clients)res.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
