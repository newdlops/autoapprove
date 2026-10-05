// Real Chromium -> production Swift HTTP/SSE -> inert original input adapter.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const directory=await mkdtemp(path.join(tmpdir(),'aa-live-input-'));
const output=path.resolve('dist/qa/live-input-stability');await mkdir(output,{recursive:true});
let fixture,browser,page,stage='startup';const checks=[],screenshots=[],errors=[];
try {
  const cache=path.resolve('.build/cache/LiveInputStability');await mkdir(cache,{recursive:true});
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary=path.join(directory,'LiveInputStability');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/live-input-stability.swift','-o',binary],{stdio:'inherit'});
  fixture=spawn(binary,[directory],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',data=>stderr+=data);
  let port;for(let i=0;i<300&&!port;i++){try{port=Number(await readFile(path.join(directory,'port'),'utf8'));}catch{}if(fixture.exitCode!==null)throw Error(stderr);if(!port)await new Promise(resolve=>setTimeout(resolve,50));}
  assert.ok(port,'Isolated server did not start');const base='http://127.0.0.1:'+port;
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
  page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(15000);
  page.on('pageerror',error=>errors.push(error.message));
  const observer=await browser.newPage({viewport:{width:768,height:1024}});
  async function select(target){await target.goto(base);await target.locator('.session-row').first().click();await target.waitForFunction(()=>latestFrame?.streamID&&!$('terminal-keyboard').disabled);}
  await select(page);await select(observer);await page.locator('#terminal-screen').click();
  const binding=await page.evaluate(()=>({sessionID:latestFrame.sessionID,streamID:latestFrame.streamID,pid:selectedItem.session.pid,tty:selectedItem.session.tty}));
  let expected='';async function type(value){expected+=value;await page.keyboard.insertText(value);}
  async function drained(){await page.waitForFunction(()=>!directSending&&!directQueue.length&&!inputInFlight);assert.equal((await readFile(path.join(directory,'input.bin'))).toString(),expected);await page.waitForFunction(value=>latestFrame?.screen.endsWith(value)&&!terminalStream?.reconnecting,expected);}
  await type('BEFORE-');await drained();
  stage='background monitor fails while selected read is pending';await writeFile(path.join(directory,'monitor-fault'),'');
  for(let i=0;i<20;i++){await type('m'+i+'한');await page.waitForTimeout(80);}
  await page.waitForFunction(()=>!directSending&&!directQueue.length);await drained();
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'terminal-keyboard','Independent background monitoring must not disconnect an active original input');
  assert.equal(await page.evaluate(()=>!!inputFailure||!!terminalStreamFailed),false);
  assert.equal((await readFile(path.join(directory,'monitor-triggered'))).length,0);
  checks.push('background monitor failure during a pending source read preserves focused sustained original input with two viewers');
  stage='temporary selected-screen read failure';await writeFile(path.join(directory,'read-fault'),'');
  await page.waitForFunction(()=>$('terminal-live').textContent.includes('재연결'));
  const before=(await readFile(path.join(directory,'input.bin'))).length;
  await type('READER-한글');await page.waitForTimeout(1200);
  assert.equal((await readFile(path.join(directory,'input.bin'))).length,before);
  assert.equal(await page.evaluate(()=>document.activeElement?.id),'terminal-keyboard');
  await page.screenshot({path:path.join(output,'mobile-read-reconnecting.png')});screenshots.push('mobile-read-reconnecting.png');
  await rm(path.join(directory,'read-fault'));await drained();
  checks.push('temporary selected-screen read failure pauses dispatch and resumes only unsent bytes without blurring');
  stage='sustained typing';
  for(const [name,width,height]of[['mobile',390,544],['tablet',768,1024],['desktop',1440,900]]){
    await page.setViewportSize({width,height});await page.evaluate(enabled=>terminalFocus(enabled),width<760);await page.locator('#terminal-screen').click();
    for(let i=0;i<16;i++){await type(name+i+'·');await page.waitForTimeout(95);}
    await drained();assert.deepEqual(await page.evaluate(()=>({sessionID:latestFrame.sessionID,streamID:latestFrame.streamID,pid:selectedItem.session.pid,tty:selectedItem.session.tty})),binding);
    assert.equal(await page.evaluate(()=>document.activeElement?.id),'terminal-keyboard');assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    await page.screenshot({path:path.join(output,name+'-sustained.png')});screenshots.push(name+'-sustained.png');
  }
  checks.push('continuous Unicode input across mobile/tablet/desktop keeps the same stream/PID/TTY and exact single delivery');
  stage='explicit permission denial';await rm(path.join(directory,'monitor-fault'));await writeFile(path.join(directory,'permission-fault'),'');
  await page.waitForFunction(()=>!directMode&&$('terminal-keyboard').disabled);
  const beforeDenied=(await readFile(path.join(directory,'input.bin'))).length;
  await page.keyboard.insertText('MUST-NOT-SEND');await page.waitForTimeout(250);
  assert.equal((await readFile(path.join(directory,'input.bin'))).length,beforeDenied);
  checks.push('explicit permission denial still stops original input even after a temporary monitor failure');
  assert.deepEqual(errors,[]);const report={result:'PASS',checks,screenshots,errors,bytes:Buffer.byteLength(expected),scope:'Chromium and production Swift with inert adapters; no user CLI input or physical phone'};
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
  await Promise.all(['failure.png','failure.json'].map(name=>rm(path.join(output,name),{force:true})));
}catch(error){const detail=await page?.evaluate(()=>({directMode,inputFailure,streamFailed:!!terminalStreamFailed,reason:$('input-reason').textContent,state:$('terminal-live').textContent,queue:directQueue.length,active:document.activeElement?.id})).catch(()=>null);await page?.screenshot({path:path.join(output,'failure.png')}).catch(()=>{});await writeFile(path.join(output,'failure.json'),JSON.stringify({stage,error:error.message,detail},null,2));throw error;
}finally{await browser?.close();if(fixture&&fixture.exitCode===null){fixture.kill();await new Promise(resolve=>fixture.once('exit',resolve));}await rm(directory,{recursive:true,force:true});}
