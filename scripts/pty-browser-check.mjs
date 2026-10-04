// Actual browser + actual controlling PTY; only inert private CLI fixtures.
import { spawn } from 'node:child_process';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const output=path.resolve('dist/qa/pty'); await mkdir(output,{recursive:true});
const server=spawn(process.execPath,['scripts/pty-integration-check.mjs','--release','--serve'],{stdio:['ignore','pipe','inherit']});
let browser;
const errors=[],checks=[],screenshots=[],latencies=[],expectedLeaseResponses=[];
const requests={stream:0,output:0,attach:0,input:0};
const closedOnly=process.argv.includes('--closed-pty-only');
const endedViewportOnly=process.argv.includes('--ended-viewport-only');
const naturalOnly=process.argv.includes('--natural-exit-only')||endedViewportOnly;
const endedOnly=closedOnly||naturalOnly;
let outputBackpressure;
try {
  const info=await new Promise((resolve,reject)=>{ let text=''; const timer=setTimeout(()=>reject(new Error('PTY fixture startup timed out: '+text.slice(-4000))),45000); server.stdout.on('data',data=>{text+=data;for(const line of text.split('\n'))try{const value=JSON.parse(line);if(value.url){clearTimeout(timer);resolve(value);return;}}catch{}});server.on('exit',code=>{clearTimeout(timer);reject(new Error('PTY server exited '+code));}); });
  console.log('PTY browser fixture ready; Swift compile cache released');
  const resumedID=new RegExp('RESUMED-ID:\\s*'+[...info.conversationID].map(char=>char+'\\s*').join(''));
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH || undefined});
  const page=await browser.newPage({viewport:endedViewportOnly?{width:1440,height:900}:{width:390,height:844},isMobile:!endedViewportOnly,hasTouch:!endedViewportOnly});
  page.setDefaultTimeout(12000);page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{
    if(message.type()!=='error')return;
    const location=message.location().url;
    if(message.text().includes('status of 409')&&location.includes('/api/pty/resize'))expectedLeaseResponses.push(message.text());else errors.push(message.text());
  });
  page.on('request',request=>{const pathname=new URL(request.url()).pathname;if(pathname==='/api/pty/stream')requests.stream++;if(pathname==='/api/pty/output')requests.output++;if(pathname==='/api/pty'&&request.method()==='POST')requests.attach++;if(pathname==='/api/pty/input')requests.input++;});
  const contents=()=>page.evaluate(()=>{const buffer=ptyClient?.term.buffer.active;if(!buffer)return '';let text='';for(let row=0;row<buffer.length;row++){const line=buffer.getLine(row);text+=(line?.isWrapped?'':'\n')+(line?.translateToString(true)||'');}return text;});
  async function visible(pattern){ const deadline=Date.now()+10000;while(Date.now()<deadline){if(pattern.test(await contents()))return;await page.waitForTimeout(50);}console.error(JSON.stringify(await page.evaluate(()=>({focus:document.activeElement?.className,ready:ptyClient?.ready,blocked:ptyClient?.blocked,queue:ptyClient?.queue.length,sequence:ptyClient?.sequence,disabled:ptyClient?.term.options.disableStdin,textarea:ptyClient?.term.textarea.value,error:ptyClient?.error}))),errors);assert.match(await contents(),pattern); }
  async function ready(){await page.waitForFunction(()=>ptyClient?.ready===true);}
  async function type(value){await page.locator('#terminal-keyboard-toggle').click();for(const fragment of value.split(/([\r\x03])/)){if(fragment==='\r')await page.keyboard.press('Enter');else if(fragment==='\x03')await page.keyboard.press('Control+c');else if(fragment)await page.keyboard.type(fragment);}}
  async function enter(){await page.locator('#send-input').click();}
  async function capture(name){await page.screenshot({path:path.join(output,name+'.png')});screenshots.push(name);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,name+' must fit');}
  async function refreshInventory(){await page.waitForFunction(()=>!loadingNetwork);await page.evaluate(()=>refreshNetwork());}
  async function verifyEndedView(attached,original){
    const finalScreen=await contents();
    await page.evaluate(()=>{window.qaEndedClient=ptyClient;});
    await refreshInventory();
    assert.equal(await page.evaluate(()=>ptyClient===window.qaEndedClient),true,'Removing an ended PTY from inventory must preserve its open terminal');
    assert.equal(await contents(),finalScreen,'Inventory refresh must preserve the final terminal screen');
    assert.match(await page.locator('#terminal-live').innerText(),/PTY 종료/);
    assert.equal(await page.locator('#session-ended').isVisible(),false,'A retained ended PTY must keep its readable terminal view');
    assert.equal(await page.locator('#send-input').isDisabled(),true);
    assert.equal(await page.locator('#close-pty').isDisabled(),true);
    assert.equal(await page.evaluate(id=>allSessions.some(item=>item.view.ptyID===id),attached.ptyID),false,'An ended PTY must leave the running session list');
    const active=await (await fetch(info.url+'/api/state')).json();
    const remaining=active.sessions.filter(view=>view.ptyID===attached.ptyID||view.session.pid===attached.pid);
    assert.deepEqual(remaining,[],'The native active inventory must exclude the ended PTY and detected CLI: '+JSON.stringify(remaining));
    const counts=await page.evaluate(()=>({sessions:allSessions.length,list:$('session-count').textContent,node:nodes.find(node=>node.local).state.sessions.length,machine:machineRows.get(nodes.find(node=>node.local).id).querySelector('.machine-status').textContent}));
    assert.equal(counts.list,counts.sessions+'개');assert.equal(await page.locator('.session-row').count(),counts.sessions);assert.equal(counts.node,active.sessions.length);assert.match(counts.machine,new RegExp('^'+counts.node+'개 세션'));
    process.kill(original.session.pid,0);
    const attachBefore=requests.attach;
    await page.locator('#terminal-back').click();await capture(endedViewportOnly?'desktop-ended-viewport-running-list':endedOnly?'mobile-'+(closedOnly?'closed':'natural-exit')+'-running-list':'desktop-ended-running-list');
    await page.locator('.session-row').filter({hasText:'기존 대화 · PTY 검증'}).first().click();
    await page.waitForFunction(id=>ptyClient?.descriptor.ptyID===id&&ptyClient.descriptor.exitCode!=null&&ptyClient.offset!=null,attached.ptyID);
    assert.equal(await page.evaluate(()=>ptyClient.descriptor.pid),attached.pid,'Selecting the original again must retain the ended continuation rather than fork');
    assert.equal(requests.attach,attachBefore+1,'A deliberate original selection must verify reuse once');
    await refreshInventory();
    assert.equal(await page.evaluate(id=>allSessions.some(item=>item.view.ptyID===id),attached.ptyID),false,'An ended reuse descriptor must never reenter the active list');
    await page.reload();await page.waitForFunction(id=>ptyClient?.descriptor.ptyID===id&&ptyClient.descriptor.exitCode!=null&&ptyClient.offset!=null,attached.ptyID);
    assert.equal(await page.evaluate(()=>ptyClient.descriptor.pid),attached.pid,'Reloading an ended original selection must not fork');
    await visible(endedOnly?/RECEIVED:EXPLICIT-CLOSE-MARK/:/RECONNECT-MARK/);
    const viewportText=await page.evaluate(()=>{const buffer=ptyClient.term.buffer.active;return Array.from({length:ptyClient.term.rows},(_,row)=>buffer.getLine(buffer.viewportY+row)?.translateToString(true)||'').join('\n');});
    assert.match(viewportText,endedOnly?/RECEIVED:EXPLICIT-CLOSE-MARK/:/RECONNECT-MARK/,'The final output must appear in the visible terminal viewport after ended reload');
    assert.match(await page.locator('#terminal-live').innerText(),/PTY 종료/);assert.equal(await page.locator('#send-input').isDisabled(),true);
    await capture(endedViewportOnly?'desktop-ended-viewport-retained':endedOnly?'mobile-'+(closedOnly?'ended':'natural-exit')+'-retained':'desktop-ended-retained');process.kill(original.session.pid,0);
    checks.push('ended PTY leaves active rows and machine counts, retains final output, and original reselection/reload never forks');
  }
  await page.goto(info.url); await page.locator('.session-row').filter({hasText:'PTY ·'}).first().waitFor();
  assert.equal(requests.attach,0,'The dashboard must not start a CLI by default');
  if(endedOnly){
    const before=await (await fetch(info.url+'/api/state')).json(),original=before.sessions.find(view=>view.title==='기존 대화 · PTY 검증');assert.ok(original);
    let holdInventory=closedOnly;const held=[];
    await page.route(/\/api\/network(?:\?.*)?$/,async route=>{if(holdInventory)held.push(route);else await route.continue();});
    await page.evaluate(()=>void refreshNetwork());await page.waitForTimeout(100);
    await page.locator('.session-row').filter({hasText:'기존 대화 · PTY 검증'}).first().click();await ready();
    if(endedViewportOnly){await page.locator('#terminal-focus').click();await ready();await page.waitForTimeout(300);}
    if(closedOnly)assert.equal(await page.evaluate(()=>ptyTemporary.has(selectedKey)),true,'This regression must close before the inventory reconciles the temporary PTY');
    const attached=await page.evaluate(()=>({pid:ptyClient.descriptor.pid,ptyID:ptyClient.descriptor.ptyID}));
    await type('EXPLICIT-CLOSE-MARK\r');await visible(/RECEIVED:EXPLICIT-CLOSE-MARK/);
    if(closedOnly){await page.locator('#terminal-settings summary').click();page.once('dialog',dialog=>dialog.accept());await page.locator('#close-pty').click();}
    else{await page.waitForFunction(()=>allSessions.some(item=>item.session.agent==='codex'&&item.session.pid===ptyClient.descriptor.pid));await page.locator('[data-key="eof"]').click();}
    await page.waitForFunction(()=>ptyClient?.descriptor.exitCode!=null);if(closedOnly)await page.locator('#terminal-settings summary').click();
    holdInventory=false;await Promise.all(held.map(route=>route.continue()));await page.unroute(/\/api\/network(?:\?.*)?$/);
    await verifyEndedView(attached,original);
    checks.push(closedOnly?'explicit UI close before inventory reconciliation never reinserts the temporary PTY':'natural CLI exit immediately retires its detected owned session');
  }else{
  await page.locator('.session-row').filter({hasText:'PTY ·'}).first().click();await ready();
  for (const key of ['escape','interrupt','eof','tab','up','down','left','right','backspace']) assert.equal(await page.locator(`[data-key="${key}"]`).isVisible(),true,`PTY must restore ${key} after a restricted mirror`);
  assert.equal(await page.locator('#terminal-input').isVisible(),false);assert.equal(await page.locator('#terminal-screen').isVisible(),false);
  await type("printf 'DIRECT=한글😀\\n'\r");await visible(/(?:^|\n)DIRECT=한글😀[ \t]*(?:\n|$)/);
  assert.equal(await page.evaluate(()=>document.activeElement===ptyClient.term.textarea),true);
  checks.push('actual screen input, UTF-8, no compose field');await capture('mobile-direct-shell');
  await type("printf 'AB\\n'");await page.keyboard.press('ArrowLeft');await page.keyboard.press('ArrowLeft');await page.keyboard.press('ArrowLeft');await page.keyboard.press('ArrowLeft');await page.keyboard.insertText('X');await enter();await visible(/(?:^|\n)AXB[ \t]*(?:\n|$)/);
  await type("printf 'BACKSPACE=ab\\n'");for(let n=0;n<4;n++)await page.keyboard.press('ArrowLeft');await page.keyboard.press('Backspace');await enter();await visible(/(?:^|\n)BACKSPACE=b[ \t]*(?:\n|$)/);
  await type("printf '\\033[31mORIGINAL-RED\\033[0m\\n\\033[2;8HCURSOR-HERE'\r");await visible(/ORIGINAL-RED/);
  checks.push('real line editor cursor arrows, Backspace and ANSI output');await capture('mobile-ansi-cursor');
  const cursor=await page.evaluate(()=>({row:ptyClient.term.buffer.active.cursorY,col:ptyClient.term.buffer.active.cursorX}));assert.ok(cursor.row>=0&&cursor.col>=0);
  // Slow the renderer while the actual shell produces output. Receiving must
  // stay bounded, resume from rendered bytes, and leave Ctrl C usable.
  await page.evaluate(()=>{
    const client=ptyClient;client.qaFlow={maxBytes:0,maxEvents:0,pauses:0};
    client.qaReceive=client.receive.bind(client);client.receive=update=>{client.qaReceive(update);client.qaFlow.maxBytes=Math.max(client.qaFlow.maxBytes,client.outputBytes);client.qaFlow.maxEvents=Math.max(client.qaFlow.maxEvents,client.outputQueue.length);if(client.outputPaused)client.qaFlow.pauses++;};
    client.qaWrite=client.term.write.bind(client.term);client.term.write=(bytes,callback)=>client.qaWrite(bytes,()=>{if(!client.qaFlow.released&&!client.qaHeld)client.qaHeld=callback;else callback();});
  });
  await type('yes BROWSER-FLOOD\r');await page.waitForTimeout(600);await page.locator('[data-key="interrupt"]').click();
  await type("printf 'AFTER-BROWSER-FLOOD\\n'\r");
  await page.evaluate(()=>{const client=ptyClient;client.qaFlow.released=true;client.term.write=client.qaWrite;const callback=client.qaHeld;client.qaHeld=null;callback?.();});
  await visible(/(?:^|\n)AFTER-BROWSER-FLOOD[ \t]*(?:\n|$)/);
  outputBackpressure=await page.evaluate(()=>{const client=ptyClient;client.receive=client.qaReceive;client.term.write=client.qaWrite;return client.qaFlow;});
  assert.ok(outputBackpressure.pauses>0,'Slow rendering must exercise stream backpressure');
  assert.ok(outputBackpressure.maxBytes<=512000,'Ordinary output queue must remain below its byte cap');
  assert.ok(outputBackpressure.maxEvents<=64,'Output event queue must remain bounded');
  checks.push('actual output flood with a slow renderer stays bounded and remains interruptible');
  await page.locator('#terminal-settings summary').click();await page.locator('#font-larger').click();await page.locator('#terminal-settings summary').click();await ready();
  await page.setViewportSize({width:390,height:500});await page.waitForTimeout(350);await type('stty size\r');await visible(/\b\d+ \d+\b/);await capture('mobile-keyboard-height');
  await page.setViewportSize({width:390,height:844});
  await page.locator('#terminal-settings summary').click();page.once('dialog',dialog=>dialog.dismiss());await page.locator('#close-pty').click();assert.equal(await page.evaluate(()=>ptyClient.descriptor.exitCode),undefined);await page.locator('#terminal-settings summary').click();
  const oldPage=await browser.newPage({viewport:{width:768,height:1024}}),oldRequests={attach:0,stream:0,output:0,input:0,resize:0};
  oldPage.on('pageerror',error=>errors.push(error.message));
  oldPage.on('request',request=>{const url=new URL(request.url()),name=url.pathname;if(name==='/api/pty')oldRequests.attach++;if(name==='/api/pty/stream')oldRequests.stream++;if(name==='/api/pty/output'){oldRequests.output++;assert.equal(url.searchParams.has('client'),false,'Old snapshot viewing must not claim a writer');}if(name==='/api/pty/input')oldRequests.input++;if(name==='/api/pty/resize')oldRequests.resize++;});
  await oldPage.route(/\/api\/network(?:\?.*)?$/,async route=>{const response=await route.fetch(),data=await response.json();for(const node of data.nodes)if(node.state?.release)node.state.release={version:'0.2.41',build:47,api:1};await route.fulfill({response,json:data});});
  await oldPage.goto(info.url);await oldPage.locator('.session-row').filter({hasText:'기존 대화 · PTY 검증'}).click();
  assert.equal(oldRequests.attach,0,'Build 47 must keep original sessions in mirror mode');
  await oldPage.evaluate(id=>selectSession(allSessions.find(item=>item.view.ptyID===id).key,true),info.pty.ptyID);
  await oldPage.waitForFunction(()=>ptyClient?.offset!=null);
  assert.equal(await oldPage.locator('#send-input').isDisabled(),true);
  assert.match(await oldPage.locator('#terminal-live').innerText(),/화면 보기.*업데이트/);
  await oldPage.waitForTimeout(500);assert.deepEqual(oldRequests,{attach:0,stream:0,output:1,input:0,resize:0});
  await oldPage.locator('#terminal-retry').click();await oldPage.waitForFunction(()=>ptyClient?.offset!=null);
  assert.deepEqual(oldRequests,{attach:0,stream:0,output:2,input:0,resize:0});await oldPage.close();
  checks.push('build47 original sessions stay mirrored and existing PTYs offer one read-only snapshot with manual refresh');
  await page.locator('#terminal-back').click();
  const before=await (await fetch(info.url+'/api/state')).json();
  const original=before.sessions.find(view=>view.title==='기존 대화 · PTY 검증');assert.ok(original);
  // Hold a whole-inventory request to prove that an unrelated slow Mac cannot
  // delay opening the descriptor returned by this deliberate selection.
  let holdInventory=true;const held=[];
  await page.route(/\/api\/network(?:\?.*)?$/,async route=>{if(holdInventory)held.push(route);else await route.continue();});
  await page.evaluate(()=>void refreshNetwork());
  const holdDeadline=Date.now()+3000;while(!held.length&&Date.now()<holdDeadline)await page.waitForTimeout(20);assert.ok(held.length);
  await page.locator('.session-row').filter({hasText:'기존 대화 · PTY 검증'}).first().click();await ready();await visible(resumedID);
  assert.equal(await page.locator('#pty-dialog').isVisible(),false,'One selection must attach without a dialog');
  assert.equal(requests.attach,1,'One deliberate original selection must issue one attach');
  assert.equal(await page.evaluate(()=>loadingNetwork),true,'The returned descriptor must open while inventory is held');
  assert.equal(await page.locator('#automatic').isChecked(),original.session.automatic,'Attach must inherit the configured automatic flag');
  const attached=await page.evaluate(()=>({pid:ptyClient.descriptor.pid,ptyID:ptyClient.descriptor.ptyID,streamID:ptyClient.descriptor.streamID}));
  assert.notEqual(attached.pid,original.session.pid,'An owned conversation continuation is a separate PTY');
  process.kill(original.session.pid,0);
  assert.equal(new URLSearchParams(new URL(page.url()).hash.slice(1)).get('session'),original.session.id,'The saved selection must retain original identity');
  holdInventory=false;await Promise.all(held.map(route=>route.continue()));await page.unroute(/\/api\/network(?:\?.*)?$/);
  checks.push('one-click attach without dialog or inventory wait, inherited automatic setting and original process alive');
  await page.locator('#terminal-back').click();await page.locator('.session-row').filter({hasText:'기존 대화 · PTY 검증'}).first().click();await ready();
  assert.deepEqual(await page.evaluate(()=>({pid:ptyClient.descriptor.pid,ptyID:ptyClient.descriptor.ptyID,streamID:ptyClient.descriptor.streamID})),attached);
  assert.equal(requests.attach,2,'Returning to the original row must reverify its current conversation before reusing the PTY');
  await page.reload();await ready();await visible(resumedID);
  assert.deepEqual(await page.evaluate(()=>({pid:ptyClient.descriptor.pid,ptyID:ptyClient.descriptor.ptyID,streamID:ptyClient.descriptor.streamID})),attached);
  assert.equal(requests.attach,3,'Reload must verify the saved original conversation once');
  const reused=await (await fetch(info.url+'/api/state')).json();
  assert.equal(new Set(reused.sessions.filter(view=>view.pty?.program==='codex').map(view=>view.ptyID)).size,1,'Reload must not fork another conversation');
  process.kill(original.session.pid,0);
  checks.push('return selection and reload reuse the same PTY, stream and PID without another fork');
  const streamsBefore=requests.stream,inputsBefore=requests.input;
  for(let sample=0;sample<5;sample++){
    const marker='STREAM-LATENCY-'+sample+'-'+Date.now();
    const started=Date.now();await type(marker+'\r');await visible(new RegExp('RECEIVED:'+marker));latencies.push(Date.now()-started);
  }
  assert.equal(requests.output,0,'Browser PTY output must stream without polling reads');
  assert.equal(requests.stream,streamsBefore,'Live byte delivery must reuse one EventSource');
  assert.ok(Math.max(...latencies)<1000,'Fixture streaming and render latency must stay below 1 second');
  assert.ok(requests.input>inputsBefore);
  checks.push('live byte streaming latency and bounded read request count');
  const beforeFailure={...requests};
  await page.evaluate(()=>{ptyClient.enqueue('NO-AUTO-REPLAY');ptyClient.source.dispatchEvent(new Event('error'));});
  await page.waitForFunction(()=>ptyClient?.blocked&&!ptyClient.ready);
  assert.equal(await page.locator('#send-input').isDisabled(),true);
  assert.equal(await page.locator('#terminal-retry').isVisible(),true);
  await page.waitForTimeout(1200);
  assert.equal(requests.stream,beforeFailure.stream,'A failed stream must not reconnect automatically');
  assert.equal(requests.input,beforeFailure.input,'A failed stream must stop unsent input');
  await capture('mobile-stream-error');
  await page.locator('#terminal-retry').click();await ready();
  assert.equal(await page.evaluate(()=>ptyClient.descriptor.pid),attached.pid);
  assert.equal(requests.input,beforeFailure.input,'Explicit output retry must not replay input');
  assert.equal(await page.locator('#pty-unsent').isVisible(),true);
  assert.match(await page.locator('#pty-unsent-text').inputValue(),/NO-AUTO-REPLAY/);
  assert.doesNotMatch(await contents(),/NO-AUTO-REPLAY/);
  checks.push('injected stream interruption stops input, explicit retry restores the same PTY without replay');
  // Fake codex has an open rollout tied to the original exact process. The first
  // selection launches its recorded fork; reuse leaves both processes alive.
  await page.locator('#terminal-focus').click();await page.waitForFunction(()=>selectedItem?.session.agent==='codex');
  assert.equal(await page.locator('#automatic').isChecked(),original.session.automatic);
  await page.locator('#automatic').check();await page.waitForFunction(()=>!mutation&&selectedItem?.session.automatic===true);await page.locator('#terminal-focus').click();
  await type('AUTO-ON=한글\r');await visible(/RECEIVED:AUTO-ON=한글/);
  assert.equal(await page.locator('#automatic').isChecked(),true);
  await type('permission\r');await visible(/AUTO-APPROVED/);
  checks.push('real PTY input while auto on and actual engine approval to same PTY');await capture('mobile-auto-on');
  const state=await (await fetch(info.url+'/api/state')).json();assert.ok(state.sessions.some(view=>view.title==='기존 대화 · PTY 검증'),'Original CLI must remain running');
  checks.push('exact existing conversation fork and original session preservation');
  await type('tui\r');await visible(/ORIGINAL-TUI/);
  assert.deepEqual(await page.evaluate(()=>({type:ptyClient.term.buffer.active.type,row:ptyClient.term.buffer.active.cursorY,col:ptyClient.term.buffer.active.cursorX,color:ptyClient.term.buffer.active.getLine(0).getCell(0).getFgColor()})),{type:'alternate',row:4,col:8,color:0x0cea38});
  await page.reload();await ready();await visible(/ORIGINAL-TUI/);assert.equal(await page.evaluate(()=>ptyClient.term.buffer.active.type),'alternate');await capture('mobile-alternate-reconnected');
  await type('normal\r');await visible(/RETURNED-FROM-TUI/);assert.equal(await page.evaluate(()=>ptyClient.term.buffer.active.type),'normal');
  checks.push('original RGB, exact cursor position and alternate-screen reconnection');
  await type('RECONNECT-MARK\r');await visible(/RECEIVED:RECONNECT-MARK/);await page.reload();await ready();await visible(/RECONNECT-MARK/);
  checks.push('reload reconnects same process and restores current screen');
  for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.waitForTimeout(400);await capture(name+'-continued-pty');}
  await type('\x03');await visible(/INTERRUPTED/);await page.locator('[data-key="eof"]').click();await page.waitForFunction(()=>ptyClient?.descriptor.exitCode!=null);assert.equal(await page.locator('#send-input').isDisabled(),true);await capture('desktop-ended');
  checks.push('Ctrl C, Ctrl D and ended input state');
  await verifyEndedView(attached,original);
  }
  assert.deepEqual(errors,[],'No browser or CSP errors');
  await writeFile(path.join(output,closedOnly?'closed-report.json':endedViewportOnly?'viewport-report.json':naturalOnly?'natural-report.json':'report.json'),JSON.stringify({checks,screenshots,errors,expectedLeaseResponses,requests,streamingLatencyMs:latencies,outputBackpressure,physicalPhoneSafariIME:'not tested'},null,2)+'\n');
  console.log(JSON.stringify({result:'PASS',checks,screenshots,errors,expectedLeaseResponses,requests,streamingLatencyMs:latencies,outputBackpressure}));
} finally {
  await browser?.close();server.kill('SIGTERM');await new Promise(resolve=>{if(server.exitCode!==null||server.signalCode!==null)resolve();else server.once('exit',resolve);});
}
