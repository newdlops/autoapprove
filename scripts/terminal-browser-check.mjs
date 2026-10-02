// Real browser + isolated synthetic terminal server; never inputs to the user's terminals.
import assert from 'node:assert/strict';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import path from 'node:path';
const { chromium } = await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const info = JSON.parse(await readFile(process.argv[2], 'utf8'));
const output = path.resolve('dist/qa/terminal'); await mkdir(output, { recursive: true });
const browser = await chromium.launch({ headless: true, executablePath: process.env.AUTOAPPROVE_CHROMIUM_PATH || undefined });
const errors = [], frames = [], checks = [], screenshots = [];
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  page.setDefaultTimeout(12000); page.on('pageerror', error => errors.push(error.message));
  page.on('response', async response => {
    if (response.url().includes('/api/terminal') && response.status() === 200) {
      try { const bytes = await response.body(), value = JSON.parse(bytes); frames.push({ bytes: bytes.length, full: typeof value.screen === 'string' }); } catch (_) {}
    }
  });
  await page.goto(info.first.url);
  await page.getByRole('button', { name: /웹 관리 구현/ }).first().click();
  await page.waitForFunction(() => document.getElementById('terminal-screen').textContent.includes('합성 데이터'));
  assert.ok(await page.locator('#terminal-screen .terminal-run').count() > 0);
  const actualRun = page.locator('.terminal-run').filter({ hasText: 'error: 오류 강조 검증 예시' });
  assert.equal(await actualRun.evaluate(element => getComputedStyle(element).color), 'rgb(135, 215, 255)', 'No error-word heuristic replaces the source color');
  assert.equal(await actualRun.evaluate(element => getComputedStyle(element).backgroundColor), 'rgb(48, 48, 48)');
  assert.equal(await page.locator('.ansi-bold').first().evaluate(element => getComputedStyle(element).fontWeight), '700');
  assert.equal(await page.locator('.ansi-underline').first().evaluate(element => getComputedStyle(element).textDecorationLine), 'underline');
  assert.equal(await page.locator('#terminal-screen img').count(), 0);
  assert.ok((await page.locator('#terminal-screen').textContent()).includes('<img src=x onerror=alert(1)>'));
  checks.push('original cell RGB, backgrounds, bold, underline and literal HTML text');
  await page.evaluate(() => {
    window.terminalMutations = 0; window.firstTerminalLine = document.getElementById('terminal-screen').firstChild;
    window.terminalObserver = new MutationObserver(changes => window.terminalMutations += changes.length);
    window.terminalObserver.observe(document.getElementById('terminal-screen'), { childList: true, characterData: true, subtree: true });
  });
  await page.waitForTimeout(2200);
  assert.equal(await page.evaluate(() => window.terminalMutations), 0, 'Unchanged output must not rewrite the console');
  assert.ok(frames.filter(frame => !frame.full).length >= 2, 'Fast polling uses compact unchanged responses');
  const colors = page.getByRole('checkbox', { name: '원본 색상', exact: true });
  await colors.uncheck();
  assert.equal(await page.evaluate(() => window.firstTerminalLine === document.getElementById('terminal-screen').firstChild), true);
  assert.equal(await actualRun.evaluate(element => getComputedStyle(element).color), await page.locator('#terminal-screen').evaluate(element => getComputedStyle(element).color));
  await page.reload(); await page.waitForFunction(() => document.getElementById('terminal-screen').textContent.includes('합성 데이터'));
  assert.equal(await colors.isChecked(), false); await colors.check();
  checks.push('unchanged DOM, compact polling and persistent monochrome switch');
  const echoLabel = '브라우저 입력 속도 검증 · ' + randomUUID();
  await page.locator('#terminal-input').fill(echoLabel + '\n' + Array.from({ length: 70 }, (_, i) => `합성 출력 ${i} · 한글/中文/🧪`).join('\n'));
  const start = performance.now(); await page.getByRole('button', { name: '텍스트 입력', exact: true }).click();
  await page.waitForFunction(value => document.getElementById('terminal-screen').textContent.includes(value), echoLabel);
  const echoMS = Math.round(performance.now() - start);
  assert.ok(echoMS < 2000, 'Synthetic input echo refreshes immediately');
  assert.ok(await page.locator('#terminal-screen').evaluate(pre => pre.scrollTop > 0));
  await page.getByRole('checkbox', { name: '아래로 따라가기' }).uncheck();
  await page.evaluate(() => {
    const pre = document.getElementById('terminal-screen'); pre.scrollTop = 40;
    const range = document.createRange(); range.setStart(pre.firstChild.firstChild, 0); range.setEnd(pre.firstChild.firstChild, 11);
    window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
    window.selectedTerminalText = window.getSelection().toString(); window.preservedTerminalLine = pre.firstChild;
  });
  const hash = new URLSearchParams(new URL(page.url()).hash.slice(1));
  const query = new URLSearchParams({ node: hash.get('node'), session: hash.get('session') });
  const frame = await (await page.request.get(info.first.url + '/api/terminal?' + query)).json();
  const otherLabel = '다른 브라우저에서 추가한 합성 출력 · ' + randomUUID();
  const sent = await page.request.post(info.first.url + '/api/input?node=' + hash.get('node'), { data: { sessionID: hash.get('session'), revision: frame.revision, kind: 'text', text: otherLabel, requestID: randomUUID() } });
  assert.equal(sent.status(), 200);
  await page.waitForFunction(value => document.getElementById('terminal-screen').textContent.includes(value), otherLabel);
  assert.equal(await page.evaluate(() => document.getElementById('terminal-screen').scrollTop), 40);
  assert.equal(await page.evaluate(() => window.getSelection().toString() === window.selectedTerminalText), true);
  assert.equal(await page.evaluate(() => document.getElementById('terminal-screen').firstChild === window.preservedTerminalLine), true);
  checks.push('input echo, follow control, changed output preserves scroll and text selection');
  async function capture(name) {
    await page.locator('#feedback').waitFor({ state: 'hidden' });
    await page.locator('#terminal-heading').scrollIntoViewIfNeeded();
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, name + ' overflow');
    await page.screenshot({ path: path.join(output, name + '.png') }); screenshots.push(name);
  }
  async function contrast() {
    const values = await page.locator('#terminal-screen span').evaluateAll(elements => {
      const bg = getComputedStyle(document.getElementById('terminal-screen').closest('.terminal')).backgroundColor;
      return [...new Set(elements.map(element => getComputedStyle(element).color))].map(fg => ({ fg, bg }));
    });
    const luminance = value => value.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => { v /= 255; return v <= .04045 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }).reduce((sum, v, i) => sum + v * [.2126, .7152, .0722][i], 0);
    for (const { fg, bg } of values) { const a = luminance(fg), b = luminance(bg); assert.ok((Math.max(a, b) + .05) / (Math.min(a, b) + .05) >= 4.5, fg + ' contrast'); }
  }
  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: width === 768 ? 1024 : width < 760 ? 844 : 900 });
    await capture('terminal-' + width);
  }
  // Source colors may intentionally have low contrast; monochrome is the readable fallback.
  await colors.uncheck(); await contrast(); await colors.check();
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' });
  await capture('terminal-dark-320'); await colors.uncheck(); await contrast(); await colors.check();
  assert.equal(await page.locator('#terminal-live').evaluate(element => getComputedStyle(element, '::before').animationName), 'none');
  await page.setViewportSize({ width: 1440, height: 900 }); await capture('terminal-dark-1440');
  checks.push('1440/768/390/320 layouts, light/dark monochrome contrast and reduced motion');
  await page.route('**/api/terminal?**', route => route.abort());
  await page.getByRole('button', { name: '화면 다시 연결' }).waitFor();
  assert.equal(await page.locator('#terminal-input').isDisabled(), true);
  await capture('terminal-disconnected');
  await page.unroute('**/api/terminal?**'); await page.getByRole('button', { name: '화면 다시 연결' }).click();
  await page.locator('#terminal-error').waitFor({ state: 'hidden' });
  checks.push('connection error, disabled input and explicit recovery');
  let controlledAppearance = { runs: [{ offset: 0, length: 1, fg: '#123456' }] };
  let controlledText = frame.screen;
  let controlledRevision = 'original-color-one';
  await page.route('**/api/terminal?**', route => route.fulfill({ json: { ...frame, screen: controlledText, appearance: controlledAppearance, revision: controlledRevision, observedAt: new Date().toISOString() } }));
  await page.waitForFunction(() => document.querySelector('.terminal-run')?.style.getPropertyValue('--run-fg') === '#123456');
  controlledAppearance = { runs: [{ offset: 0, length: 1, fg: '#abcdef' }] }; controlledRevision = 'original-color-two';
  await page.waitForFunction(() => document.querySelector('.terminal-run')?.style.getPropertyValue('--run-fg') === '#abcdef');
  controlledAppearance = undefined; controlledRevision = 'plain-host';
  await page.waitForFunction(() => document.getElementById('terminal-colors').disabled);
  assert.equal(await page.locator('.terminal-run').count(), 0);
  assert.match(await page.locator('#terminal-color-status').textContent(), /텍스트만 제공합니다/);
  await capture('terminal-plain-host');
  controlledAppearance = { runs: [{ offset: 0, length: 1, fg: 'url(https://example.invalid)' }] }; controlledRevision = 'invalid-color';
  await page.waitForTimeout(2200);
  assert.equal(await page.locator('.terminal-run').count(), 0);
  checks.push('color-only frame refresh, plain host fallback and invalid style rejection');
  await page.unroute('**/api/terminal?**');
  let edgeScreen = Array.from({ length: 7500 }, (_, i) => `合成 ${i} · 긴 출력 검증\n`).join('');
  const denseText = edgeScreen;
  await page.route('**/api/terminal?**', route => route.fulfill({ json: { ...frame, appearance: undefined, screen: edgeScreen, revision: 'synthetic-edge-' + edgeScreen.length, observedAt: new Date().toISOString() } }));
  await page.getByRole('button', { name: '상태 새로고침' }).click();
  await page.waitForFunction(value => document.getElementById('terminal-screen').textContent === value, denseText);
  assert.ok(await page.locator('#terminal-screen .terminal-line').count() <= 2000);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
  edgeScreen = '';
  await page.getByRole('button', { name: '상태 새로고침' }).click();
  await page.waitForFunction(() => document.getElementById('terminal-screen').textContent === '터미널 화면에 표시된 내용이 없습니다.');
  checks.push('large output preserves all text with bounded DOM and empty screen recovery');
  assert.deepEqual(errors, []);
  const report = { checks, screenshots, syntheticInputEchoMS: echoMS, frames, javascriptErrors: errors };
  await writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ checks, screenshots, syntheticInputEchoMS: echoMS, compactFrames: frames.filter(frame => !frame.full).length, javascriptErrors: errors }, null, 2));
} finally { await browser.close(); }
