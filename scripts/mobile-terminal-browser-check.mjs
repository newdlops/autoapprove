// Real browser, synthetic loopback API. No input is sent to a user's terminal.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
const { chromium } = await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const output = path.resolve('dist/qa/mobile-terminal'); await mkdir(output, { recursive: true });
const keys = ['text','submit','characters','enter','escape','interrupt','up','down','left','right','backspace','delete','home','end','tab'];
const sessions = ['one','two'].map((id, i) => ({
  session: { id, agent: i ? 'claude' : 'codex', terminal: 'iterm', hostName: '검증용 터미널', phase: 'idle', cwd: '/fixture/mobile-terminal', tty: '/dev/fixture-' + id, automatic: !i, detail: '합성 데이터', queuedQuestions: [] },
  title: i ? '두 번째 검증 세션' : '한글과 긴 프로젝트 이름 · 모바일 터미널 검증', phaseTitle: '입력 대기', canApprove: true, canReveal: true, canRead: true, keys
}));
const screens = new Map(sessions.map(view => [view.session.id, '모바일 터미널 검증 · 합성 데이터\n\n' + Array.from({length: 90}, (_, i) => `출력 ${i} · 한글 🧪 · ${'long-text-'.repeat(10)}`).join('\n') + '\n› ']));
const operations = [], receipts = new Map(), revisions = new Map([['one',0],['two',0]]);
const cursors = new Map();
const streamIDs = new Map([['one','stream-one'],['two','stream-two']]);
let inputDelay = 180, failNext = false, blockInput = false, frameError = false, activeKeys = keys;
const network = () => ({ updatedAt: new Date().toISOString(), nodes: [{ id: 'fixture-mac', name: '검증용 Mac', local: true, online: true, state: { sessions: sessions.map(view => ({...view, keys: activeKeys, inputReason: blockInput ? '화면 연결을 확인해주세요.' : undefined})), snapshot: { paused: false, events: [] } } }] });
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const json = (status, value) => { const body = JSON.stringify(value); res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(body); };
  try {
    if (url.pathname === '/api/network') return json(200, network());
    if (url.pathname === '/api/terminal') {
      if (frameError) return json(503, { error: '검증용 연결 끊김 · 화면을 다시 연결해주세요.' });
      const id = url.searchParams.get('session'), revision = String(revisions.get(id));
      return json(200, { sessionID: id, revision, streamID: streamIDs.get(id), cursor: cursors.get(id) || {offset:screens.get(id).length,padding:0,visible:true,style:'block',blink:true}, observedAt: new Date().toISOString(), keys: activeKeys, inputReason: blockInput ? '화면 연결을 확인해주세요.' : undefined, ...(url.searchParams.get('revision') === revision ? {} : { screen: screens.get(id) }) });
    }
    if (url.pathname === '/api/input') {
      let body = ''; for await (const chunk of req) body += chunk;
      const input = JSON.parse(body);
      if (receipts.has(input.requestID)) return json(200, receipts.get(input.requestID));
      if ((input.relay ? input.streamID !== streamIDs.get(input.sessionID) : input.revision !== String(revisions.get(input.sessionID))) || blockInput) return json(409, { error: '화면이 달라졌습니다. 확인 후 다시 입력해주세요.' });
      operations.push(input); revisions.set(input.sessionID, revisions.get(input.sessionID) + 1);
      screens.set(input.sessionID, screens.get(input.sessionID) + '\n[검증용 전달] ' + (input.text || input.kind));
      const fail = failNext; failNext = false;
      await new Promise(resolve => setTimeout(resolve, inputDelay));
      if (fail) return json(503, { error: '전달 결과를 확인하지 못했습니다. 현재 터미널을 확인해주세요.' });
      const receipt = { message: '검증용 터미널에 입력했습니다.' }; receipts.set(input.requestID, receipt); return json(200, receipt);
    }
    if (url.pathname === '/api/action') return json(200, { message: '검증용 변경' });
    const name = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
    if (!['index.html','app.js','app.css','favicon.svg'].includes(name)) { res.writeHead(404); return res.end(); }
    const data = await readFile(path.resolve('Sources/AutoApproveCore/Resources/RemoteWeb', name));
    res.writeHead(200, { 'Content-Type': name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : name.endsWith('.svg') ? 'image/svg+xml' : 'text/html', 'Cache-Control': 'no-store' }); res.end(data);
  } catch (error) { json(500, { error: error.message }); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
let browser;
const checks = [], screenshots = [], errors = [];
try {
  browser = await chromium.launch({ headless: true, executablePath: process.env.AUTOAPPROVE_CHROMIUM_PATH || undefined });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  page.setDefaultTimeout(12000); page.on('pageerror', error => errors.push(error.message));
  const url = 'http://127.0.0.1:' + server.address().port;
  await page.goto(url); await page.locator('.session-row').first().click();
  const input = page.locator('#terminal-input'), keyboard = page.locator('#terminal-keyboard'), enter = page.locator('#send-input'), compose = page.locator('#compose-input');
  const screen = page.locator('#terminal-screen');
  const focused = () => page.evaluate(() => document.activeElement?.id);
  const ready = () => page.waitForFunction(() => !document.getElementById('terminal-keyboard').disabled);
  await ready();
  assert.equal(await page.locator('#automatic').isChecked(), true);
  assert.equal(await input.isVisible(), false, 'Default terminal must not require a separate input field');
  assert.equal(await page.locator('body').evaluate(body => body.classList.contains('terminal-focus')), true);
  assert.ok((await screen.boundingBox()).height > 600);
  assert.equal(await keyboard.evaluate(element => getComputedStyle(element).fontSize), '16px');
  await page.waitForFunction(() => !document.getElementById('terminal-cursor').hidden);
  const originalCursor = await page.locator('#terminal-cursor').boundingBox();
  const last = screens.get('one').length;
  cursors.set('one',{offset:last-1,padding:0,visible:true,style:'bar',blink:false}); revisions.set('one',revisions.get('one')+1);
  await page.waitForFunction(offset => document.getElementById('terminal-cursor').dataset.offset === String(offset),last-1);
  const movedCursor = await page.locator('#terminal-cursor').boundingBox();
  assert.ok(movedCursor.x < originalCursor.x, 'The original insertion point moves left on the actual output row');
  assert.equal(await screen.textContent(),screens.get('one'),'Cursor overlays must not mutate original terminal output');
  cursors.set('one',{offset:last-1,padding:0,visible:false,style:'bar',blink:false}); revisions.set('one',revisions.get('one')+1);
  await page.waitForFunction(() => document.getElementById('terminal-cursor').hidden);
  cursors.delete('one'); revisions.set('one',revisions.get('one')+1);
  const originalScreen = screens.get('one'), blankRows = '한글 🧪a\n\n';
  screens.set('one',blankRows); revisions.set('one',revisions.get('one')+1);
  cursors.set('one',{offset:blankRows.length,padding:0,visible:true,style:'bar',blink:false});
  await page.waitForFunction(value => terminalValue === value && document.getElementById('terminal-cursor').dataset.offset === String(value.length), blankRows);
  const emptyRow = await page.evaluate(() => {
    const pre=document.getElementById('terminal-screen'), caret=document.getElementById('terminal-cursor'), style=getComputedStyle(pre), root=pre.parentElement.getBoundingClientRect();
    return {actual:parseFloat(caret.style.top)+root.top,expected:pre.getBoundingClientRect().top+parseFloat(style.paddingTop)+2*parseFloat(style.lineHeight)};
  });
  assert.ok(Math.abs(emptyRow.actual-emptyRow.expected)<4, 'Cursor after trailing newlines belongs on the final empty row');
  screens.set('one',originalScreen); cursors.delete('one'); revisions.set('one',revisions.get('one')+1);
  await page.waitForFunction(value => terminalValue === value,originalScreen);
  checks.push('Automation ON keeps typing enabled; real cursor movement and hidden mode preserve exact output');
  async function waitCount(count) {
    const deadline = Date.now() + 12000;
    while (operations.length < count) {
      if (Date.now() >= deadline) console.log(JSON.stringify({pending:operations.slice(-3),state:await page.evaluate(() => ({terminal:selectedItem.session.terminal,mode:composeMode,mutation,inputInFlight,directSending,keys:latestFrame?.keys,reason:document.getElementById('input-reason').textContent}))}));
      assert.ok(Date.now() < deadline, 'Expected '+count+' inputs, received '+operations.length); await page.waitForTimeout(30);
    }
    await page.waitForFunction(() => ['live','changed'].includes(document.getElementById('terminal-live').dataset.state));
  }
  async function directAgain() {
    await input.fill(''); await page.locator('#terminal-settings summary').click(); await compose.uncheck(); await ready();
  }
  async function composition(value) {
    await keyboard.evaluate(element => { element.dispatchEvent(new CompositionEvent('compositionstart', {bubbles:true})); element.value='ㅎ'; element.dispatchEvent(new InputEvent('input', {bubbles:true,isComposing:true,data:'ㅎ'})); });
    await page.waitForTimeout(150);
    assert.equal(await page.locator('#terminal-composition').isVisible(), true);
    const geometry = await page.evaluate(() => ['terminal-composition','terminal-cursor'].map(id => {const style=document.getElementById(id).style;return [parseFloat(style.left),parseFloat(style.top)];}));
    assert.ok(Math.abs(geometry[0][0]-geometry[1][0])<1 && Math.abs(geometry[0][1]-geometry[1][1])<4,'Korean composition is displayed at the terminal insertion point');
    assert.equal(await enter.isDisabled(), true);
    await screen.click(); assert.equal(await focused(),'terminal-keyboard');
    assert.equal(await keyboard.inputValue(),'ㅎ','Tapping output during composition must preserve the unfinished word');
    await keyboard.evaluate((element, value) => { element.value=value; element.dispatchEvent(new CompositionEvent('compositionend', {bubbles:true,data:value})); element.dispatchEvent(new InputEvent('input', {bubbles:true,data:value})); }, value);
  }
  async function paste(value) {
    await keyboard.evaluate((element, value) => { const clipboardData=new DataTransfer(); clipboardData.setData('text/plain',value); element.dispatchEvent(new ClipboardEvent('paste',{bubbles:true,cancelable:true,clipboardData})); }, value);
  }
  let start = operations.length;
  inputDelay=450;
  await page.locator('[data-key="up"]').click();
  while(operations.length===start) await page.waitForTimeout(10);
  await page.locator('[data-key="down"]').click(); await enter.click(); await waitCount(start+3);
  assert.deepEqual(operations.slice(start).map(({kind})=>kind),['up','down','enter']);
  assert.equal(await page.evaluate(()=>directMode),true,'Closed-keyboard buttons arm the current stream without cancelling queued keys');
  inputDelay=180; start=operations.length;
  checks.push('Closed-keyboard Up, Down and Enter bind one stream and preserve FIFO during a slow POST');
  await screen.click();
  assert.equal(await focused(), 'terminal-keyboard', 'Tapping terminal output opens its keyboard capture');
  await page.keyboard.type('direct'); await waitCount(start + 1);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['characters','direct']], 'Terminal typing sends characters before Return');
  assert.equal(await input.isVisible(), false);
  assert.equal(await page.locator('#terminal-keyboard-toggle').getAttribute('aria-pressed'), 'true');
  checks.push('Screen tap focuses 16px keyboard capture and sends characters immediately without a separate editor');
  start = operations.length; inputDelay = 350;
  await page.keyboard.type('a'); while (operations.length === start) await page.waitForTimeout(10);
  assert.equal(await keyboard.isEnabled(), true); assert.equal(await focused(), 'terminal-keyboard');
  await page.keyboard.type('b'); await page.keyboard.press('Enter'); await waitCount(start + 3);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['characters','a'],['characters','b'],['enter','']]);
  inputDelay = 180;
  checks.push('Typing during a slow POST preserves keyboard focus and FIFO character/Return order');
  start = operations.length; await composition('한글'); await waitCount(start + 1); await page.waitForTimeout(200);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['characters','한글']]);
  assert.equal(await page.locator('#terminal-composition').isVisible(), false);
  start = operations.length; await composition('🧪'); await waitCount(start + 1);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['characters','🧪']]);
  start = operations.length; await page.keyboard.press('Backspace'); await waitCount(start + 1);
  await keyboard.evaluate(element => element.dispatchEvent(new InputEvent('beforeinput', {bubbles:true,cancelable:true,inputType:'deleteContentBackward'}))); await waitCount(start + 2);
  assert.deepEqual(operations.slice(start).map(({kind}) => kind), ['backspace','backspace']);
  assert.equal(await keyboard.inputValue(), '\u200b');
  start = operations.length;
  for (const key of ['ArrowUp','ArrowDown','ArrowLeft','ArrowRight','Home','End','Delete','Escape','Control+c','Tab','Shift+Enter']) await page.keyboard.press(key);
  await waitCount(start + 11);
  assert.deepEqual(operations.slice(start).map(({kind}) => kind), ['up','down','left','right','home','end','delete','escape','interrupt','tab','enter']);
  await page.locator('[data-key="up"]').click(); await waitCount(start + 12);
  assert.equal(await focused(), 'terminal-keyboard', 'Onscreen special key retains keyboard focus');
  await page.keyboard.press('Shift+Tab'); assert.notEqual(await focused(), 'terminal-keyboard');
  assert.equal(await focused(),'terminal-screen','Output remains keyboard accessible for reading and scrolling');
  const readingCount=operations.length; await page.keyboard.press('ArrowUp'); await page.keyboard.press('Enter');
  assert.equal(await focused(),'terminal-keyboard'); assert.equal(operations.length,readingCount);
  await page.keyboard.press('Shift+Tab');
  checks.push('Synthetic Korean/emoji IME commits once; hardware/phone Backspace, terminal keys and Shift Tab focus exit');
  await page.locator('#terminal-keyboard-toggle').click(); assert.equal(await focused(), 'terminal-keyboard');
  await page.locator('#terminal-keyboard-toggle').click(); assert.notEqual(await focused(), 'terminal-keyboard');
  const beforeSelection = operations.length;
  const selectionBox = await screen.boundingBox();
  await page.mouse.move(selectionBox.x+14,selectionBox.y+18); await page.mouse.down();
  await page.mouse.move(selectionBox.x+180,selectionBox.y+18,{steps:12}); await page.mouse.up();
  assert.notEqual(await focused(), 'terminal-keyboard', 'Dragging output selects text without reopening keyboard');
  assert.ok(await page.evaluate(() => getSelection().toString().length > 0));
  await page.waitForTimeout(750); assert.equal(operations.length,beforeSelection);
  await screen.evaluate(() => getSelection().removeAllRanges());
  await screen.evaluate(pre => { pre.scrollTop=0; });
  assert.notEqual(await focused(), 'terminal-keyboard');
  await page.locator('#jump-latest').click(); await screen.click(); assert.equal(await focused(), 'terminal-keyboard');
  start = operations.length; await paste('붙여넣기 🧪'); await waitCount(start + 1);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['characters','붙여넣기 🧪']]);
  start = operations.length; await paste('first\nsecond'); await page.waitForTimeout(400);
  assert.equal(operations.length,start,'Multiline paste must not execute without review');
  assert.equal(await input.isVisible(),true); assert.equal(await input.inputValue(),'first\nsecond');
  await input.press('Shift+Enter'); await page.waitForTimeout(180); assert.equal(operations.length,start);
  await input.fill('작성 한글 🧪'); await input.press('Enter');
  while(operations.length === start) await page.waitForTimeout(10);
  assert.equal(await input.isEnabled(),true,'Composed POST keeps mobile editor alive');
  await input.fill('다음 초안'); await waitCount(start + 1);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]),[['submit','작성 한글 🧪']]);
  assert.equal(await input.inputValue(),'다음 초안');
  await input.fill(''); start=operations.length; await enter.click(); await waitCount(start+1); assert.equal(operations.at(-1).kind,'enter');
  checks.push('Keyboard toggle, output selection/scroll, single-line paste, reviewed multiline paste and optional atomic compose/Return');
  await directAgain(); start=operations.length; inputDelay=900;
  await page.keyboard.type('stream-A'); while(operations.length===start) await page.waitForTimeout(10);
  await page.keyboard.type('before-rotation'); streamIDs.set('one','stream-one-B'); revisions.set('one',revisions.get('one')+1);
  await input.waitFor({state:'visible'}); await page.waitForTimeout(1100);
  assert.equal(operations.length,start+1,'Text queued for stream A must never enter stream B');
  assert.equal(await input.inputValue(),'before-rotation'); inputDelay=180;
  checks.push('Connection generation rotation stops and preserves queued text instead of delivering it to a new stream');
  await directAgain(); start=operations.length; inputDelay=400; failNext=true;
  await page.keyboard.type('uncertain'); while(operations.length===start) await page.waitForTimeout(10);
  await page.keyboard.type('pending'); await waitCount(start+1); await input.waitFor({state:'visible'});
  await page.waitForFunction(() => document.getElementById('terminal-input').value==='uncertainpending');
  await page.waitForTimeout(700); assert.equal(operations.length,start+1);
  assert.match(await page.locator('#input-reason').textContent(),/확인/);
  assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),true);
  checks.push('Uncertain response stops direct input, preserves failed and queued characters in original order, never replays');
  await directAgain(); start=operations.length;
  await page.keyboard.type('x'); while(operations.length===start) await page.waitForTimeout(10);
  await page.keyboard.type('y'); await page.locator('#terminal-back').click(); await page.locator('.session-row').nth(1).click(); await ready();
  await page.waitForTimeout(600); assert.equal(operations.length,start+1); assert.equal(operations.at(-1).sessionID,'one');
  await page.locator('#terminal-back').click(); await page.locator('.session-row').first().click(); await input.waitFor({state:'visible'});
  assert.equal(await input.inputValue(),'y'); inputDelay=180;
  await input.fill('초안 보존'); await page.locator('#terminal-back').click(); await page.locator('.session-row').nth(1).click(); await ready();
  assert.equal(await input.isVisible(),false); await page.locator('#terminal-back').click(); await page.locator('.session-row').first().click();
  assert.equal(await input.inputValue(),'초안 보존');
  await directAgain(); blockInput=true; await page.waitForFunction(() => document.getElementById('terminal-keyboard').disabled);
  assert.equal(await enter.isDisabled(),true); blockInput=false; await ready();
  checks.push('Session switch cancels unsent keys and preserves drafts in their original session; disconnected input is disabled');
  await screen.click(); start=operations.length; inputDelay=750; failNext=true;
  await page.keyboard.type('old-uncertain'); while(operations.length===start) await page.waitForTimeout(10);
  await page.locator('#terminal-back').click(); await page.locator('.session-row').nth(1).click(); await ready();
  await page.locator('#terminal-back').click(); await page.locator('.session-row').first().click(); await ready();
  await screen.click(); await page.keyboard.type('new-queued'); await waitCount(start+1); await page.waitForTimeout(1000);
  assert.equal(operations.length,start+1,'Failed old generation must stop newer same-session queued text');
  assert.equal(await input.inputValue(),'old-uncertainnew-queued');
  checks.push('Switch away/back during an uncertain direct POST stops the newer same-session queue and preserves its text');
  await directAgain(); await page.locator('#terminal-settings summary').click(); await compose.check();
  start=operations.length; inputDelay=400; failNext=true;
  await input.fill('composed-uncertain'); await enter.click(); while(operations.length===start) await page.waitForTimeout(10);
  await page.locator('#terminal-back').click(); await page.locator('.session-row').nth(1).click(); await ready();
  await page.waitForTimeout(650); await page.locator('#terminal-back').click(); await page.locator('.session-row').first().click();
  assert.equal(await input.inputValue(),'composed-uncertain','Failed composed POST restores text to its original session even while another session is selected');
  assert.equal(operations.length,start+1); inputDelay=180; await directAgain();
  checks.push('Failed composed POST after a session switch preserves the original-session draft without replay');
  await page.locator('#terminal-settings summary').click(); await compose.check();
  start=operations.length; inputDelay=750; failNext=true;
  await input.fill('composed-old'); await enter.click(); while(operations.length===start) await page.waitForTimeout(10);
  await page.locator('#terminal-back').click(); await page.locator('.session-row').nth(1).click(); await ready();
  await page.locator('#terminal-back').click(); await page.locator('.session-row').first().click(); await ready();
  await screen.click(); await page.keyboard.type('new-direct'); await waitCount(start+1); await page.waitForTimeout(1000);
  assert.equal(operations.length,start+1,'Failed composed POST must stop newly armed same-session direct input');
  assert.equal(await input.inputValue(),'composed-oldnew-direct'); inputDelay=180; await directAgain();
  checks.push('Failed composed POST also stops and preserves a newer direct queue for the same session');
  async function capture(name) {
    await page.locator('#feedback').waitFor({state:'hidden',timeout:20000});
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, name+' horizontal overflow');
    const box=await page.locator('.input-actions').boundingBox(), viewport=await page.evaluate(() => ({height:visualViewport.height,top:visualViewport.offsetTop}));
    if (await page.locator('body').evaluate(body => body.classList.contains('terminal-focus'))) assert.ok(box.y>=viewport.top-2 && box.y+box.height<=viewport.top+viewport.height+2,name+' key controls outside viewport');
    await page.screenshot({path:path.join(output,name+'.png')}); screenshots.push(name);
  }
  sessions[0].session.terminal='terminal'; activeKeys=['text','submit','enter'];
  await page.waitForFunction(() => document.getElementById('direct-input-help').textContent.includes('손쉬운 사용'));
  assert.equal(await keyboard.isDisabled(),true); assert.equal(await input.isVisible(),true); assert.equal(await enter.isEnabled(),true);
  await capture('mobile-permission-fallback');
  sessions[0].session.terminal='vscode'; activeKeys=['text','enter','escape','interrupt','up','down','tab'];
  await page.waitForFunction(() => document.getElementById('direct-input-help').textContent.includes('VS Code') && !inputKeys().includes('submit'));
  start=operations.length; await input.fill('구형 확장 한글'); await input.press('Enter'); await waitCount(start+2);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]),[['text','구형 확장 한글'],['enter','']]);
  sessions[0].session.terminal='iterm'; activeKeys=keys; await ready();
  assert.equal(await input.isVisible(),false);
  checks.push('Terminal permission explanation and old VS Code text-then-Return fallback; direct UI returns when supported');
  for(const [width,height] of [[390,844],[320,740],[844,390],[768,1024],[1440,900]]) {
    await page.setViewportSize({width,height}); await capture('focus-'+width+'x'+height);
  }
  await page.setViewportSize({width:390,height:844}); await page.locator('#terminal-settings summary').click();
  await page.locator('#font-larger').click(); await page.locator('#font-larger').click(); assert.equal(await page.locator('#font-size').textContent(),'16px');
  await page.locator('#terminal-wrap').uncheck(); assert.equal(await screen.evaluate(e => getComputedStyle(e).whiteSpace),'pre');
  await capture('mobile-settings'); await page.locator('#terminal-wrap').check(); await page.locator('#terminal-settings summary').click();
  await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'}); await screen.click(); await capture('mobile-dark');
  // Keyboard geometry and IME below are simulated, not a physical phone keyboard.
  await page.evaluate(() => { window.fixtureOriginalViewport=window.visualViewport; window.fixtureViewport=new EventTarget(); Object.assign(window.fixtureViewport,{height:430,offsetTop:0}); Object.defineProperty(window,'visualViewport',{configurable:true,get:()=>window.fixtureViewport}); window.dispatchEvent(new Event('resize')); });
  await capture('mobile-keyboard-geometry');
  await page.evaluate(() => { window.fixtureViewport.height=280; window.fixtureViewport.offsetTop=100; window.dispatchEvent(new Event('resize')); });
  await capture('mobile-keyboard-offset'); assert.ok((await screen.boundingBox()).height>80);
  await page.evaluate(() => { Object.defineProperty(window,'visualViewport',{configurable:true,get:()=>window.fixtureOriginalViewport}); window.dispatchEvent(new Event('resize')); });
  checks.push('390/320 portrait, landscape, tablet/desktop, font/wrap/settings, dark/reduced motion and simulated keyboard viewport');
  await screen.click(); frameError=true; await page.locator('#terminal-retry').waitFor({state:'visible'});
  assert.equal(await keyboard.isDisabled(),true); assert.equal(await input.isDisabled(),true); await capture('mobile-disconnected');
  const stopped=operations.length; frameError=false; await page.locator('#terminal-retry').click(); await ready();
  await page.waitForTimeout(500); assert.equal(operations.length,stopped); assert.notEqual(await focused(),'terminal-keyboard');
  await page.locator('#terminal-focus').click(); assert.equal(await page.locator('.session-summary').isVisible(),true);
  for(const [width,height] of [[768,1024],[1440,900]]) { await page.setViewportSize({width,height}); await capture('detail-'+width+'x'+height); }
  checks.push('Disconnect disables capture, explicit recovery never replays or steals focus; normal tablet/desktop details remain usable');
  assert.deepEqual(errors,[]);
  const report={checks,screenshots,javascriptErrors:errors,inputOperations:operations.length,scope:'Chromium + synthetic HTTP fixture; IME, clipboard and keyboard geometry simulated; no physical phone or native Mac key delivery'};
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)); console.log(JSON.stringify(report,null,2));
} finally { if(browser) await browser.close(); await new Promise(resolve=>server.close(resolve)); }
