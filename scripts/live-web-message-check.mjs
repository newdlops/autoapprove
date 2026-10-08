// Opt-in real CLI test: private tmux socket and empty scratch folders, no existing session input.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const tmux=process.env.AUTOAPPROVE_TMUX||path.join(process.env.HOME,'.local/bin/tmux');
const codex=process.env.AUTOAPPROVE_CODEX||execFileSync('/usr/bin/which',['codex'],{encoding:'utf8'}).trim();
const claude=process.env.AUTOAPPROVE_CLAUDE||execFileSync('/usr/bin/which',['claude'],{encoding:'utf8'}).trim();
const directory=await mkdtemp('/private/tmp/aa-live-message-'),socket=path.join(directory,'socket');
const output=path.resolve('.runtime/web-messages-20261008/live-cli');await mkdir(output,{recursive:true,mode:0o700});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let created=false,fixture,browser,page;const checks=[],errors=[],readFailures=[];
try {
  for(const name of ['codex','claude'])await mkdir(path.join(directory,name));
  const cache=path.resolve('.build/cache/LiveWebMessages');await mkdir(cache,{recursive:true});
  const binary=path.join(directory,'LiveWebMessages');
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/live-web-messages.swift','-o',binary],{stdio:'inherit'});
  execFileSync(tmux,['-S',socket,'-f','/dev/null','new-session','-d','-x','120','-y','40','-s','codex','-c',path.join(directory,'codex'),codex,'--no-daemon','--no-alt-screen','-c','check_for_update_on_startup=false','-s','read-only','-a','on-request'],{stdio:'inherit'});created=true;
  execFileSync(tmux,['-S',socket,'set-option','-g','remain-on-exit','on'],{stdio:'inherit'});
  execFileSync(tmux,['-S',socket,'new-session','-d','-x','120','-y','40','-s','claude','-c',path.join(directory,'claude'),claude,'--safe-mode','--tools','','--disable-slash-commands'],{stdio:'inherit'});
  fixture=spawn(binary,[socket,tmux,directory],{stdio:['ignore','ignore','pipe']});let fixtureError='';fixture.stderr.on('data',data=>fixtureError+=data);
  let ready;for(let i=0;i<200&&!ready;i++){try{ready=JSON.parse(await readFile(path.join(directory,'ready.json'),'utf8'));}catch{}if(fixture.exitCode!==null)throw Error(fixtureError);if(!ready)await wait(100);}
  assert.ok(ready,'Real fixture startup: '+fixtureError);
  // Consent applies only to the empty scratch folder created above. Never restart the shared Codex daemon.
  for(const agent of ['codex','claude']) {
    let startupReady=false,consented=false;
    for(let i=0;i<500;i++) {
      const screen=execFileSync(tmux,['-S',socket,'capture-pane','-p','-t',agent+':0.0'],{encoding:'utf8'});
      if(agent==='claude'&&!consented&&screen.includes(path.join(directory,'claude'))&&screen.includes('Yes, I trust this folder')) {
        execFileSync(tmux,['-S',socket,'send-keys','-H','-t','claude:0.0','1b','5b','42']);
        let selected='';for(let attempt=0;attempt<30;attempt++){await wait(100);selected=execFileSync(tmux,['-S',socket,'capture-pane','-p','-t','claude:0.0'],{encoding:'utf8'});if(/❯\s+Yes, I trust this folder/.test(selected))break;}
        assert.match(selected,/❯\s+Yes, I trust this folder/,'Only the created scratch folder may be confirmed');
        execFileSync(tmux,['-S',socket,'send-keys','-H','-t','claude:0.0','0d']);consented=true;await wait(500);continue;
      }
      if(/\?\s+for shortcuts|\d+% (?:context )?left|shift\+tab to cycle/i.test(screen)){startupReady=true;break;}
      await wait(100);
    }
    assert.ok(startupReady,agent+' did not finish its startup menus; no web message was sent');
  }
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
  page=await browser.newPage({viewport:{width:390,height:844}});page.setDefaultTimeout(30000);page.on('pageerror',error=>errors.push(error.message));
  page.on('response',async response=>{if(response.status()>=400&&new URL(response.url()).pathname.startsWith('/api/terminal')){try{const body=await response.json();readFailures.push({status:response.status(),error:body.error,diagnostics:body.diagnostics});}catch{}}});
  await page.goto(ready.url);await page.waitForFunction(()=>allSessions.length===2);
  const results=[];
  for(const agent of ['codex','claude']) {
    if(await page.locator('#interaction-dialog').evaluate(dialog=>dialog.open))await page.locator('#close-interaction').click();
    if(await page.locator('#terminal-back').isVisible())await page.locator('#terminal-back').click();
    else if(await page.locator('#back').isVisible())await page.locator('#back').click();
    await page.locator('.session-row').filter({hasText:agent==='codex'?'Codex':'Claude Code'}).click();
    await page.waitForFunction(()=>terminalFrameFresh());
    const before=await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty,started:selectedItem.session.started}));
    await page.locator('#terminal-questions').click();
    const marker='AUTOAPPROVE_WEB_ACK_'+randomUUID().replaceAll('-','').slice(0,12);
    const message=`메시지 전달 검사입니다. 파일·도구·명령을 실행하지 말고 ${marker} 하나만 답해주세요.`;
    await page.locator('#message-input').fill(message);await page.waitForFunction(()=>!$('send-message').disabled);await page.locator('#send-message').click();
    await page.waitForFunction(()=>messageDeliveries.get(selectedKey)?.phase==='accepted');
    await page.locator('#close-interaction').click();
    await page.waitForFunction(marker=>latestFrame?.screen?.split(marker).length>=3,marker,{timeout:60000});
    const after=await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty,started:selectedItem.session.started}));assert.deepEqual(after,before);
    const observed=await page.evaluate(marker=>({textSeen:latestFrame.screen.includes(marker),occurrences:latestFrame.screen.split(marker).length-1,phase:selectedItem.session.phase}),marker);
    results.push({agent,originalIdentityPreserved:true,received:observed.textSeen,occurrences:observed.occurrences,phase:observed.phase});
    assert.ok(observed.textSeen);console.log(JSON.stringify({agent,received:true,originalIdentityPreserved:true}));
  }
  assert.deepEqual(errors,[]);checks.push('Real Codex and Claude TUI receive browser messages through their original tmux panes without PID, start or TTY changes');
  await writeFile(path.join(output,'report.json'),JSON.stringify({result:'PASS',checks,results,errors},null,2));console.log(JSON.stringify({result:'PASS',checks,results,errors},null,2));
} catch(error){
  let paneMetadata;try{paneMetadata=execFileSync(tmux,['-S',socket,'list-panes','-a','-F',['pid','session_id','pane_id','pane_pid','pane_tty','pane_width','pane_height','cursor_x','cursor_y','cursor_flag','cursor_shape','cursor_blinking','pane_in_mode','synchronize-panes','pane_input_off'].map(key=>'#{'+key+'}').join('|')],{encoding:'utf8'}).trim();}catch{}
  const screens=[];for(const agent of ['codex','claude'])try{screens.push(agent+'\n'+execFileSync(tmux,['-S',socket,'capture-pane','-p','-t',agent+':0.0','-S','-100'],{encoding:'utf8'}));}catch{}
  await writeFile(path.join(output,'failure-screens.txt'),screens.join('\n'),{mode:0o600});
  await writeFile(path.join(output,'failure.json'),JSON.stringify({error:error.message,checks,errors,paneMetadata,readFailures:readFailures.slice(-5),state:page?await page.evaluate(()=>({key:selectedKey,terminal:selectedItem?.session.terminal,reason:latestFrame?.inputReason,keys:latestFrame?.keys,observedAt:latestFrame?.observedAt,frameError:document.getElementById('terminal-error')?.textContent,connection:document.getElementById('connection')?.textContent})).catch(()=>null):null},null,2));throw error;
}
finally {if(browser)await browser.close();if(fixture&&fixture.exitCode===null)fixture.kill('SIGTERM');if(created)try{execFileSync(tmux,['-S',socket,'kill-server'],{stdio:'ignore'});}catch{}await rm(directory,{recursive:true,force:true});}
