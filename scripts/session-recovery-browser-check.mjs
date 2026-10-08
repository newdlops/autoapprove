// Chromium and the production Swift HTTP server; isolated synthetic sessions only.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,rm,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const root=await mkdtemp('/private/tmp/aa-recovery-web-'),out=path.resolve('dist/qa/session-recovery');
await mkdir(out,{recursive:true});await mkdir('.build/cache/SessionRecoveryWeb',{recursive:true});
let fixture,browser;const errors=[],checks=[],views=[],requests=[];
try {
 const binary=path.join(root,'fixture'),objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(f=>f.endsWith('.swift.o')).map(f=>path.join(build,'AutoApproveCore.build',f));
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/SessionRecoveryWeb'),'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/web-interaction-fixture.swift','-o',binary],{stdio:'inherit'});
 fixture=spawn(binary,[root,'--messages-only'],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',v=>stderr+=v);
 let ready;for(let i=0;i<400&&!ready;i++){try{ready=JSON.parse(await readFile(path.join(root,'ready.json'),'utf8'));}catch{}if(fixture.exitCode!==null)throw Error(stderr);if(!ready)await new Promise(r=>setTimeout(r,40));}
 assert.ok(ready,'fixture startup '+stderr);const base='http://127.0.0.1:'+ready.port;
 const dashboard=await(await fetch(base+'/api/network')).json(),own=dashboard.nodes[0],codex=own.state.sessions.find(v=>v.session.agent==='codex');
 const initial=await(await fetch(base+'/api/network?initial=1')).json();assert.equal(initial.partial,true);assert.deepEqual(initial.nodes[0].state.snapshot.events,[]);assert.deepEqual(initial.nodes[0].state.snapshot.sessions,[]);assert.equal(initial.nodes[0].state.sessions.length,2);
 checks.push('Production initial inventory contains session views without duplicated sessions or full audit bodies');
 let ended=false,recovered=false,offline=false,delayFull=true;
 const errorNode='00000000-0000-4000-8000-000000000062';
 function content(source){const value=structuredClone(source);const local=value.nodes[0],view=local.state.sessions.find(v=>v.session.agent==='codex');
  view.session.interruption={id:'synthetic-failure',kind:'transport',detail:'stream disconnected before completion: Transport error: network error: '+('긴 오류 설명 및 주소/검사경로/'.repeat(30)),date:new Date().toISOString(),processEnded:ended,recoveryStatus:ended?'awaiting':undefined,recoveryDetail:ended?'같은 대화의 실행을 확인하고 있습니다. 복구 명령은 다시 보내지 않습니다.':undefined,...(recovered?{recoveredAt:new Date().toISOString(),resumedSessionID:'process:61:synthetic'}:{})};
  view.session.capacityResume={phase:'scheduled',attempt:1,limit:0,deadline:new Date(Date.now()+30000).toISOString(),reason:'연결 오류',message:'이어서 진행하자.'};view.session.phase=ended?'ended':'idle';view.phaseTitle=ended?'오류로 종료됨':'중단 · 자동 이어가기 대기';
  if(recovered){const next=structuredClone(view);next.session.id='process:61:synthetic';next.session.pid=61;next.session.phase='working';delete next.session.interruption;delete next.session.capacityResume;next.phaseTitle='작업 중';local.state.sessions.push(next);}
  value.nodes.push({id:errorNode,name:'합성 다른 Mac · 긴 이름과 이더넷/Wi-Fi 연결 상태',local:false,online:!offline,release:{version:'0.2.59',build:74,api:1},...(offline?{error:'합성 연결 끊김'}:{state:{...structuredClone(local.state),id:errorNode,name:'합성 다른 Mac',release:{version:'0.2.59',build:74,api:1},sessions:[]}})});
  value.nodes.push({id:'00000000-0000-4000-8000-000000000063',name:'버전 정보가 없는 이전 Mac',local:false,online:false});return value;}
 browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
 const page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>requests.push(new URL(r.url()).pathname));
 await page.route('**/api/network*',async route=>{const response=await route.fetch(),value=await response.json();if(delayFull&&!new URL(route.request().url()).searchParams.has('initial'))await new Promise(r=>setTimeout(r,2400));await route.fulfill({response,json:content(value)});});
 const started=performance.now();await page.goto(base,{waitUntil:'domcontentloaded'});await page.waitForFunction(()=>document.querySelectorAll('#session-list>li').length>=2);const firstListMs=Math.round(performance.now()-started);
 assert.ok(firstListMs<1800,'Initial list must precede the 2400ms full network delay: '+firstListMs);assert.equal(requests.some(r=>r.startsWith('/vendor/xterm')||r==='/pty.js'),false);delayFull=false;
 assert.match(await page.locator('#machines').textContent(),/v0\.2\.61.*빌드 76/);assert.match(await page.locator('#machines').textContent(),/v0\.2\.59.*빌드 74/);assert.match(await page.locator('#machines').textContent(),/버전 미확인/);
 checks.push('Cold list appears before a delayed full network read; PTY libraries are absent until needed; each Mac exposes its own version');
 async function capture(name){await page.screenshot({path:path.join(out,name+'.png')});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name+' overflow');views.push(name);}
 for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.setViewportSize({width,height});if(await page.locator('#terminal-back').isVisible())await page.locator('#terminal-back').click();else if(await page.locator('#back').isVisible())await page.locator('#back').click();
  await page.locator('#interruption-list details summary').click();await capture(name+'-error-list');await page.locator('#interruption-list button').first().click();assert.equal(await page.evaluate(()=>selectedItem.session.id),codex.session.id);await capture(name+'-selected-error');
 }
 await page.setViewportSize({width:390,height:844});if(await page.locator('#terminal-focus').getAttribute('aria-pressed')==='true')await page.locator('#terminal-focus').click();ended=true;await page.locator('#refresh').click();await page.waitForFunction(()=>selectedItem.session.phase==='ended');await capture('mobile-ended-awaiting');assert.equal(await page.locator('#automatic').isDisabled(),true);
 checks.push('Failure details wrap, View session selects the exact session, and ended CLI controls are disabled');
 recovered=true;await page.locator('#refresh').click();await page.waitForFunction(()=>selectedItem?.session.id==='process:61:synthetic');assert.equal(await page.locator('#terminal-input').inputValue(),'');checks.push('Same-conversation recovery follows the verified new session without copying or replaying an old input draft');
 if(await page.locator('#terminal-focus').getAttribute('aria-pressed')==='true')await page.locator('#terminal-focus').click();offline=true;await page.locator('#refresh').click();await page.waitForFunction(()=>nodes.some(n=>n.id==='00000000-0000-4000-8000-000000000062'&&!n.online));assert.match(await page.locator('#machines').textContent(),/마지막 확인 · v0\.2\.59/);
 await page.locator('#back').click();await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});await capture('mobile-dark-reduced-motion');
 await page.locator('#new-pty').click();await page.locator('#pty-directory').fill('/private/tmp');await page.locator('#pty-program').selectOption('shell');await page.locator('#start-pty').click();await page.waitForFunction(()=>ptyClient?.ready===true);assert.ok(requests.includes('/vendor/xterm.js')&&requests.includes('/pty.js'));await capture('mobile-lazy-pty');
 page.once('dialog',dialog=>dialog.accept());await page.locator('#terminal-settings>summary').click();await page.locator('#close-pty').click();await page.waitForFunction(()=>selectedItem?.view.pty?.closed===true||selectedItem?.view.pty?.exitCode!=null);
 checks.push('Lazy PTY assets load on the first explicit new terminal and its isolated shell can be closed');
 assert.deepEqual(errors,[]);const report={checks,views,javascriptErrors:errors,firstListMs,delayedFullNetworkMs:2400};await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
}finally{await browser?.close();fixture?.kill('SIGTERM');await rm(root,{recursive:true,force:true});}
