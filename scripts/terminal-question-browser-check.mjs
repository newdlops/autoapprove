// Production Swift HTTP and Chromium with isolated, synthetic original terminals.
// No user session, provider server, permission setting or desktop is changed.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug'),root=await mkdtemp('/private/tmp/aa-terminal-question-'),out=path.resolve('dist/qa/terminal-question');
await mkdir(out,{recursive:true});await mkdir('.build/cache/TerminalQuestionWeb',{recursive:true});
let fixture,browser;const errors=[],checks=[],views=[],actions=[];
const optional=async name=>{try{return await readFile(path.join(root,name),'utf8');}catch{return '';}};
try {
 const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(f=>f.endsWith('.swift.o')).map(f=>path.join(build,'AutoApproveCore.build',f)),binary=path.join(root,'fixture');
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/TerminalQuestionWeb'),'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/web-interaction-fixture.swift','-o',binary],{stdio:'inherit'});
 fixture=spawn(binary,[root,'--no-codex-server'],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',v=>stderr+=v);
 let ready;for(let i=0;i<400&&!ready;i++){try{ready=JSON.parse(await readFile(path.join(root,'ready.json'),'utf8'));}catch{}if(fixture.exitCode!==null)throw Error(stderr);if(!ready)await new Promise(r=>setTimeout(r,40));}
 assert.ok(ready,'fixture startup '+stderr);const base='http://127.0.0.1:'+ready.port;
 browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
 const page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(15000);page.on('pageerror',e=>errors.push(e.message));
 page.on('request',r=>{if(r.method()==='POST'&&new URL(r.url()).pathname==='/api/action')actions.push(r.postDataJSON());});
 await page.goto(base);await page.waitForFunction(()=>allSessions.length===2);await page.locator('#session-list button').filter({hasText:'Codex'}).click();await page.waitForFunction(()=>latestFrame?.keys.includes('submit'));
 const original=await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty}));
 await page.locator('#terminal-questions').click();await page.waitForFunction(()=>queueSnapshot?.available===false&&!queueLoading);
 assert.equal(await page.locator('#queue-error').isVisible(),false);assert.equal(await page.locator('#connect-queue-conversation').isVisible(),false);assert.equal(await page.locator('#clear-queue').isDisabled(),true);
 assert.match(await page.locator('#queue-status').textContent(),/원본 터미널/);checks.push('Missing Codex server is an unavailable queue feature; normal questions stay available without a connection error or dead conversation picker');
 const form=page.locator('#questions form').filter({hasText:'한글·이모지·긴 선택지의 줄바꿈'});
 assert.equal(await form.getByRole('radio').count(),2);assert.equal(await form.locator('input:checked').count(),0);assert.equal(await form.getByRole('button',{name:'답변 보내기'}).isDisabled(),true);
 await form.getByRole('radio',{name:'질문을 먼저 확인',exact:true}).check();await form.getByRole('radio',{name:'긴 선택지와 추가 설명을 함께 보내기',exact:true}).check();
 await form.getByRole('radio',{name:'질문을 먼저 확인',exact:true}).focus();await page.keyboard.press('ArrowDown');
 assert.equal(await form.getByRole('radio',{name:'질문을 먼저 확인',exact:true}).isChecked(),false);await form.locator('textarea').fill('폰에서 선택한 답변 · 한글 🧪');
 await page.locator('#refresh').evaluate(b=>b.click());await page.waitForFunction(()=>!loadingNetwork);
 assert.equal(await form.locator('textarea').inputValue(),'폰에서 선택한 답변 · 한글 🧪');assert.equal(await form.locator('input:checked').count(),1);
 async function capture(name){await page.screenshot({path:path.join(out,name+'.png')});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name+' overflow');views.push(name);}
 for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await form.scrollIntoViewIfNeeded();await capture(name+'-async-choice');}
 checks.push('General async choices use radios without a submitted default; selection and explanation survive refresh at three widths');
 await page.setViewportSize({width:390,height:844});await form.getByRole('button',{name:'답변 보내기'}).click();await page.waitForFunction(()=>selectedItem.session.queuedQuestions.find(q=>q.id==='fixture-q2')?.reply?.transport==='terminal');
 const routes=(await optional('message-routes.jsonl')).trim().split('\n').map(JSON.parse);assert.equal(routes.length,1);assert.equal(routes[0].pid,original.pid);assert.equal(routes[0].tty,original.tty);assert.match(routes[0].text,/^> 한글·이모지/);assert.match(routes[0].text,/긴 선택지와 추가 설명을 함께 보내기\n폰에서 선택한 답변 · 한글 🧪$/);
 assert.equal(await optional('messages.txt'),'');await capture('mobile-original-answer-receipt');checks.push('A selected general answer and explanation reach the exact original CLI once without submitting to a Codex server');
 await page.reload();await page.waitForFunction(id=>selectedItem?.session.id===id&&latestFrame?.keys.length,original.id);await page.locator('#terminal-questions').click();await page.waitForFunction(()=>queueSnapshot?.available===false);
 assert.equal(await form.getByRole('button',{name:'답변 보내기'}).isDisabled(),true);assert.equal((await optional('message-routes.jsonl')).trim().split('\n').length,1);
 checks.push('Reload retains the authoritative reply receipt and cannot replay the original answer');
 const menu='어떤 화면에서 동작을 확인할까요?\n\n  1. 휴대폰 세로 화면\n› 2. 데스크톱 화면\n  3. 두 화면 모두와 한글·이모지 및 긴 선택지의 화면 줄바꿈을 확인\n\nPress enter to confirm or esc to cancel';
 await writeFile(path.join(root,'terminal-question'),menu);await page.waitForFunction(()=>latestFrame?.question?.options.length===3);
 const choiceForm=page.locator('#questions form').filter({hasText:'원본 터미널의 질문'});
 assert.equal(await choiceForm.locator('input:checked').count(),0);assert.equal(await choiceForm.locator('textarea').count(),0);assert.equal(await choiceForm.getByRole('button',{name:'답변 보내기'}).isDisabled(),true);
 await choiceForm.getByRole('radio',{name:'휴대폰 세로 화면',exact:true}).check();
 for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await choiceForm.scrollIntoViewIfNeeded();await capture(name+'-terminal-choice');}
 await page.setViewportSize({width:390,height:844});const stale=await page.evaluate(()=>latestFrame.question.id);
 await page.route('**/api/action**',async route=>{if(route.request().postDataJSON()?.action==='replyTerminalQuestion')await writeFile(path.join(root,'terminal-question'),menu.replace('동작을 확인','다음 작업을 점검'));return route.continue();});
 await choiceForm.getByRole('button',{name:'답변 보내기'}).click();await page.waitForFunction(old=>latestFrame?.question?.id&&latestFrame.question.id!==old,stale);await page.unroute('**/api/action**');
 assert.equal(await optional('choice-delivered.json'),'');assert.equal(await choiceForm.locator('input:checked').count(),0);checks.push('Current terminal menus become explicit choice forms, and a changed question rejects the old selection before any input');
 await choiceForm.getByRole('radio',{name:/두 화면 모두/}).check();await choiceForm.getByRole('button',{name:'답변 보내기'}).click();await page.waitForFunction(()=>!latestFrame?.question);
 const chosen=JSON.parse(await optional('choice-delivered.json'));assert.equal(chosen.pid,original.pid);assert.equal(chosen.tty,original.tty);assert.equal(chosen.bytes,'\x1b[B\r');assert.equal(await choiceForm.count(),0);
 checks.push('Selection relative to the current cursor sends one movement and one Return to the original CLI, then removes the answered menu from compact updates');
 const overlay='Question 1/2 (2 unanswered)\n\n확인할 화면을 골라주세요.\n\n› 1. 휴대폰\n  2. 데스크톱\n  3. None of the above\n\ntab to add notes | enter to submit answer | ←/→ to navigate questions | esc to interrupt';
 await writeFile(path.join(root,'terminal-question'),overlay);await page.waitForFunction(()=>latestFrame?.question?.numericSubmission===true);
 await choiceForm.getByRole('radio',{name:'데스크톱',exact:true}).check();await choiceForm.getByRole('button',{name:'답변 보내기'}).click();await page.waitForFunction(()=>latestFrame?.question?.question.includes('Question 2/2'));
 assert.equal(JSON.parse(await optional('choice-delivered.json')).bytes,'2');assert.equal(await choiceForm.locator('input:checked').count(),0);await choiceForm.scrollIntoViewIfNeeded();await capture('mobile-codex-next-question');
 await choiceForm.getByRole('radio',{name:'휴대폰',exact:true}).check();await choiceForm.getByRole('button',{name:'답변 보내기'}).click();await page.waitForFunction(()=>!latestFrame?.question);
 assert.equal(JSON.parse(await optional('choice-delivered.json')).bytes,'1');checks.push('Codex multi-question overlays advance with one digit per deliberate web response, without submitting the next default option');
 await writeFile(path.join(root,'terminal-question'),menu.replace('동작을 확인','마지막 조건을 검증'));await writeFile(path.join(root,'choice-uncertain'),'');await page.waitForFunction(()=>latestFrame?.question?.options.length===3);
 await choiceForm.getByRole('radio',{name:'휴대폰 세로 화면',exact:true}).check();await choiceForm.getByRole('button',{name:'답변 보내기'}).click();await page.waitForFunction(()=>latestFrame?.question?.reply?.phase==='uncertain');
 assert.equal(await choiceForm.getByRole('button',{name:'답변 보내기'}).isDisabled(),true);await choiceForm.scrollIntoViewIfNeeded();await capture('mobile-uncertain-choice');
 const inputs=await optional('inputs.txt');await page.reload();await page.waitForFunction(id=>selectedItem?.session.id===id&&latestFrame?.question?.reply?.phase==='uncertain',original.id);await page.locator('#terminal-questions').click();
 assert.equal(await choiceForm.getByRole('button',{name:'답변 보내기'}).isDisabled(),true);assert.equal(await optional('inputs.txt'),inputs);
 assert.deepEqual(await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty})),original);assert.deepEqual(errors,[]);
 checks.push('An uncertain terminal choice preserves the selection, blocks repeats after reload and keeps the original PID/TTY');
 const report={checks,views,javascriptErrors:errors,originalPreserved:true,queueSubmissions:0,answerRequests:actions.filter(v=>v.action==='replyQuestion').length};await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2));console.log(JSON.stringify(report,null,2));
}finally{await browser?.close();fixture?.kill('SIGTERM');await rm(root,{recursive:true,force:true});}
