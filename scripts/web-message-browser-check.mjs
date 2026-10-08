// Real Chromium and production Swift HTTP; every CLI and input is synthetic.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const directory=await mkdtemp(path.join(tmpdir(),'aa-web-message-')),output=path.resolve('dist/qa/web-message');
await mkdir(output,{recursive:true});
let fixture,browser,page;const errors=[],checks=[],posts=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const file=async name=>{try{return await readFile(path.join(directory,name),'utf8');}catch{return '';}};
const routes=async()=> (await file('message-routes.jsonl')).trim().split('\n').filter(Boolean).map(JSON.parse);
try {
  const cache=path.resolve('.build/cache/WebMessageFixture');await mkdir(cache,{recursive:true});
  const binary=path.join(directory,'WebMessageFixture');
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/web-interaction-fixture.swift','-o',binary],{stdio:'inherit'});
  fixture=spawn(binary,[directory,'--messages-only'],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',part=>stderr+=part);
  let ready;for(let i=0;i<375&&!ready;i++){try{ready=JSON.parse(await file('ready.json'));}catch{}if(fixture.exitCode!==null)throw Error(stderr);if(!ready)await wait(40);}
  assert.ok(ready,'Fixture not ready: '+stderr);const base='http://127.0.0.1:'+ready.port;
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
  page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(15000);
  page.on('pageerror',error=>errors.push(error.message));page.on('request',request=>{if(request.method()==='POST'&&new URL(request.url()).pathname==='/api/action')posts.push(request.postDataJSON());});
  await page.goto(base);await page.waitForFunction(()=>allSessions.length===2);
  async function select(agent){if(await page.locator('#interaction-dialog').evaluate(dialog=>dialog.open))await page.locator('#close-interaction').click();if(await page.locator('body').evaluate(body=>body.classList.contains('detail-open'))){const back=await page.locator('#terminal-back').isVisible()?page.locator('#terminal-back'):page.locator('#back');await back.click();}await page.locator('#session-list button').filter({hasText:agent}).click();await page.waitForFunction(()=>terminalFrameFresh());await page.locator('#terminal-questions').click();}
  async function send(text){await page.locator('#message-input').fill(text);await page.waitForFunction(()=>!$('send-message').disabled);await page.locator('#send-message').click();}
  async function accepted(){await page.waitForFunction(()=>messageDeliveries.get(selectedKey)?.phase==='accepted');}
  async function capture(name){await page.screenshot({path:path.join(output,name+'.png')});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name+' overflow');}
  await select('Codex');await page.locator('#queue-error').waitFor({state:'visible'});
  const multiline='대화 기록 없이 원본에 보내는 한글🧪\n두 번째 줄도 그대로 전달합니다.';
  await send(multiline);await accepted();assert.equal((await routes()).filter(row=>row.text===multiline).length,1);assert.equal((await routes()).find(row=>row.text===multiline).pid,41);
  assert.equal(await file('messages.txt'),'','A missing queue binding must not route into a guessed conversation');
  checks.push('Codex without rollout/queue binding sends multiline Unicode to its exact original CLI once');
  const draft='갱신해도 보관하는 새 메시지 · 한글🧪';await page.locator('#message-input').fill(draft);await page.reload();await page.waitForFunction(()=>terminalFrameFresh());await page.locator('#terminal-questions').click();assert.equal(await page.locator('#message-input').inputValue(),draft);
  checks.push('Unsent draft survives a real page reload');
  const slow='Codex 전달 응답을 기다리는 메시지';
  await page.route('**/api/action**',async route=>{if(route.request().postDataJSON().text===slow){const response=await route.fetch();await wait(2500);return route.fulfill({response});}return route.continue();});
  await send(slow);await select('Claude Code');assert.equal(await page.locator('#message-input').inputValue(),'');assert.equal(await page.locator('#message-status').textContent(),'');
  const claude='다른 세션 응답을 기다리는 동안 Claude로 전달';await send(claude);await accepted();await wait(2700);await page.unroute('**/api/action**');
  assert.equal((await routes()).filter(row=>row.text===slow&&row.pid===41).length,1);assert.equal((await routes()).filter(row=>row.text===claude&&row.pid===51).length,1);
  checks.push('Two sessions submit independently and neither draft, result nor target leaks into the other session');
  const lost='응답이 유실돼도 접수 결과로 복구 · 한글🧪';
  await page.route('**/api/action**',async route=>{if(route.request().postDataJSON().text===lost){await route.fetch();return route.abort('failed');}return route.continue();});
  await send(lost);await accepted();await page.unroute('**/api/action**');assert.equal((await routes()).filter(row=>row.text===lost).length,1);assert.equal(posts.filter(row=>row.text===lost).length,1);
  checks.push('Lost HTTP acknowledgement is reconciled by a read-only durable receipt; the POST is never replayed');
  await writeFile(path.join(directory,'message-preflight-failure'),'');const retry='전송 전 화면 충돌 뒤 다시 보내는 메시지';await send(retry);await page.waitForFunction(()=>messageDeliveries.get(selectedKey)?.phase==='failed');assert.equal(await page.locator('#message-input').inputValue(),retry);assert.equal(await page.locator('#message-input').isDisabled(),false);assert.equal((await routes()).filter(row=>row.text===retry).length,0);
  for(const [label,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await capture(label+'-preflight-failure');}
  await rm(path.join(directory,'message-preflight-failure'));await page.locator('#send-message').click();await accepted();assert.equal((await routes()).filter(row=>row.text===retry).length,1);
  checks.push('Proven preflight refusal preserves an editable draft and permits a single explicit retry after reconnection');
  await page.setViewportSize({width:390,height:844});const missing='기록에 보관할 접수 결과 미확인 메시지';await page.route('**/api/action**',route=>route.request().postDataJSON().text===missing?route.abort('failed'):route.continue());await send(missing);await page.waitForFunction(()=>messageDeliveries.get(selectedKey)?.phase==='uncertain');await page.locator('#new-message').click();await page.locator('#message-history summary').click();assert.match(await page.locator('#message-history').textContent(),/기록에 보관할 접수 결과 미확인 메시지/);assert.equal((await routes()).filter(row=>row.text===missing).length,0);await page.unroute('**/api/action**');
  for(const [label,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await capture(label+'-retained-history');}
  checks.push('Explicit new message keeps the prior uncertain text and status visible in history');
  assert.deepEqual(errors,[]);await writeFile(path.join(output,'report.json'),JSON.stringify({checks,errors,posts:posts.map(({requestID,sessionID,transport})=>({requestID,sessionID,transport})),viewports:[[390,844],[768,1024],[1440,900]]},null,2));console.log(JSON.stringify({result:'PASS',checks,errors},null,2));
} catch(error){await writeFile(path.join(output,'failure.json'),JSON.stringify({error:error.message,errors,state:page?await page.evaluate(()=>({selectedKey,deliveries:[...messageDeliveries],help:$('message-help').textContent,error:$('message-error').textContent})).catch(()=>null):null},null,2));throw error;}
finally{if(browser)await browser.close();if(fixture&&fixture.exitCode===null)fixture.kill('SIGTERM');await rm(directory,{recursive:true,force:true});}
