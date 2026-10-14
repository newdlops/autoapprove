// Production Swift HTTP and real Chromium, using only synthetic sessions.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,readdir,rm,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const root=await mkdtemp('/private/tmp/aa-error-read-web-'),out=path.resolve('dist/qa/session-error-read');
await mkdir(out,{recursive:true});await mkdir('.build/cache/SessionErrorRead',{recursive:true});
let fixture,browser,base,page,offline=false,oldVersion=false,failRead=false,holdRead=false,releaseRead,readStarted;
const errors=[],checks=[],views=[],requests=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
try {
  const binary=path.join(root,'fixture');
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/SessionErrorRead'),'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/session-error-read-fixture.swift','-o',binary],{stdio:'inherit'});
  async function start() {
    await rm(path.join(root,'ready.json'),{force:true});
    fixture=spawn(binary,[root],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',value=>stderr+=value);
    let ready;
    for(let i=0;i<400&&!ready;i++) {
      try {ready=JSON.parse(await readFile(path.join(root,'ready.json'),'utf8'));} catch {}
      if(fixture.exitCode!==null)throw Error(stderr);
      if(!ready)await wait(40);
    }
    assert.ok(ready,'fixture startup '+stderr);base='http://127.0.0.1:'+ready.port;return ready;
  }
  async function stop() {const child=fixture;if(child&&child.exitCode===null){const done=new Promise(resolve=>child.once('exit',resolve));child.kill('SIGTERM');await done;}fixture=null;}
  const ready=await start();
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
  page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(15000);
  page.on('pageerror',error=>errors.push(error.message));
  page.on('request',request=>{if(request.method()==='POST')requests.push(request.postDataJSON());});
  await page.route('**/api/network*',async route=>{
    try {
      const response=await route.fetch(),value=await response.json();
      if(offline)value.nodes[0].online=false;
      if(oldVersion)value.nodes[0].state.release={version:'0.2.83',build:107,api:1};
      await route.fulfill({response,json:value});
    } catch {try {await route.abort();} catch {}}
  });
  await page.route('**/api/action*',async route=>{
    const body=route.request().postDataJSON();
    if(body?.action==='read'&&holdRead) {
      await new Promise(resolve=>{releaseRead=resolve;readStarted?.();});
    }
    if(body?.action==='read'&&failRead) {await route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({error:'합성 저장 실패 · 다시 확인해주세요.'})});return;}
    await route.continue();
  });
  const state=async()=>await(await fetch(base+'/api/state')).json();
  const live=async()=> (await state()).sessions.find(value=>value.session.id===ready.live).session;
  const liveRead=()=>page.locator('#interruption-list').getByRole('button',{name:/오류 확인했음/});
  async function refresh(){await page.locator('#refresh').click();await page.waitForFunction(()=>!loadingNetwork);}
  async function capture(name){await page.screenshot({path:path.join(out,name+'.png')});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name+' page overflow');views.push(name);}
  await page.goto(base);await page.waitForFunction(()=>allSessions.length===4);
  assert.equal(await page.locator('#session-list>li').count(),3);
  assert.equal(await page.locator('#interruption-list>article').count(),2);
  assert.equal((await state()).snapshot.events.length,1);
  checks.push('An exact legacy read receipt hides its ended error; two unread errors and the live original stay visible');
  for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]) {
    await page.setViewportSize({width,height});await page.locator('#interruption-list summary').first().click();await capture(name+'-long-errors');await page.locator('#interruption-list summary').first().click();
  }
  await page.setViewportSize({width:390,height:844});holdRead=true;
  const firstRead=new Promise(resolve=>readStarted=resolve);
  const firstButton=page.getByRole('button',{name:/합성 종료 오류 1 오류 확인했음/});
  await firstButton.focus();await page.keyboard.press('Enter');await firstRead;
  assert.equal(await page.getByRole('button',{name:/합성 종료 오류 1 오류 확인했음/}).isDisabled(),true);
  assert.match(await page.getByRole('button',{name:/합성 종료 오류 1 오류 확인했음/}).textContent(),/확인 중/);
  assert.equal(await page.getByRole('button',{name:/합성 종료 오류 2 오류 확인했음/}).isEnabled(),true);
  assert.equal(await page.locator('#refresh').isEnabled(),true);await capture('mobile-saving-receipt');
  holdRead=false;releaseRead();await page.waitForFunction(()=>document.querySelectorAll('#interruption-list>article').length===1);
  await page.waitForFunction(()=>document.querySelectorAll('#session-list>li').length===2);
  assert.equal(await page.evaluate(()=>!!document.activeElement.closest('#interruption-list')),true,'Keyboard focus follows the remaining error after cleanup');
  const saved=(await state()).sessions.find(value=>value.session.interruption?.id==='fixture-error-0').session;
  assert.ok(saved.interruption.acknowledgedAt);assert.equal(saved.interruption.recoveredAt,undefined);
  assert.equal((await state()).snapshot.events.length,1);
  checks.push('Keyboard confirmation saves the exact receipt, exposes pending state, cleans the ended row, preserves history and leaves unrelated controls usable');
  await page.reload();await page.waitForFunction(()=>allSessions.length===4);
  assert.equal(await page.locator('#session-list>li').count(),2);assert.equal(await page.locator('#interruption-list>article').count(),1);
  await page.getByRole('button',{name:/합성 종료 오류 2 세션 보기/}).click();
  await page.waitForFunction(()=>document.querySelector('#session-interruptions').hidden);
  assert.equal(await page.evaluate(()=>selectedItem.session.interruption.recoveredAt==null),true);
  if(await page.locator('#terminal-back').isVisible())await page.locator('#terminal-back').click();else await page.locator('#back').click();
  assert.equal(await page.locator('#session-list>li').count(),1);await capture('mobile-confirmed-errors-cleaned');
  checks.push('Explicitly opening an error also saves its receipt; confirmed errors stay cleaned after browser reload and the active session stays listed');
  await page.goto('about:blank');await stop();await start();await page.goto(base);await page.waitForFunction(()=>allSessions.length===4);
  assert.equal(await page.locator('#session-list>li').count(),1);assert.equal(await page.locator('#session-interruptions').isVisible(),false);
  assert.equal((await state()).snapshot.events.length,1);checks.push('Confirmed ended errors stay cleaned after a real server restart without deleting the audit event');
  await writeFile(path.join(root,'next-error'),'first-live-error');
  for(let i=0;i<100&&!(await live()).interruption;i++)await wait(30);
  await refresh();await page.waitForFunction(()=>document.querySelectorAll('#interruption-list>article').length===1);
  const firstError=(await live()).interruption.id;
  await liveRead().click();await page.waitForFunction(()=>document.querySelector('#session-interruptions').hidden);
  assert.equal(await page.locator('#session-list>li').count(),1);
  assert.equal((await live()).pid,45);assert.equal((await live()).tty,'/dev/ttys999');
  checks.push('Acknowledging a live failure removes its alert while preserving its original session, PID and TTY');
  await writeFile(path.join(root,'next-error'),'second-live-error');
  for(let i=0;i<100&&(await live()).interruption.id===firstError;i++)await wait(30);
  await refresh();await page.waitForFunction(()=>document.querySelectorAll('#interruption-list>article').length===1);
  const secondError=(await live()).interruption.id;assert.notEqual(secondError,firstError);assert.equal((await live()).interruption.acknowledgedAt,undefined);
  holdRead=true;const racedRead=new Promise(resolve=>readStarted=resolve);
  await liveRead().click();await racedRead;
  await writeFile(path.join(root,'next-error'),'third-live-error');
  for(let i=0;i<100&&(await live()).interruption.id===secondError;i++)await wait(30);
  await refresh();holdRead=false;releaseRead();await page.waitForFunction(()=>document.querySelector('#feedback').textContent.includes('오류가 바뀌었습니다'));
  assert.equal((await live()).interruption.acknowledgedAt,undefined);assert.equal(await page.locator('#interruption-list>article').count(),1);
  checks.push('A newer failure reappears; an in-flight read of the previous episode returns 409 and cannot acknowledge the newer error');
  failRead=true;await liveRead().click();await page.waitForFunction(()=>document.querySelector('#feedback').textContent.includes('합성 저장 실패'));
  assert.equal(await page.locator('#interruption-list>article').count(),1);assert.equal((await live()).interruption.acknowledgedAt,undefined);await capture('mobile-save-failure');
  failRead=false;offline=true;await refresh();assert.equal(await liveRead().isDisabled(),true);await capture('mobile-offline-receipt');
  offline=false;oldVersion=true;await refresh();const unsupported=liveRead();assert.equal(await unsupported.isDisabled(),true);assert.match(await unsupported.getAttribute('title'),/0\.2\.84/);
  checks.push('Save failures preserve the alert for retry; offline and older Macs cannot falsely report a saved confirmation');
  oldVersion=false;await refresh();await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});await page.setViewportSize({width:768,height:1024});await capture('tablet-dark-retry');
  await liveRead().click();await page.waitForFunction(()=>document.querySelector('#session-interruptions').hidden);
  assert.equal(await page.locator('#feedback').getAttribute('data-error'),'false');assert.match(await page.locator('#feedback').textContent(),/오류 확인 상태를 저장했습니다/);
  await page.setViewportSize({width:1440,height:900});await capture('desktop-cleaned-live-session');
  assert.equal(await page.locator('#session-list>li').count(),1);assert.equal((await state()).snapshot.events.length,1);
  assert.ok(requests.every(body=>body?.action==='read'),'The browser must not send terminal input, approval or recovery cancellation');assert.deepEqual(errors,[]);
  const report={checks,views,javascriptErrors:errors,onlyReadActions:true,auditPreserved:true};await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
} finally {releaseRead?.();await browser?.close();if(fixture&&fixture.exitCode===null)fixture.kill('SIGTERM');await rm(root,{recursive:true,force:true});}
