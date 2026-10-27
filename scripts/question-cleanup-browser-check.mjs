// Real browser -> real gateway -> real owner Core, synthetic questions only.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3),engine=process.argv.includes('--webkit')?'webkit':'chromium';
const build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/question-cleanup-198/'+engine),root=await mkdtemp('/private/tmp/aa-question-cleanup-');
await mkdir(out,{recursive:true});const cache=path.resolve('.build/cache/QuestionCleanupPreview');await mkdir(cache,{recursive:true});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));async function until(test,label){const end=Date.now()+20000;while(!await test()){assert.ok(Date.now()<end,label);await wait(30);}}
let fixture,browser,page,closing=false;const errors=[],posts=[],checks=[],views=[],gatewayMode=process.argv.includes('--gateway');
try {
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/question-cleanup-preview.swift','-o',root+'/Preview'],{stdio:'inherit',timeout:180000});
 fixture=spawn(root+'/Preview',[root],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',v=>stderr+=v);
 let ready;await until(async()=>{assert.equal(fixture.exitCode,null,stderr);try{ready=JSON.parse(await readFile(root+'/ready.json','utf8'));return true;}catch{return false;}},'Two Core nodes start');
 const pw=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await pw[engine].launch({headless:true,...(engine==='chromium'?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined}:{})});
 const context=await browser.newContext({viewport:{width:390,height:844},hasTouch:true});
 await context.addInitScript(({node,session})=>{
  if(sessionStorage.getItem('seeded'))return;sessionStorage.setItem('seeded','yes');
  const key=node+'/'+session,deliveries={};for(let i=0;i<100;i++)deliveries[key+'#accepted-'+i]={requestID:'accepted-'+i,nodeID:node,sessionID:session,text:'확인된 합성 메시지 '+i,phase:'accepted'};
  for(const phase of ['uncertain','failed'])deliveries[key+'#'+phase]={requestID:phase,nodeID:node,sessionID:session,text:'유지할 합성 '+phase,phase,receiptSettled:true};
  deliveries['other/session#accepted']={requestID:'other',nodeID:'other',sessionID:'session',text:'다른 세션 기록',phase:'accepted'};
  sessionStorage.setItem('autoapprove-message-drafts-v1',JSON.stringify({drafts:{[key]:'보존할 새 메시지 초안 🙂'},deliveries}));
 },{node:ready.node,session:ready.sessions[0]});
 page=await context.newPage();page.setDefaultTimeout(15000);page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{if(r.method()==='POST'&&new URL(r.url()).pathname!=='/auth/login')posts.push(JSON.parse(r.postData()||'{}'));});
 const second=await browser.newContext({viewport:{width:1440,height:900}}),observer=await second.newPage();observer.on('pageerror',e=>errors.push(e.message));
 const origin=gatewayMode?'https://cleanup.tunnel-qa.invalid':ready.base;
 if(gatewayMode)for(const p of [page,observer])await p.route(origin+'/**',async route=>{
  try {const request=route.request(),url=new URL(request.url()),headers={...request.headers(),host:new URL(origin).host};delete headers['if-none-match'];delete headers.prefer;const response=await route.fetch({url:new URL(url.pathname+url.search,ready.gateway).href,headers});await route.fulfill({response});}catch(error){if(!closing)throw error;}
 });
 await Promise.all([page.goto(origin),observer.goto(origin)]);
 if(gatewayMode)for(const p of [page,observer]){await p.locator('#tunnel-key').fill('001234');await p.locator('#tunnel-login-submit').click();}
 const count=async(p,expected)=>p.waitForFunction(n=>typeof pastQuestionRecords==='function'&&pastQuestionRecords().length===n,expected,{timeout:20000});
 await Promise.all([count(page,150),count(observer,150)]);
 await page.locator('.session-row').filter({hasText:'cleanup-0'}).click();await page.locator('#terminal-questions').click();
 assert.equal(await page.locator('#questions form').count(),2);assert.equal(await page.locator('#past-question-list>li').count(),10);assert.equal(await page.locator('#past-questions').evaluate(e=>e.open),false);
 assert.equal(await page.evaluate(()=>[...messageDeliveries].filter(([k,v])=>k.startsWith(selectedKey+'#')&&v.phase==='accepted').length),20);
 assert.equal(await page.evaluate(()=>[...messageDeliveries.values()].filter(v=>v.phase==='uncertain'||v.phase==='failed').length),2);
 assert.equal(await page.locator('#message-input').inputValue(),'보존할 새 메시지 초안 🙂');
 await page.locator('#past-question-count').scrollIntoViewIfNeeded();await page.screenshot({path:out+'/mobile-past-records.png'});
 checks.push('150 past questions fold into compact records while current and uncertain questions remain; confirmed message archives are bounded to 20 and unknown/failed/drafts survive');
 const current=page.locator('#questions form').filter({hasText:'현재 응답이 필요한 질문 0'});await current.locator('textarea').fill('현재 질문의 미전송 답변');
 await page.locator('#past-question-count').click();await page.locator('#past-question-list').getByRole('button',{name:'답변하기',exact:true}).first().click();
 await page.locator('#questions form').filter({hasText:'지난 합성 질문 0-66'}).locator('textarea').fill('지난 질문에 작성 중인 답변');
 await count(page,149);assert.equal(await page.locator('#questions form').count(),3);
 for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.setViewportSize({width,height});await page.locator('#send-message').scrollIntoViewIfNeeded();
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  const box=await page.locator('#send-message').boundingBox();assert.ok(box.y>=0&&box.y+box.height<=height&&box.height>=44);
  await page.screenshot({path:out+'/'+name+'-drafts.png'});views.push([width,height]);
 }
 checks.push('Review reopens exactly one past editor; current/past drafts remain editable and excluded from cleanup; three viewport composer controls stay reachable');
 await page.setViewportSize({width:390,height:844});await page.keyboard.press('Escape');
 await page.locator(await page.locator('#terminal-back').isVisible() ? '#terminal-back':'#back').click();
 await writeFile(root+'/fail','synthetic failure');await until(async()=>JSON.parse(await readFile(root+'/observed.json','utf8')).fail,'Storage failure enabled');
 await page.locator('#list-cleanup>summary').click();
 for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.locator('#clean-all-past-questions').scrollIntoViewIfNeeded();assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/'+name+'-cleanup-controls.png'});}
 await page.setViewportSize({width:390,height:844});await page.locator('#clean-all-past-questions').focus();await page.keyboard.press('Enter');
 await page.waitForFunction(()=>!questionCleanupBusy&&questionCleanupError.includes('일부'));
 await page.screenshot({path:out+'/mobile-partial-error.png'});
 await Promise.all([count(page,83),count(observer,84)]);assert.equal(posts.filter(p=>p.action==='cleanPastQuestions').length,2);
 checks.push('Real forwarded cleanup commits one session atomically, reports the other session storage failure, and the independent browser sees only confirmed removals');
 await rm(root+'/fail');await until(async()=>!JSON.parse(await readFile(root+'/observed.json','utf8')).fail,'Storage restored');
 await page.locator('#clean-all-past-questions').click();await Promise.all([count(page,0),count(observer,1)]);
 await observer.reload();await count(observer,1);
 await page.locator('.session-row').filter({hasText:'cleanup-0'}).click();await page.locator('#terminal-questions').click();assert.equal(await current.locator('textarea').inputValue(),'현재 질문의 미전송 답변');
 assert.equal(await page.locator('#questions form').filter({hasText:'지난 합성 질문 0-66'}).locator('textarea').inputValue(),'지난 질문에 작성 중인 답변');
 assert.equal(await page.locator('#message-input').inputValue(),'보존할 새 메시지 초안 🙂');
 assert.equal(await page.locator('#past-questions').isVisible(),false);await page.locator('#question-cleanup-undo').click();
 await Promise.all([count(page,83),count(observer,84)]);
 checks.push('Cleanup persists across another browser reload, keeps both question drafts and the message draft, and undo restores only the last confirmed batch');
 const inventory=await(await page.request.get(ready.owner+'/api/inventory')).json(),target=inventory.sessions.find(v=>v.session.id===ready.sessions[1]).session.queuedQuestions.find(q=>q.id==='old-1-0');
 await writeFile(root+'/changed','changed synthetic content');
 await until(async()=>{const s=await(await page.request.get(ready.owner+'/api/inventory')).json();return s.sessions.find(v=>v.session.id===ready.sessions[1]).session.queuedQuestions.find(q=>q.id===target.id)?.cleanupToken!==target.cleanupToken;},'Question content changes');
 const stale=await page.request.post(ready.base+'/api/action?'+new URLSearchParams({node:ready.node}),{data:{action:'cleanPastQuestions',sessionID:ready.sessions[1],questions:[{id:target.id,token:target.cleanupToken}],requestID:crypto.randomUUID()}});assert.equal(stale.status(),409);
 checks.push('A stale client cannot clear a rewritten question with the same ID; node/session/content are validated by the actual owner');
 await page.evaluate(()=>{const original=Storage.prototype.setItem;window.restoreSyntheticStorage=()=>Storage.prototype.setItem=original;Storage.prototype.setItem=function(k,...args){if(k==='autoapprove-message-drafts-v1')throw new DOMException('synthetic quota','QuotaExceededError');return original.call(this,k,...args);};for(let i=0;i<30;i++)messageDeliveries.set(selectedKey+'#extra-'+i,{requestID:'extra-'+i,text:'synthetic confirmed',phase:'accepted'});saveMessageDrafts();});
 assert.equal(await page.evaluate(()=>[...messageDeliveries].filter(([k,v])=>k.startsWith(selectedKey+'#')&&v.phase==='accepted').length),50);
 await page.evaluate(()=>{restoreSyntheticStorage();saveMessageDrafts();updateInteractionControls();});assert.equal(await page.evaluate(()=>[...messageDeliveries].filter(([k,v])=>k.startsWith(selectedKey+'#')&&v.phase==='accepted').length),20);
 checks.push('Automatic message trimming commits to storage before removing memory records; quota failure retains all records and recovery keeps the latest 20');
 await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});await page.locator('#send-message').scrollIntoViewIfNeeded();await page.screenshot({path:out+'/mobile-dark-after.png'});
 assert.ok(posts.every(p=>['cleanPastQuestions','restorePastQuestions'].includes(p.action)));assert.deepEqual(errors,[]);
 const report={passed:true,engine,gatewayMode,checks,views,posts:posts.filter(p=>p.action).map(p=>({action:p.action,questions:p.questions?.length})),errors,scope:'Real browsers and two production Core nodes'+(gatewayMode?' through the actual PIN-authenticated HTTPS gateway origin simulation':' on LAN HTTP')+', synthetic questions/SQLite fault/confirmed messages; no user CLI, account, terminal input or original history changes'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}catch(error){await page?.screenshot({path:out+'/failure.png'}).catch(()=>{});await writeFile(out+'/failure.json',JSON.stringify({error:error.message,checks,errors},null,2));throw error;}
finally{closing=true;await browser?.close();await writeFile(root+'/stop','stop').catch(()=>{});if(fixture){await Promise.race([new Promise(resolve=>fixture.once('exit',resolve)),wait(1000)]);if(fixture.exitCode===null)fixture.kill('SIGTERM');}await rm(root,{recursive:true,force:true});}
