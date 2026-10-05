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
const output=path.resolve('dist/qa/web-interaction');await mkdir(output,{recursive:true});
let fixture, browser, mcp;const errors=[],screenshots=[],checks=[];
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
  const page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
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
  const codexForm=page.locator('#questions form').filter({hasText:'어떤 모바일 화면을 확인할까요?'});await codexForm.getByRole('checkbox',{name:'질문과 답변'}).check();await codexForm.getByRole('button',{name:'답변 보내기'}).click();
  await page.waitForFunction(()=>$('questions').textContent.includes('대기열에 등록'));
  await page.locator('#message-input').fill('작업 도중 새 질문입니다. 한글🧪');await page.locator('#send-message').click();await page.waitForFunction(()=>$('message-status').textContent.includes('등록'));
  assert.match(await optionalFile('messages.txt'),/작업 도중 새 질문입니다\. 한글🧪/);checks.push('MCP explicit answers reach originating process and Codex replies/messages use the same validated queue transport');
  await page.locator('#message-input').fill('전달 결과를 모를 때 중복 전송하지 않는지 확인');await page.locator('#message-input').focus();await page.setViewportSize({width:390,height:544});await capture('mobile-message-keyboard');await page.setViewportSize({width:390,height:844});
  const queuedBeforeFailure=await optionalFile('messages.txt');
  await page.route('**/api/action**',route=>{if(route.request().postDataJSON()?.action==='sendMessage')return route.abort('failed');return route.continue();});
  await page.locator('#send-message').click();await page.locator('#message-error').waitFor({state:'visible'});assert.equal(await page.locator('#send-message').isDisabled(),true);await capture('mobile-message-error');
  await page.locator('#new-message').click();assert.equal(await page.locator('#message-input').inputValue(),'');assert.equal(await optionalFile('messages.txt'),queuedBeforeFailure);await page.unroute('**/api/action**');checks.push('mobile keyboard height, inline delivery error and explicit new draft without automatic retry');
  await page.locator('#close-interaction').click();await page.locator('#back').click();await page.locator('#session-list button').filter({hasText:'Claude Code'}).click();await page.locator('#terminal-questions').click();
  assert.equal(await page.locator('#message-status').textContent(),'','Messages must not show another session\'s delivery status');
  const claudeForm=page.locator('#questions form[data-structured=true]');await claudeForm.getByRole('radio',{name:/개발/}).check();await claudeForm.getByRole('checkbox',{name:'휴대폰 질문 폼'}).check();await claudeForm.getByRole('checkbox',{name:'Mac 전체 화면 공유'}).check();await claudeForm.locator('textarea').nth(1).fill('휴대폰으로 확인');await capture('mobile-claude-multiple');await claudeForm.getByRole('button',{name:'답변 보내기'}).click();
  let claudeAnswer;for(let i=0;i<100&&!claudeAnswer;i++){try{claudeAnswer=JSON.parse(await optionalFile('claude-answer.json'));}catch{}if(!claudeAnswer)await new Promise(resolve=>setTimeout(resolve,40));}
  assert.deepEqual(claudeAnswer.hookSpecificOutput.updatedInput.answers,{'어떤 환경을 확인할까요?':'개발','어떤 기능을 테스트할까요?':'휴대폰 질문 폼, Mac 전체 화면 공유\n휴대폰으로 확인'});
  assert.equal(await optionalFile('inputs.txt'),'','Structured answers must inject zero terminal keys');checks.push('Claude multi-question answers preserve original hook fields and inject no arrow/text keys');
  await page.locator('#refresh').evaluate(button=>button.click());await page.waitForFunction(()=>!$('questions').textContent.includes('어떤 기능을 테스트할까요?'));
  await page.locator('#message-input').fill('같은 Claude 터미널로 새 메시지');await page.waitForFunction(()=>!$('send-message').disabled);await page.locator('#send-message').click();await page.waitForFunction(()=>$('message-status').textContent.includes('전달했습니다'));
  assert.match(await optionalFile('inputs.txt'),/^submit:같은 Claude 터미널로 새 메시지\n$/);checks.push('Claude new message uses the existing original terminal input after its question is answered');
  await page.locator('#close-interaction').click();await page.locator('#terminal-screens').click();await page.getByRole('button',{name:'화면 보기'}).click();
  await page.waitForFunction(()=>$('test-screen-image').complete&&$('test-screen-image').naturalWidth===640);await capture('mobile-test-screen');assert.ok((await optionalFile('captures.txt')).length>0);
  await page.locator('#test-screen-zoom').focus();await page.keyboard.press('Enter');assert.equal(await page.locator('#test-screen-image').getAttribute('data-zoom'),'true');
  await page.locator('#close-test-screen').click();await page.waitForTimeout(1000);const stoppedCount=(await optionalFile('captures.txt')).length;await page.waitForTimeout(1200);assert.equal((await optionalFile('captures.txt')).length,stoppedCount,'Closed viewer must not request captures');
  await page.locator('#terminal-screens').click();await page.getByRole('button',{name:'화면 보기'}).click();await page.waitForFunction(()=>$('test-screen-image').naturalWidth===640);await page.locator('#stop-test-screen').click();await page.waitForFunction(()=>$('test-screen-status').textContent.includes('종료'));
  const ended=await fetch(base+'/api/test-screen?share='+share.id);assert.equal(ended.status,410);checks.push('explicit desktop viewer, zoom, close stops capture requests and phone stop revokes image access');
  assert.equal(errors.length,0,errors.join('\n'));const state=await(await fetch(base+'/api/state')).json();assert.equal(state.sessions.some(item=>item.pty),false);
  await writeFile(path.join(output,'report.json'),JSON.stringify({result:'PASS',scope:'Real browser, production Swift HTTP/MCP/hooks with synthetic sessions/providers/images; no physical phone or user desktop',checks,screenshots,errors},null,2));console.log(JSON.stringify({result:'PASS',checks,screenshots,errors},null,2));
}catch(error){await writeFile(path.join(output,'failure.json'),JSON.stringify({error:error.message,errors,checks},null,2));throw error;}
finally{if(browser)await browser.close();if(mcp){mcp.stdin.end();await new Promise(resolve=>setTimeout(resolve,200));if(mcp.exitCode===null)mcp.kill('SIGTERM');}if(fixture&&fixture.exitCode===null)fixture.kill('SIGTERM');await rm(directory,{recursive:true,force:true});}
