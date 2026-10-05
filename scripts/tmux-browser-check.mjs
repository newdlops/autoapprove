// Real Chromium -> real Swift HTTP/SSE/input -> isolated real tmux QA pane.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,rm,writeFile,access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const tmux=process.env.AUTOAPPROVE_TMUX||path.join(process.env.HOME,'.local/bin/tmux');
const directory=await mkdtemp(path.join(tmpdir(),'aa-tmux-web-'));
const output=path.resolve('dist/qa/tmux-browser');await mkdir(output,{recursive:true});
const socket=path.join(directory,'socket'),record=path.join(directory,'input.bin');
let created=false,fixture,browser;
const errors=[],screenshots=[],latencies=[];
try {
  const cache=path.resolve('.build/cache/TmuxWebFixture');await mkdir(cache,{recursive:true});
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary=path.join(directory,'TmuxWebFixture'),pane=path.join(directory,'codex');
  execFileSync('/usr/bin/cc',['Tests/fixtures/tmux-relay-pane.c','-o',pane],{stdio:'inherit'});
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/tmux-web-fixture.swift','-o',binary],{stdio:'inherit'});
  execFileSync(tmux,['-S',socket,'-f','/dev/null','new-session','-d','-x','80','-y','25','-s','qa',pane,record],{stdio:'inherit'});
  await access(socket);created=true;
  const original=execFileSync(tmux,['-S',socket,'list-panes','-a','-F','#{pane_pid}|#{pane_tty}|#{pane_width}|#{pane_height}'],{encoding:'utf8'}).trim();
  fixture=spawn(binary,[socket,tmux,directory],{stdio:['ignore','ignore','pipe']});
  let fixtureError='';fixture.stderr.on('data',part=>fixtureError+=part);
  let port;
  const deadline=Date.now()+15000;
  while(!port&&Date.now()<deadline){try{port=Number(await readFile(path.join(directory,'port'),'utf8'));}catch{}if(fixture.exitCode!==null)throw Error(fixtureError);if(!port)await new Promise(resolve=>setTimeout(resolve,40));}
  assert.ok(port,'Private web fixture did not become ready: '+fixtureError);
  const base='http://127.0.0.1:'+port;
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
  const page=await browser.newPage({viewport:{width:390,height:844}});
  page.on('pageerror',error=>errors.push(error.message));
  await page.goto(base);await page.locator('.session-row').first().click();
  try { await page.waitForFunction(()=>latestFrame?.screen?.includes('TMUX QA')&&latestFrame?.streamID&&!$('terminal-keyboard-toggle').disabled); }
  catch (error) {
    console.log(JSON.stringify({fixtureError,errors,initial:await page.evaluate(()=>({frame:latestFrame,item:selectedItem,reason:document.getElementById('input-reason').textContent,native:document.getElementById('native-status').textContent,output:document.getElementById('terminal-screen').textContent,connected,directMode}))}));
    await page.screenshot({path:path.join(output,'initial-error.png')});throw error;
  }
  const sessionID=await page.evaluate(()=>latestFrame.sessionID), streamID=await page.evaluate(()=>latestFrame.streamID);
  assert.equal(await page.locator('#automatic').isChecked(),true);
  assert.equal(await page.locator('#terminal-input').isVisible(),false);
  assert.equal(await page.locator('#native-view-label').isVisible(),false,'tmux does not capture a Mac window');
  assert.ok(await page.locator('#terminal-screen [style]').count()>0,'Actual tmux RGB must render');
  assert.equal(await page.evaluate(()=>latestFrame.cursor.style),'bar');
  async function visibleTerminal(marker) {
    await page.waitForFunction(marker=>{
      const pre=document.getElementById('terminal-screen'),cursor=document.getElementById('terminal-cursor');
      const line=[...pre.querySelectorAll('.terminal-line')].find(line=>line.textContent.includes(marker));
      if(cursor.hidden||!line)return false;
      const bounds=pre.getBoundingClientRect(),caret=cursor.getBoundingClientRect();
      const range=document.createRange();range.selectNodeContents(line);
      const intersects=rect=>rect.bottom>bounds.top&&rect.top<bounds.bottom&&rect.bottom>0&&rect.top<innerHeight;
      return intersects(caret)&&caret.left>=bounds.left&&caret.right<=bounds.right&&[...range.getClientRects()].some(intersects);
    },marker);
  }
  for(const [name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
    await page.setViewportSize({width,height});await page.evaluate(enabled=>terminalFocus(enabled),width<760);
    await page.locator('#terminal-screen').click();
    await page.waitForFunction(()=>directMode&&document.activeElement===document.getElementById('terminal-keyboard'));
    const marker=name.toUpperCase(),before=Date.now();
    await page.keyboard.insertText(marker);
    await page.waitForFunction(marker=>latestFrame.screen.includes(marker),marker);
    latencies.push({name,ms:Date.now()-before});
    await page.waitForFunction(()=>!directSending&&!directQueue.length);
    assert.equal(await page.evaluate(()=>latestFrame.sessionID),sessionID);
    assert.equal(await page.evaluate(()=>latestFrame.streamID),streamID);
    assert.equal(await page.locator('#automatic').isChecked(),true);
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'Page overflow at '+name);
    await visibleTerminal(marker);
    assert.equal(await page.locator('#follow').isChecked(),true,'Viewport changes must retain cursor following');
    await page.screenshot({path:path.join(output,name+'.png')});screenshots.push(name+'.png');
  }
  await page.evaluate(()=>{const pre=document.getElementById('terminal-screen');pre.scrollTop=pre.scrollHeight;});
  await page.waitForFunction(()=>!document.getElementById('follow').checked);
  await page.locator('#jump-latest').click();await visibleTerminal('DESKTOP');
  assert.equal(await page.locator('#follow').isChecked(),true,'Follow must return to the actual tmux cursor');
  await page.setViewportSize({width:390,height:844});await page.evaluate(()=>terminalFocus(true));
  await page.locator('#terminal-screen').click();await page.keyboard.insertText('한글🧪');
  await page.waitForFunction(()=>latestFrame.screen.includes('한글🧪')&&!directSending&&!directQueue.length);
  assert.equal(await page.locator('#follow').isChecked(),true,'Mobile viewport must keep following after returning from manual scroll');
  const beforeArrow=await page.evaluate(()=>latestFrame.cursor);
  await page.keyboard.press('ArrowLeft');
  await page.waitForFunction(old=>latestFrame.cursor.offset!==old.offset||latestFrame.cursor.padding!==old.padding,beforeArrow);
  await page.waitForFunction(()=>!directSending&&!directQueue.length);
  await visibleTerminal('한글🧪');
  assert.equal(await page.evaluate(()=>latestFrame.cursor.padding),1,'Arrow enters the second cell of the wide emoji');
  const bytes=await readFile(record);
  assert.equal(bytes.toString('utf8'),'MOBILETABLETDESKTOP한글🧪\x1b[D','Real pane must receive exactly the phone bytes');
  const fetched=await (await fetch(base+'/api/state')).json();
  assert.equal(fetched.sessions.length,1);assert.equal(fetched.sessions[0].session.terminal,'tmux');
  assert.ok(fetched.sessions.every(view=>!view.pty),'No separate PTY created');
  const after=execFileSync(tmux,['-S',socket,'list-panes','-a','-F','#{pane_pid}|#{pane_tty}|#{pane_width}|#{pane_height}'],{encoding:'utf8'}).trim();
  assert.equal(after,original,'Browser must preserve original PID/TTY/80×25 geometry');
  await page.screenshot({path:path.join(output,'mobile-unicode-cursor.png')});screenshots.push('mobile-unicode-cursor.png');
  await page.setViewportSize({width:390,height:544});await visibleTerminal('한글🧪');
  assert.equal(await page.locator('#follow').isChecked(),true,'A smaller mobile keyboard viewport must retain cursor following');
  await page.screenshot({path:path.join(output,'mobile-small-viewport.png')});screenshots.push('mobile-small-viewport.png');
  await page.setViewportSize({width:390,height:844});await visibleTerminal('한글🧪');
  assert.equal(await page.locator('#follow').isChecked(),true,'Restoring mobile height must retain cursor following');
  await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});
  await page.screenshot({path:path.join(output,'mobile-dark.png')});screenshots.push('mobile-dark.png');
  assert.deepEqual(errors,[]);
  const report={checks:['real tmux RGB/cursor over Swift SSE','mobile/tablet/desktop direct input while automation ON','visible active output/cursor at every viewport','manual scroll pauses follow; return follows original cursor','viewport and mobile height changes retain cursor following','exact Korean/emoji/arrow bytes and wide-cell cursor','same original PID/TTY/geometry, no extra PTY'],latencies,screenshots,errors};
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{
  if(browser)await browser.close();
  if(fixture&&fixture.exitCode===null){fixture.kill('SIGTERM');await Promise.race([new Promise(resolve=>fixture.once('exit',resolve)),new Promise(resolve=>setTimeout(resolve,5000))]);}
  if(created){try{execFileSync(tmux,['-S',socket,'kill-server'],{stdio:'ignore',timeout:5000});}catch{}}
  await rm(directory,{recursive:true,force:true});
}
