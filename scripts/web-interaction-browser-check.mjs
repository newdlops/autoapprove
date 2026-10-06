// Real browser -> production Swift HTTP, Claude hook and local stdio MCP.
// Every session, provider response and image is synthetic; no user CLI or desktop is touched.
import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {mkdtemp, mkdir, readdir, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const directory=await mkdtemp(path.join(tmpdir(),'aa-web-interaction-'));
const baseline=process.argv.includes('--baseline-question');
const output=path.resolve('dist/qa',baseline?'web-interaction-baseline':'web-interaction');await mkdir(output,{recursive:true});
let fixture, browser, mcp, page;const errors=[],screenshots=[],checks=[],actions=[];
const optionalFile=async name=>{try{return await readFile(path.join(directory,name),'utf8');}catch{return '';}};
try {
  const cache=path.resolve('.build/cache/WebInteractionFixture');await mkdir(cache,{recursive:true});
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary=path.join(directory,'WebInteractionFixture');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/web-interaction-fixture.swift','-o',binary],{stdio:'inherit'});
  fixture=spawn(binary,[directory],{stdio:['ignore','ignore','pipe']});let fixtureError='';fixture.stderr.on('data',part=>fixtureError+=part);
  let ready;for(let i=0;i<375&&!ready;i++){try{ready=JSON.parse(await readFile(path.join(directory,'ready.json'),'utf8'));}catch{}if(fixture.exitCode!==null)throw Error(fixtureError);if(!ready)await new Promise(resolve=>setTimeout(resolve,40));}
  assert.ok(ready,'Fixture not ready: '+fixtureError);const base='http://127.0.0.1:'+ready.port;
  mcp=spawn(path.join(build,'autoapprove'),['--home',path.join(directory,'profile'),'mcp'],{stdio:['pipe','pipe','pipe']});let mcpError='';mcp.stderr.on('data',part=>mcpError+=part);
  const pending=new Map();let sequence=0;
  readline.createInterface({input:mcp.stdout}).on('line',line=>{const reply=JSON.parse(line);pending.get(reply.id)?.(reply);pending.delete(reply.id);});
  const rpc=async(method,params={})=>{
    const id=++sequence;let resolve;const reply=new Promise(done=>{resolve=done;});pending.set(id,resolve);mcp.stdin.write(JSON.stringify({jsonrpc:'2.0',id,method,params})+'\n');
    let timer;try{const value=await Promise.race([reply,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('MCP timeout '+method+': '+mcpError)),22000);})]);assert.equal(value.error,undefined);return value.result;}finally{clearTimeout(timer);}
  };
  const tool=async(name,args={})=>{const result=await rpc('tools/call',{name,arguments:args});assert.equal(result.isError,false,JSON.stringify(result));return result.structuredContent;};
  assert.equal((await rpc('initialize',{protocolVersion:'2025-11-25',capabilities:{},clientInfo:{name:'isolated-browser-check',version:'1'}})).protocolVersion,'2025-11-25');
  mcp.stdin.write(JSON.stringify({jsonrpc:'2.0',method:'notifications/initialized'})+'\n');assert.equal((await rpc('tools/list')).tools.length,5);
  const questions=[{id:'platform',question:'어떤 화면에서 확인할까요?',options:[{label:'휴대폰 세로 화면',description:'한 손으로 긴 질문을 읽고 선택지를 고릅니다.'},{label:'데스크톱'}]},
    {id:'checks',question:'여러 질문을 동시에 확인할 때 어떤 기능을 함께 점검할까요?',multiSelect:true,options:[{label:'한글과 이모지 🧪'},{label:'긴 선택지와 추가 설명을 입력해도 작성한 내용이 자동 갱신으로 사라지지 않는지 확인'}]}];
  const ask=await tool('ask_user',{title:'합성 MCP 질문',questions});const requestID=ask.request.id;
  const share=(await tool('start_screen_share',{title:'합성 Mac 전체 테스트 화면',sourceID:1,durationSeconds:600})).share;
  assert.equal(await optionalFile('captures.txt'),'');checks.push('stdio initialize/list, question publication and explicit desktop share start without capture');
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
  page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
  page.on('request',request=>{if(request.method()==='POST'&&new URL(request.url()).pathname==='/api/action')actions.push(request.postDataJSON());});
  if(baseline){const previous=execFileSync('git',['show','v0.2.49:Sources/AutoApproveCore/Resources/RemoteWeb/app.js'],{encoding:'utf8'});await page.route('**/app.js',route=>route.fulfill({status:200,contentType:'text/javascript',body:previous}));}
  async function capture(name){await page.screenshot({path:path.join(output,name+'.png')});screenshots.push(name);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name+' horizontal overflow');}
  for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
    await page.setViewportSize({width,height});
    if(name==='mobile'){await page.goto(base);await page.waitForFunction(()=>allSessions.length===2);}
    else {await page.locator('#back').evaluate(button=>button.click());}
    await capture(name+'-list');
    await page.locator('#session-list button').filter({hasText:'Codex'}).click();await page.waitForFunction(()=>latestFrame?.keys?.length>0);
    assert.equal(await page.locator('#automatic').isChecked(),true);
    await page.locator('#terminal-questions').click();await page.waitForFunction(()=>$('interaction-dialog').open);await capture(name+'-questions');
    const form=page.locator('#web-question-forms form').filter({hasText:'합성 MCP 질문'});
    await page.locator('.interaction-body').evaluate(body=>body.scrollTop=0);
    if(name==='mobile'){
      await form.getByRole('radio',{name:/휴대폰 세로 화면/}).check();await form.getByRole('checkbox',{name:'한글과 이모지 🧪'}).check();await form.locator('textarea').nth(1).fill('입력 도중 새 질문이 와도 이 초안은 유지되어야 합니다.');
      await tool('ask_user',{title:'나중에 도착한 질문',questions:[{question:'추가 테스트 메모를 적어주세요.'}]});await page.locator('#refresh').evaluate(button=>button.click());
      await page.waitForFunction(()=>$('web-question-forms').textContent.includes('나중에 도착한 질문'));
      assert.equal(await form.locator('textarea').nth(1).inputValue(),'입력 도중 새 질문이 와도 이 초안은 유지되어야 합니다.');assert.equal(await form.getByRole('radio',{name:/휴대폰 세로 화면/}).isChecked(),true);
      await capture('mobile-dense-draft');checks.push('mobile multiple questions, single/multiple selection and draft retention across a new request');
    }
    await page.locator('#close-interaction').click();
  }
  await page.setViewportSize({width:390,height:844});await page.locator('#terminal-questions').click();
  const mcpForm=page.locator('#web-question-forms form').filter({hasText:'합성 MCP 질문'});await mcpForm.getByRole('button',{name:'답변 보내기'}).click();
  await page.waitForFunction(()=>!$('web-question-forms').textContent.includes('합성 MCP 질문'));
  const answered=(await tool('get_user_answers',{requestID})).request;assert.equal(answered.phase,'answered');assert.equal(answered.answers[questions[0].question],'휴대폰 세로 화면');assert.match(answered.answers[questions[1].question],/한글과 이모지 🧪\n입력 도중/);
  let beginStarted=false,beginFinished=false,replyAfterBegin=false;
  await page.route('**/api/action**',async route=>{
    const request=route.request().postDataJSON();
    if(request.action==='beginQuestion'){beginStarted=true;await new Promise(resolve=>setTimeout(resolve,1500));beginFinished=true;}
    if(request.action==='replyQuestion')replyAfterBegin=beginFinished;
    return route.continue();
  });
  const binding=await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty}));
  const codexForm=page.locator('#questions form').filter({hasText:'합성 모바일 테스트를 진행할까요?'});await codexForm.getByRole('checkbox',{name:'아니요',exact:true}).check();
  for(let i=0;i<10&&!beginStarted;i++)await new Promise(resolve=>setTimeout(resolve,25));
  assert.equal(beginStarted,true,'Question editing should be acknowledged independently');assert.equal(beginFinished,false);
  assert.equal(await codexForm.getByRole('button',{name:'답변 보내기'}).isEnabled(),true,'Holding automation must not swallow a Send tap');
  await codexForm.getByRole('button',{name:'답변 보내기'}).click({timeout:800});
  await page.waitForFunction(()=>$('questions').textContent.includes('대기열에 등록'));
  assert.equal(replyAfterBegin,true);assert.equal((await optionalFile('messages.txt')).split('> 합성 모바일 테스트를 진행할까요?').length-1,1);
  await page.unroute('**/api/action**');checks.push('Immediate Send during a delayed editing acknowledgement delivers the selected Codex answer exactly once');
  const nodeID=await page.evaluate(()=>selectedItem.node.id);
  await page.route('**/api/network',async route=>{const response=await route.fetch(),dashboard=await response.json();dashboard.nodes=dashboard.nodes.map(node=>node.id===nodeID?{id:node.id,name:node.name,local:node.local,online:false,error:'synthetic inventory timeout'}:node);await route.fulfill({response,json:dashboard});});
  await page.waitForFunction(()=>currentNode()?.online===false&&!loadingNetwork);
  const failedQuestion=page.locator('#questions form').filter({hasText:'한글·이모지·긴 선택지의 줄바꿈'});
  await failedQuestion.getByRole('checkbox',{name:'질문을 먼저 확인',exact:true}).check();await failedQuestion.locator('textarea').fill('선택한 답변과 추가 설명을 보관합니다.');
  await writeFile(path.join(directory,'reply-failure'),'');
  assert.equal(await failedQuestion.getByRole('button',{name:'답변 보내기'}).isEnabled(),true,'Terminal control refresh must retain the independently verified question Send state');
  await failedQuestion.getByRole('button',{name:'답변 보내기'}).click();
  const inlineError=failedQuestion.locator('[data-delivery-error]');await inlineError.waitFor({state:'visible'});assert.match(await inlineError.textContent(),/합성 응답 경로 오류/);
  await inlineError.scrollIntoViewIfNeeded();await capture('mobile-question-error');
  assert.equal(await failedQuestion.locator('textarea').inputValue(),'선택한 답변과 추가 설명을 보관합니다.');assert.equal(await failedQuestion.getByRole('checkbox',{name:'질문을 먼저 확인',exact:true}).isChecked(),true);
  await page.unroute('**/api/network');await page.waitForFunction(()=>currentNode()?.online===true&&selectedItem.session.queuedQuestions.some(item=>item.reply?.phase==='failed'));
  await rm(path.join(directory,'reply-failure'));await failedQuestion.getByRole('button',{name:'답변 보내기'}).click();await page.waitForFunction(()=>selectedItem.session.queuedQuestions.every(item=>item.reply?.phase==='queued'));
  checks.push('Verified original-stream question remains sendable during inventory timeout; production preflight error is inline, preserves selections/text and permits an explicit retry only after a fresh authoritative failed status');
  await page.locator('#message-input').fill('작업 도중 새 질문입니다. 한글🧪');await page.locator('#send-message').click();await page.waitForFunction(()=>$('message-status').textContent.includes('등록'));
  assert.match(await optionalFile('messages.txt'),/작업 도중 새 질문입니다\. 한글🧪/);checks.push('MCP explicit answers reach originating process and Codex replies/messages use the same validated queue transport');
  await page.locator('#message-input').fill('전달 결과를 모를 때 중복 전송하지 않는지 확인');await page.locator('#message-input').focus();await page.setViewportSize({width:390,height:544});await capture('mobile-message-keyboard');await page.setViewportSize({width:390,height:844});
  const queuedBeforeFailure=await optionalFile('messages.txt');
  await page.route('**/api/action**',route=>{if(route.request().postDataJSON()?.action==='sendMessage')return route.abort('failed');return route.continue();});
  await page.locator('#send-message').click();await page.locator('#message-error').waitFor({state:'visible'});assert.equal(await page.locator('#send-message').isDisabled(),true);await capture('mobile-message-error');
  await page.locator('#new-message').click();assert.equal(await page.locator('#message-input').inputValue(),'');assert.equal(await optionalFile('messages.txt'),queuedBeforeFailure);await page.unroute('**/api/action**');checks.push('mobile keyboard height, inline delivery error and explicit new draft without automatic retry');
  await writeFile(path.join(directory,'queue-unbound'),'');await page.locator('#refresh-queue').click();await page.locator('#queue-error').waitFor({state:'visible'});
  await page.locator('#connect-queue-conversation').click();await page.locator('#queue-conversation').selectOption('00000000-0000-4000-8000-000000000001');
  for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.locator('#queue-conversation-picker').scrollIntoViewIfNeeded();await capture(name+'-queue-conversation');}
  await page.setViewportSize({width:390,height:844});await page.locator('#use-queue-conversation').click();await page.waitForFunction(()=>queueSnapshot?.items.length===5);await rm(path.join(directory,'queue-unbound'));
  checks.push('A Codex CLI without an open rollout offers an explicit active conversation choice; its validated selected queue loads without restarting the CLI');
  const queueBefore=(await(await fetch(base+'/api/codex/queue?session='+encodeURIComponent(binding.id))).json()).items;
  await page.locator('#clear-queue').click();await page.locator('#cancel-clear-queue').click();assert.deepEqual((await(await fetch(base+'/api/codex/queue?session='+encodeURIComponent(binding.id))).json()).items,queueBefore);
  await page.route('**/api/action**',route=>route.request().postDataJSON().action==='clearQueuedInputs'?route.abort('failed'):route.continue());
  await page.locator('#clear-queue').click();await page.locator('#confirm-clear-queue').click();await page.locator('#queue-error').waitFor({state:'visible'});await capture('mobile-queue-error');
  assert.deepEqual((await(await fetch(base+'/api/codex/queue?session='+encodeURIComponent(binding.id))).json()).items,queueBefore);await page.unroute('**/api/action**');
  const addedDuringDelete='삭제 도중 들어온 새 입력 · 한글🧪와 긴 내용을 보관합니다. '.repeat(5);
  await page.route('**/api/action**',async route=>{
    if(route.request().postDataJSON().action==='clearQueuedInputs'){
      const response=await fetch(base+'/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:'sendMessage',sessionID:binding.id,text:addedDuringDelete,requestID:crypto.randomUUID()})});assert.equal(response.status,200);
    }
    return route.continue();
  });
  await page.locator('#clear-queue').click();await page.locator('#confirm-clear-queue').click();await page.waitForFunction(()=>queueSnapshot?.items.length===1&&!queueLoading);await page.unroute('**/api/action**');
  assert.equal(await page.locator('#queued-inputs li').textContent(),addedDuringDelete);assert.match(await page.locator('#queue-status').textContent(),/5개를 삭제/);
  await page.waitForFunction(()=>selectedItem.session.queuedQuestions.every(item=>item.reply?.phase==='cancelled'));
  assert.deepEqual(await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty})),binding);assert.equal(await page.locator('#automatic').isChecked(),true);
  for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.locator('#codex-queue').scrollIntoViewIfNeeded();await capture(name+'-queue-after-clear');}
  await page.setViewportSize({width:390,height:844});checks.push('Actual queue list, cancel, failed deletion without replay, clear preserves concurrently added input, cancelled answer becomes editable and original identity/automation stay intact');
  const selectedCodex=await page.evaluate(()=>({sessionID:selectedItem.session.id,threadID:queueConversations.get(selectedKey).id}));
  const codexInstruction='브라우저 로그인 흐름을 자동 테스트하고 결과를 알려주세요.';
  await page.locator('#message-input').fill(codexInstruction);await page.locator('#send-message').click();await page.waitForFunction(()=>$('message-status').textContent.includes('대기열'));
  const codexDelivery=actions.filter(action=>action.action==='sendMessage'&&action.text===codexInstruction);assert.equal(codexDelivery.length,1);assert.equal(codexDelivery[0].sessionID,selectedCodex.sessionID);assert.equal(codexDelivery[0].threadID,selectedCodex.threadID);
  assert.equal(await optionalFile('inputs.txt'),'');checks.push('Explicitly chosen Codex conversation receives one test instruction through its validated queue without terminal key injection');
  await page.locator('#close-interaction').click();await page.locator('#back').click();await page.locator('#session-list button').filter({hasText:'Claude Code'}).click();await page.locator('#terminal-questions').click();
  assert.equal(await page.locator('#message-status').textContent(),'','Messages must not show another session\'s delivery status');
  const claudeForm=page.locator('#questions form[data-structured=true]');await claudeForm.getByRole('radio',{name:/개발/}).check();await claudeForm.getByRole('checkbox',{name:'휴대폰 질문 폼'}).check();await claudeForm.getByRole('checkbox',{name:'Mac 전체 화면 공유'}).check();await claudeForm.locator('textarea').nth(1).fill('휴대폰으로 확인');await capture('mobile-claude-multiple');await claudeForm.getByRole('button',{name:'답변 보내기'}).click();
  let claudeAnswer;for(let i=0;i<100&&!claudeAnswer;i++){try{claudeAnswer=JSON.parse(await optionalFile('claude-answer.json'));}catch{}if(!claudeAnswer)await new Promise(resolve=>setTimeout(resolve,40));}
  assert.deepEqual(claudeAnswer.hookSpecificOutput.updatedInput.answers,{'어떤 환경을 확인할까요?':'개발','어떤 기능을 테스트할까요?':'휴대폰 질문 폼, Mac 전체 화면 공유\n휴대폰으로 확인'});
  assert.equal(await optionalFile('inputs.txt'),'','Structured answers must inject zero terminal keys');checks.push('Claude multi-question answers preserve original hook fields and inject no arrow/text keys');
  await page.locator('#refresh').evaluate(button=>button.click());await page.waitForFunction(()=>!$('questions').textContent.includes('어떤 기능을 테스트할까요?'));
  await page.locator('#message-input').fill('같은 Claude 터미널로 새 메시지');await page.waitForFunction(()=>!$('send-message').disabled);await page.locator('#send-message').click();await page.waitForFunction(()=>$('message-status').textContent.includes('전달했습니다'));
  assert.match(await optionalFile('inputs.txt'),/^submit:같은 Claude 터미널로 새 메시지\n$/);checks.push('Claude new message uses the existing original terminal input after its question is answered');
  await page.locator('#close-interaction').click();await page.locator('#terminal-screens').click();
  await page.waitForFunction(()=>$('test-screen-image').complete&&$('test-screen-image').naturalWidth===640);await capture('mobile-test-screen');assert.ok((await optionalFile('captures.txt')).length>0);
  await page.locator('#test-screen-zoom').focus();await page.keyboard.press('Enter');assert.equal(await page.locator('#test-screen-image').getAttribute('data-zoom'),'true');
  const beforeViewInput=await optionalFile('inputs.txt');await page.keyboard.press('ArrowUp');await page.keyboard.type('view only');assert.equal(await optionalFile('inputs.txt'),beforeViewInput);
  assert.match(await page.locator('#test-screen-source').textContent(),/보기 전용/);assert.equal(await page.locator('#screen-share-picker').isVisible(),false);
  const additionalShare=(await tool('start_screen_share',{title:'합성 다른 공유 화면 · '+ '긴 테스트 결과 이름 '.repeat(7),sourceID:1})).share;
  await page.waitForFunction(()=>!$('screen-share-picker').hidden);await page.locator('#screen-share-picker summary').click();
  assert.ok((await page.locator('#screen-share-picker summary').boundingBox()).height>=44);await capture('mobile-multiple-shares');
  await page.locator('.test-screen-row').filter({hasText:additionalShare.title}).getByRole('button',{name:'화면 보기'}).click();assert.equal(await page.evaluate(()=>sharedScreen.share.id),additionalShare.id);
  await page.locator('.test-screen-row').filter({hasText:share.title}).getByRole('button',{name:'화면 보기'}).click();await tool('stop_screen_share',{shareID:additionalShare.id});
  await page.waitForFunction(()=>$('screen-share-picker').hidden);checks.push('Multiple shared screens use a 44px disclosure control; long titles wrap and normal selection stays bound to the same session');
  const viewerBinding=await page.evaluate(()=>({shareID:sharedScreen.share.id,sessionID:selectedItem.session.id,key:selectedKey}));
  await page.locator('#screen-message').click();await page.waitForFunction(()=>$('interaction-dialog').open);
  await capture('mobile-screen-instruction');assert.equal(await page.evaluate(()=>selectedKey),viewerBinding.key);
  const claudeInstruction='현재 Mac 화면의 앱을 자동 테스트해주세요.';await page.locator('#message-input').fill(claudeInstruction);await page.locator('#send-message').click();await page.waitForFunction(()=>$('message-status').textContent.includes('전달했습니다'));
  const claudeDelivery=await optionalFile('inputs.txt');assert.equal(claudeDelivery,beforeViewInput+'submit:'+claudeInstruction+'\n');
  await page.locator('#close-interaction').click();assert.equal(await page.evaluate(()=>$('test-screen-dialog').open&&sharedScreen.share.id),viewerBinding.shareID);
  checks.push('View-only screen pointer/keyboard actions inject zero keys; test instruction uses the original Claude session and closing its form returns to the same share');
  await page.locator('#close-test-screen').click();await page.waitForTimeout(1000);const stoppedCount=(await optionalFile('captures.txt')).length;await page.waitForTimeout(1200);assert.equal((await optionalFile('captures.txt')).length,stoppedCount,'Closed viewer must not request captures');
  await page.locator('#terminal-screens').click();await page.waitForFunction(()=>$('test-screen-image').naturalWidth===640);await page.locator('#stop-test-screen').click();await page.waitForFunction(()=>$('test-screen-status').textContent.includes('종료'));
  const ended=await fetch(base+'/api/test-screen?share='+share.id);assert.equal(ended.status,410);checks.push('explicit desktop viewer, zoom, close stops capture requests and phone stop revokes image access');
  await page.locator('#close-test-screen').click();await writeFile(path.join(directory,'screen-denied'),'');const capturesBeforeDenied=await optionalFile('captures.txt');
  await page.locator('#terminal-screens').click();await page.locator('#screen-start-error').waitFor({state:'visible'});assert.match(await page.locator('#screen-start-error').textContent(),/화면 녹음 권한/);assert.equal(await optionalFile('captures.txt'),capturesBeforeDenied);await capture('mobile-screen-permission');
  await rm(path.join(directory,'screen-denied'));await page.locator('#start-test-screen').click();await page.waitForFunction(()=>$('test-screen-image').naturalWidth===640);
  const webShare=await page.evaluate(()=>sharedScreen.share.id);assert.notEqual(webShare,share.id);
  for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
    await page.setViewportSize({width,height});await capture(name+'-screen-button');
    assert.ok(await page.locator('.test-screen-image').evaluate(element=>element.scrollHeight<=element.clientHeight+1),'Default sharing view must show the whole screen without vertical cropping');
  }
  await page.locator('#stop-test-screen').click();assert.equal((await fetch(base+'/api/test-screen?share='+webShare)).status,410);
  checks.push('One terminal Test Screen click opens an existing MCP share or directly starts full-display sharing; permission denial captures nothing and explicit retry/stop work');
  await page.locator('#close-test-screen').click();const standalone=(await tool('start_screen_share',{title:'합성 보기 전용 화면',sourceID:1})).share;
  const beforeStandaloneInput=await optionalFile('inputs.txt');await page.goto(base+'#share='+standalone.id);await page.reload();await page.waitForFunction(()=>$('test-screen-image').naturalWidth===640&&$('test-screen-dialog').open);
  assert.equal(await page.locator('#screen-message').isVisible(),false);assert.equal(await page.evaluate(()=>selectedItem),null);await capture('desktop-screen-without-session');assert.equal(await optionalFile('inputs.txt'),beforeStandaloneInput);
  await page.locator('#stop-test-screen').click();checks.push('MCP share link without a selected agent displays only the Mac image and never chooses or controls a terminal');
  assert.equal(errors.length,0,errors.join('\n'));const state=await(await fetch(base+'/api/state')).json();assert.equal(state.sessions.some(item=>item.pty),false);
  await rm(path.join(output,'failure.json'),{force:true});
  await writeFile(path.join(output,'report.json'),JSON.stringify({result:'PASS',scope:'Real browser, production Swift HTTP/MCP/hooks with synthetic sessions/providers/images; no physical phone or user desktop',checks,screenshots,errors},null,2));console.log(JSON.stringify({result:'PASS',checks,screenshots,errors},null,2));
}catch(error){
  const client=page ? await page.evaluate(()=>({deliveries:[...questionDeliveries.entries()],questions:interactionSources().flatMap(source=>source.queuedQuestions||[]),buttons:[...document.querySelectorAll('#questions button')].map(button=>({text:button.textContent,disabled:button.disabled})),network:{connected,mutation,original:originalStreamSelected()}})).catch(()=>null) : null;
  await writeFile(path.join(output,'failure.json'),JSON.stringify({error:error.message,errors,checks,client},null,2));throw error;
}
finally{if(browser)await browser.close();if(mcp){mcp.stdin.end();await new Promise(resolve=>setTimeout(resolve,200));if(mcp.exitCode===null)mcp.kill('SIGTERM');}if(fixture&&fixture.exitCode===null)fixture.kill('SIGTERM');await rm(directory,{recursive:true,force:true});}
