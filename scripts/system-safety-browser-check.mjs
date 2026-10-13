// Real production HTTP, hook decisions and screen routing with isolated synthetic CLIs.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const root=await mkdtemp('/private/tmp/aa-system-safety-web-'),out=path.resolve('dist/qa/system-safety');
await mkdir(out,{recursive:true});await mkdir('.build/cache/SystemSafetyWeb',{recursive:true});
let fixture,browser;const errors=[],checks=[],views=[];
const optional=async name=>{try{return await readFile(path.join(root,name),'utf8');}catch{return '';}};
try {
 const binary=path.join(root,'fixture'),objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(f=>f.endsWith('.swift.o')).map(f=>path.join(build,'AutoApproveCore.build',f));
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/SystemSafetyWeb'),'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/system-safety-fixture.swift','-o',binary],{stdio:'inherit'});
 fixture=spawn(binary,[root],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',data=>stderr+=data);
 let ready;for(let i=0;i<300&&!ready;i++){try{ready=JSON.parse(await readFile(path.join(root,'ready.json'),'utf8'));}catch{}if(fixture.exitCode!==null)throw Error(stderr);if(!ready)await new Promise(r=>setTimeout(r,40));}
 assert.ok(ready,'fixture startup '+stderr);const base='http://127.0.0.1:'+ready.port;
 browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
 const page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
 await page.goto(base);await page.waitForFunction(()=>allSessions.length===2);
 assert.equal(await page.locator('#system-safety').isVisible(),true);
 assert.match(await page.locator('#system-safety-title').textContent(),/시스템 변경 경고/);
 assert.equal(await optional('inputs.jsonl'),'');checks.push('Immediate visible warnings precede automatic input; global pause prevents all screen writes');
 async function capture(name){await page.screenshot({path:path.join(out,name+'.png')});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name+' overflow');views.push(name);}
 async function leaveDetail(){if(await page.locator('#terminal-back').isVisible())await page.locator('#terminal-back').click();else if(await page.locator('#back').isVisible())await page.locator('#back').click();}
 for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]) {
  await page.setViewportSize({width,height});await leaveDetail();await capture(name+'-warning-list');
  await page.locator('#session-list button').filter({hasText:'Codex'}).click();
  assert.equal(await page.locator('#session-safety').isVisible(),true);
  const details=page.locator('#session-safety details');if(!await details.evaluate(element=>element.open))await details.locator('summary').click();
  await details.locator('summary').focus();assert.equal(await details.locator('summary').evaluate(element=>element.getBoundingClientRect().height>=44),true);
  await capture(name+'-long-request-paused');
 }
 await page.setViewportSize({width:390,height:844});await leaveDetail();
 await page.locator('#session-list button').filter({hasText:'Claude Code'}).click();await page.locator('#terminal-questions').click();
 const safe=page.getByRole('button',{name:'안전한 방법으로 계속',exact:true});assert.equal(await safe.count(),1);
 assert.equal(await page.getByRole('button',{name:'이번 요청 허용',exact:true}).count(),0);
 await safe.focus();await capture('mobile-claude-safe-action');await safe.click();
 await page.waitForFunction(()=>selectedItem?.session.systemSafety?.phase==='guided');
 let denial;for(let i=0;i<50&&!denial;i++){try{denial=JSON.parse(await optional('claude-response.json'));}catch{}if(!denial)await new Promise(r=>setTimeout(r,50));}
 assert.equal(denial.hookSpecificOutput.decision.behavior,'deny');assert.equal(denial.hookSpecificOutput.decision.interrupt,false);assert.match(denial.hookSpecificOutput.decision.message,/계속 진행/);
 checks.push('Web safe action denies the exact Claude permission, includes alternative instructions and does not interrupt the session');
 await page.locator('#close-interaction').click();await leaveDetail();
 await page.locator('#machines').getByRole('button',{name:/자동 승인 재개$/}).click();
 await page.locator('#session-list button').filter({hasText:'Codex'}).click();
 await page.waitForFunction(()=>selectedItem?.session.systemSafety?.phase==='guided');
 const sent=(await optional('inputs.jsonl')).trim().split('\n').map(JSON.parse);
 assert.deepEqual(sent.map(value=>value.kind),['escape','characters','enter','enter']);assert.ok(sent.every(value=>value.pid===41&&value.tty==='/dev/ttys980'));
 assert.match(sent[1].text,/원래 목표는 멈추지 말고/);assert.equal(await optional('approvals.txt'),'');
 checks.push('Codex original screen receives Escape, one guidance message and Enter-only newline recovery; no approval is sent');
 for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await capture(name+'-guided');}
 await page.emulateMedia({colorScheme:'dark'});await page.setViewportSize({width:390,height:844});await capture('mobile-dark-guided');
 await page.reload();await page.waitForFunction(()=>selectedItem?.session.systemSafety?.phase==='guided');assert.equal((await optional('inputs.jsonl')).trim().split('\n').length,4);
 await writeFile(path.join(root,'uncertain-write'),'fixture');
 await writeFile(path.join(root,'codex-screen'),'Would you like to run the following command?\n\n$ touch ~/Library/LaunchAgents/com.fixture.second.plist\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel');
 await page.waitForFunction(()=>selectedItem?.session.systemSafety?.phase==='uncertain');await capture('mobile-uncertain');
 const writesBefore=(await optional('inputs.jsonl')).trim().split('\n').length;
 await page.reload();await page.waitForFunction(()=>selectedItem?.session.systemSafety?.phase==='uncertain');await new Promise(r=>setTimeout(r,1200));
 assert.equal((await optional('inputs.jsonl')).trim().split('\n').length,writesBefore);assert.equal(await optional('approvals.txt'),'');
 checks.push('Reload preserves guided and uncertain receipts; an uncertain text write is never replayed');
 assert.deepEqual(errors,[]);
 await writeFile(path.join(out,'checks.json'),JSON.stringify({checks,views,errors,viewportSizes:[[390,844],[768,1024],[1440,900]],fixture:'isolated synthetic original CLIs; no provider request or system registration'},null,2));
 console.log(JSON.stringify({passed:checks.length,screenshots:views.length,checks},null,2));
} finally {
 await browser?.close();if(fixture&&fixture.exitCode===null){fixture.kill('SIGTERM');await new Promise(resolve=>{fixture.once('exit',resolve);setTimeout(resolve,2000);});}
 await rm(root,{recursive:true,force:true});
}
