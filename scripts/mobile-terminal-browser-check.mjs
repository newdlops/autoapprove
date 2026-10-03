// Real browser, synthetic loopback API. No input is sent to a user's terminal.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
const { chromium } = await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const output = path.resolve('dist/qa/mobile-terminal'); await mkdir(output, { recursive: true });
const keys = ['text','submit','characters','enter','escape','interrupt','up','down','left','right','backspace','delete','home','end','tab'];
const sessions = ['one','two'].map((id, i) => ({
  session: { id, agent: i ? 'claude' : 'codex', terminal: 'iterm', hostName: '검증용 터미널', phase: 'idle', cwd: '/fixture/mobile-terminal', tty: '/dev/fixture-' + id, automatic: false, detail: '합성 데이터', queuedQuestions: [] },
  title: i ? '두 번째 검증 세션' : '한글과 긴 프로젝트 이름 · 모바일 터미널 검증', phaseTitle: '입력 대기', canApprove: true, canReveal: true, canRead: true, keys
}));
const screens = new Map(sessions.map(view => [view.session.id, '모바일 터미널 검증 · 합성 데이터\n\n' + Array.from({length: 90}, (_, i) => `출력 ${i} · 한글 🧪 · ${'long-text-'.repeat(10)}`).join('\n') + '\n› ']));
const operations = [], receipts = new Map(), revisions = new Map([['one',0],['two',0]]);
let inputDelay = 180, failNext = false, blockInput = false, frameError = false, activeKeys = keys;
const network = () => ({ updatedAt: new Date().toISOString(), nodes: [{ id: 'fixture-mac', name: '검증용 Mac', local: true, online: true, state: { sessions: sessions.map(view => ({...view, keys: activeKeys, inputReason: blockInput ? '직접 입력하려면 자동 승인을 끄세요.' : undefined})), snapshot: { paused: false, events: [] } } }] });
const server = createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const json = (status, value) => { const body = JSON.stringify(value); res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(body); };
  try {
    if (url.pathname === '/api/network') return json(200, network());
    if (url.pathname === '/api/terminal') {
      if (frameError) return json(503, { error: '검증용 연결 끊김 · 화면을 다시 연결해주세요.' });
      const id = url.searchParams.get('session'), revision = String(revisions.get(id));
      return json(200, { sessionID: id, revision, observedAt: new Date().toISOString(), keys: activeKeys, inputReason: blockInput ? '직접 입력하려면 자동 승인을 끄세요.' : undefined, ...(url.searchParams.get('revision') === revision ? {} : { screen: screens.get(id) }) });
    }
    if (url.pathname === '/api/input') {
      let body = ''; for await (const chunk of req) body += chunk;
      const input = JSON.parse(body);
      if (receipts.has(input.requestID)) return json(200, receipts.get(input.requestID));
      if (input.revision !== String(revisions.get(input.sessionID)) || blockInput) return json(409, { error: '화면이 달라졌습니다. 확인 후 다시 입력해주세요.' });
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
  const input = page.locator('#terminal-input'), enter = page.locator('#send-input'), live = page.locator('#direct-input');
  await input.waitFor({ state: 'visible' }); await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  assert.equal(await page.locator('body').evaluate(body => body.classList.contains('terminal-focus')), true);
  assert.ok((await page.locator('#terminal-screen').boundingBox()).height > 540);
  assert.equal(await input.evaluate(element => getComputedStyle(element).fontSize), '16px');
  checks.push('390 portrait opens full-height terminal with 16px input and fixed keyboard controls');
  async function waitCount(count) {
    const deadline = Date.now() + 12000;
    while (operations.length < count) { assert.ok(Date.now() < deadline, `Expected ${count} inputs, received ${operations.length}`); await page.waitForTimeout(30); }
    await page.waitForFunction(() => ['live','changed'].includes(document.getElementById('terminal-live').dataset.state));
  }
  let start = operations.length;
  await input.fill('한글 🧪'); await input.press('Enter');
  while (operations.length === start) await page.waitForTimeout(10);
  assert.equal(await input.isEnabled(), true, 'Own POST must keep editor and keyboard alive');
  await input.fill('다음 작성 내용'); await waitCount(start + 1);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['submit','한글 🧪']]);
  assert.equal(await input.inputValue(), '다음 작성 내용');
  start = operations.length; await input.press('Shift+Enter'); await page.waitForTimeout(200);
  assert.equal(operations.length, start); assert.ok((await input.inputValue()).includes('\n'));
  await input.fill(''); await input.press('Enter'); await waitCount(start + 1);
  assert.equal(operations.at(-1).kind, 'enter');
  checks.push('atomic text + Return, empty Return, Shift Enter draft and keyboard/draft preserved during POST');
  await live.check(); await input.focus();
  start = operations.length; inputDelay = 350;
  await input.pressSequentially('a'); while (operations.length === start) await page.waitForTimeout(10);
  await input.pressSequentially('b'); await input.press('Enter');
  await page.waitForFunction(() => !document.getElementById('send-input').disabled);
  while (operations.length < start + 3) await page.waitForTimeout(30);
  await waitCount(start + 3);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['characters','a'],['characters','b'],['enter','']]);
  inputDelay = 180;
  start = operations.length;
  await input.evaluate(element => { element.dispatchEvent(new CompositionEvent('compositionstart', {bubbles:true})); element.value='ㅎ'; element.dispatchEvent(new InputEvent('input', {bubbles:true,isComposing:true,data:'ㅎ'})); });
  await page.waitForTimeout(150); assert.equal(operations.length, start);
  await input.evaluate(element => { element.value='한글'; element.dispatchEvent(new CompositionEvent('compositionend', {bubbles:true,data:'한글'})); element.dispatchEvent(new InputEvent('input', {bubbles:true,data:'한글'})); });
  await waitCount(start + 1); await page.waitForTimeout(150);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['characters','한글']]);
  await input.press('Backspace'); await waitCount(start + 2); assert.equal(operations.at(-1).kind, 'backspace');
  await input.evaluate(element => element.dispatchEvent(new InputEvent('beforeinput', {bubbles:true,cancelable:true,inputType:'deleteContentBackward'})));
  await waitCount(start + 3); assert.equal(operations.at(-1).kind, 'backspace');
  await page.locator('[data-key="up"]').click(); await waitCount(start + 4);
  assert.equal(await input.evaluate(element => document.activeElement === element), true, 'Key button retains editor focus');
  await input.press('Tab'); await waitCount(start + 5); assert.equal(operations.at(-1).kind, 'tab');
  await input.press('Shift+Tab'); assert.equal(await input.evaluate(element => document.activeElement === element), false);
  checks.push('FIFO live typing during slow POST, Enter ordering, synthetic IME commit once, desktop/mobile Backspace and focus escape');
  await input.focus(); start = operations.length; failNext = true;
  await input.pressSequentially('uncertain'); await waitCount(start + 1);
  await page.waitForFunction(() => !document.getElementById('direct-input').checked);
  await page.waitForTimeout(800); assert.equal(operations.length, start + 1);
  assert.equal(await input.inputValue(), 'uncertain');
  assert.match(await page.locator('#input-reason').textContent(), /확인/);
  checks.push('uncertain response stops live mode, restores pending text and never replays');
  await input.fill(''); await live.check(); inputDelay = 400; start = operations.length;
  await input.pressSequentially('x'); while (operations.length === start) await page.waitForTimeout(10);
  await input.pressSequentially('y'); await page.locator('#terminal-back').click(); await page.locator('.session-row').nth(1).click();
  await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  await page.waitForTimeout(600); assert.equal(operations.length, start + 1); assert.equal(operations.at(-1).sessionID, 'one');
  await page.locator('#terminal-back').click(); await page.locator('.session-row').first().click();
  await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  assert.equal(await input.inputValue(), 'y'); assert.equal(await live.isChecked(), false); inputDelay = 180;
  checks.push('session change cancels unsent live keys and preserves their original-session draft');
  await input.fill('초안 보존'); await page.locator('#terminal-back').click();
  await page.locator('.session-row').nth(1).click(); await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  assert.equal(await input.inputValue(), ''); await page.locator('#terminal-back').click(); await page.locator('.session-row').first().click();
  assert.equal(await input.inputValue(), '초안 보존');
  await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  await input.fill(''); blockInput = true;
  await page.waitForFunction(() => document.getElementById('terminal-input').disabled);
  assert.equal(await live.isDisabled(), true); blockInput = false;
  await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  checks.push('per-session drafts and automatic/manual input exclusion');
  async function capture(name) {
    await page.locator('#feedback').waitFor({state:'hidden'});
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, name + ' horizontal overflow');
    const box = await input.boundingBox(), viewport = await page.evaluate(() => ({height:visualViewport.height,top:visualViewport.offsetTop,body:document.body.getBoundingClientRect().height}));
    assert.ok(box.y + box.height <= viewport.top + viewport.height + 2, name + ' input outside viewport: ' + JSON.stringify({box,viewport}));
    await page.screenshot({path:path.join(output,name+'.png')}); screenshots.push(name);
  }
  sessions[0].session.terminal = 'terminal'; activeKeys = ['text','submit','enter'];
  await page.waitForFunction(() => document.getElementById('direct-input-help').textContent.includes('손쉬운 사용'));
  assert.equal(await live.isDisabled(), true); assert.equal(await enter.isEnabled(), true);
  await capture('mobile-permission-fallback');
  sessions[0].session.terminal = 'vscode'; activeKeys = ['text','enter','escape','interrupt','up','down','tab'];
  await page.waitForFunction(() => document.getElementById('direct-input-help').textContent.includes('VS Code'));
  start = operations.length; await input.fill('구형 확장 한글'); await input.press('Enter'); await waitCount(start + 2);
  assert.deepEqual(operations.slice(start).map(({kind,text}) => [kind,text]), [['text','구형 확장 한글'],['enter','']]);
  sessions[0].session.terminal = 'iterm'; activeKeys = keys; await page.waitForFunction(() => !document.getElementById('direct-input').disabled);
  checks.push('Terminal accessibility fallback and old VS Code text-then-Return compatibility');
  for (const [width,height] of [[390,844],[320,740],[844,390],[768,1024],[1440,900]]) {
    await page.setViewportSize({width,height}); await capture(`focus-${width}x${height}`);
  }
  await page.setViewportSize({width:390,height:844});
  await page.locator('#terminal-settings summary').click();
  await page.locator('#font-larger').click(); await page.locator('#font-larger').click();
  assert.equal(await page.locator('#font-size').textContent(), '16px');
  await page.locator('#terminal-wrap').uncheck(); assert.equal(await page.locator('#terminal-screen').evaluate(e => getComputedStyle(e).whiteSpace), 'pre');
  await capture('mobile-settings'); await page.locator('#terminal-wrap').check(); await page.locator('#terminal-settings summary').click();
  await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'}); await capture('mobile-dark');
  // Reduced visual viewport approximates keyboard geometry, not a physical iOS/Android keyboard.
  await page.evaluate(() => { window.fixtureOriginalViewport=window.visualViewport; window.fixtureViewport=new EventTarget(); Object.assign(window.fixtureViewport,{height:430,offsetTop:0}); Object.defineProperty(window,'visualViewport',{configurable:true,get:()=>window.fixtureViewport}); window.dispatchEvent(new Event('resize')); });
  await capture('mobile-keyboard-geometry');
  await page.evaluate(() => { window.fixtureViewport.height=280; window.fixtureViewport.offsetTop=100; window.dispatchEvent(new Event('resize')); });
  const editor = await input.boundingBox(); assert.ok(editor.y + editor.height <= 381); assert.ok(editor.y >= 100);
  await page.screenshot({path:path.join(output,'mobile-keyboard-offset.png')}); screenshots.push('mobile-keyboard-offset');
  await page.evaluate(() => { Object.defineProperty(window,'visualViewport',{configurable:true,get:()=>window.fixtureOriginalViewport}); window.dispatchEvent(new Event('resize')); });
  checks.push('390/320 portrait, landscape, tablet/desktop focus, settings, wrap, font size, dark mode and simulated keyboard viewport/offset');
  await live.check(); frameError = true; await page.locator('#terminal-retry').waitFor({state:'visible'});
  assert.equal(await live.isChecked(), false, 'Frame connection loss must stop live mode');
  assert.equal(await input.isDisabled(), true); await capture('mobile-disconnected');
  frameError = false; await page.locator('#terminal-retry').click(); await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  await page.locator('#terminal-focus').click();
  assert.equal(await page.locator('.session-summary').isVisible(), true);
  await page.setViewportSize({width:1440,height:900}); await page.screenshot({path:path.join(output,'desktop-detail.png')}); screenshots.push('desktop-detail');
  checks.push('disconnect disables inputs, explicit recovery and return to automation/detail controls');
  assert.deepEqual(errors, []);
  const report={checks,screenshots,javascriptErrors:errors,inputOperations:operations.length,scope:'Chromium + synthetic HTTP fixture; IME and keyboard geometry simulated; no physical phone or native Mac key delivery'};
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)); console.log(JSON.stringify(report,null,2));
} finally { if(browser) await browser.close(); await new Promise(resolve=>server.close(resolve)); }
