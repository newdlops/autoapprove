// Run after network-integration-check.mjs --serve. Requires Playwright with Chromium.
const { chromium } = await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
const info = JSON.parse(await readFile(process.argv[2], 'utf8'));
const output = path.resolve('dist/qa/network'); await mkdir(output, { recursive: true });
const httpLAN = process.argv.includes('--http-lan');
const gateway = new URL(info.first.url);
if (httpLAN) gateway.hostname = 'gateway.autoapprove.local';
const browser = await chromium.launch({ headless: true, executablePath: process.env.AUTOAPPROVE_CHROMIUM_PATH || undefined,
  args: httpLAN ? ['--host-resolver-rules=MAP gateway.autoapprove.local 127.0.0.1', '--no-proxy-server'] : [] });
const errors = [], screenshots = [], checks = [];
let page;
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  page = await context.newPage();
  page.setDefaultTimeout(12000);
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
  await page.goto(gateway.href);
  if (httpLAN) {
    assert.equal(await page.evaluate(() => window.isSecureContext), false);
    assert.equal(await page.evaluate(() => typeof crypto.randomUUID), 'undefined');
    checks.push('ordinary HTTP origin with crypto UUID fallback');
  }
  await page.getByRole('button', { name: /웹 관리 구현/ }).first().waitFor();
  async function capture(name) {
    await page.screenshot({ path: path.join(output, name + '.png'), fullPage: false }); screenshots.push(name);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth);
    assert.equal(overflow, false, name + ' must not have page overflow');
  }
  await capture('desktop-list');
  await page.getByRole('button', { name: /QA Mac B.*자동 승인 일시정지/ }).click();
  await page.getByRole('button', { name: /QA Mac B.*자동 승인 재개/ }).waitFor();
  await page.getByRole('button', { name: /QA Mac A.*자동 승인 일시정지/ }).waitFor();
  await page.getByRole('button', { name: /QA Mac B.*자동 승인 재개/ }).click();
  await page.getByRole('button', { name: /QA Mac B.*자동 승인 일시정지/ }).waitFor();
  checks.push('cross-Mac pause/resume with independent controls');
  await page.getByRole('button', { name: /웹 관리 구현/ }).first().click();
  await page.waitForFunction(() => document.getElementById('terminal-screen').textContent.includes('합성 데이터'));
  await capture('desktop-terminal');
  const toggle = page.getByRole('switch', { name: '자동 승인' });
  await toggle.check(); await page.locator('#send-input').waitFor();
  await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  assert.equal(await toggle.isChecked(), true);
  if (!await page.locator('#terminal-input').isVisible()) {
    if (!await page.locator('#terminal-settings').evaluate(details => details.open)) await page.locator('#terminal-settings summary').click();
    await page.locator('#compose-input').check();
  }
  await page.locator('#terminal-input').waitFor({ state: 'visible' });
  await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  await page.locator('#terminal-input').fill('브라우저에서 보낸 한글 · 검증용');
  await page.locator('#send-input').click();
  await page.waitForFunction(() => document.getElementById('terminal-screen').textContent.includes('브라우저에서 보낸 한글'));
  assert.equal(await toggle.isChecked(), true);
  await toggle.uncheck();
  await capture('desktop-after-input'); checks.push('input while automatic approval remains on, exact terminal text delivery');
  const search = page.getByRole('searchbox', { name: '세션 검색' });
  await search.fill('존재하지-않는-세션'); await page.getByText('검색이나 필터에 맞는 세션이 없습니다.').waitFor();
  await capture('desktop-empty-search'); await search.fill('');
  await page.getByRole('button', { name: '응답 필요', exact: true }).click();
  assert.ok(await page.locator('.session-row').count() > 0); await page.getByRole('button', { name: '전체', exact: true }).click(); checks.push('search empty state and review filter');
  await page.getByRole('button', { name: /질문 응답 대기/ }).first().click();
  await page.locator('#questions-section').scrollIntoViewIfNeeded(); await capture('desktop-question');
  await page.setViewportSize({ width: 390, height: 844 });
  await page.locator('#questions-section').scrollIntoViewIfNeeded(); await capture('mobile-question');
  await page.getByLabel('개인 핫스팟에서 확인', { exact: true }).check();
  await page.getByLabel('직접 답변 또는 추가 설명', { exact: true }).fill('선택과 함께 보낼 설명');
  await page.getByRole('button', { name: '답변 보내기', exact: true }).click();
  await page.getByText('답변이 대기열에 등록되었습니다.', { exact: true }).waitFor(); checks.push('question option, free text and queue receipt');
  await capture('mobile-question-queued');
  await page.setViewportSize({ width: 1440, height: 900 }); await page.evaluate(() => window.scrollTo(0, 0));
  await page.getByRole('button', { name: 'Mac 추가', exact: true }).click();
  await page.getByRole('textbox', { name: 'Mac의 웹 주소' }).fill('http://8.8.8.8:8765');
  await page.getByRole('button', { name: 'Mac 연결', exact: true }).click();
  await page.getByText('Mac에 표시된 사설 IP 또는 .local 주소와 포트를 입력해주세요.', { exact: true }).waitFor();
  await capture('desktop-add-error');
  await page.getByRole('textbox', { name: 'Mac의 웹 주소' }).fill(info.second.url);
  await page.getByRole('button', { name: 'Mac 연결', exact: true }).click();
  await page.locator('#add-dialog').waitFor({ state: 'hidden' }); checks.push('address form error and successful Mac addition');
  await page.locator('#feedback').waitFor({ state: 'hidden' });
  for (const size of [{ width: 768, height: 1024 }, { width: 390, height: 844 }, { width: 320, height: 700 }]) {
    await page.setViewportSize(size);
    if (size.width < 760) { await page.getByRole('button', { name: '세션 목록으로 돌아가기' }).click(); }
    await capture(`${size.width}-list`);
    await page.getByRole('button', { name: /긴 표시 이름/ }).first().click();
    await page.waitForFunction(() => document.getElementById('terminal-screen').textContent.includes('합성 데이터'));
    await capture(`${size.width}-long-terminal`);
    if (await page.locator('body').evaluate(body => body.classList.contains('terminal-focus'))) await page.locator('#terminal-focus').click();
    if (!await page.locator('#terminal-input').isVisible()) {
      if (!await page.locator('#terminal-settings').evaluate(details => details.open)) await page.locator('#terminal-settings summary').click();
      await page.locator('#compose-input').check();
    }
    await page.locator('#terminal-input').fill('화면 갱신 중에도 보존할 초안');
    await page.getByRole('button', { name: '상태 새로고침' }).click();
    assert.equal(await page.locator('#terminal-input').inputValue(), '화면 갱신 중에도 보존할 초안');
    if (size.width < 760) { await page.getByRole('button', { name: '세션 목록으로 돌아가기' }).click(); await page.getByRole('button', { name: /긴 표시 이름/ }).first().click(); assert.equal(await page.locator('#terminal-input').inputValue(), '화면 갱신 중에도 보존할 초안'); }
  }
  checks.push('768, 390 and 320 widths, long content, mobile back, draft preservation');
  await page.emulateMedia({ colorScheme: 'dark', reducedMotion: 'reduce' }); await capture('mobile-dark');
  await page.setViewportSize({ width: 1440, height: 900 }); await capture('desktop-dark');
  if (await page.locator('body').evaluate(body => body.classList.contains('terminal-focus'))) await page.locator('#terminal-focus').click();
  await page.emulateMedia({ colorScheme: 'light', reducedMotion: 'no-preference' });
  await page.getByRole('button', { name: 'Mac 추가', exact: true }).click(); await page.keyboard.press('Escape');
  assert.equal(await page.locator('#add-dialog').isVisible(), false);
  await page.keyboard.press('Tab');
  const focus = await page.evaluate(() => ({ tag: document.activeElement.tagName, outline: getComputedStyle(document.activeElement).outlineStyle }));
  assert.equal(focus.outline, 'solid'); checks.push('dialog Escape, keyboard focus and dark/reduced-motion');
  const geometry = await page.locator('button').evaluateAll(buttons => buttons.filter(button => !button.hidden && getComputedStyle(button).display !== 'none' && button.getBoundingClientRect().height > 0).map(button => ({ label: button.textContent, width: button.getBoundingClientRect().width, height: button.getBoundingClientRect().height })).filter(button => button.width < 44 || button.height < 44));
  assert.deepEqual(geometry, [], 'All visible button targets are at least 44px');
  await page.route('**/api/network', route => route.abort());
  await page.getByRole('button', { name: '상태 새로고침' }).click();
  await page.locator('#network-error').waitFor({ state: 'visible' });
  assert.match(await page.locator('#connection').textContent(), /연결 끊김 · 마지막 갱신/);
  assert.equal(await page.locator('#mac-count').textContent(), '0대');
  await capture('desktop-disconnected');
  await page.unroute('**/api/network'); await page.getByRole('button', { name: '상태 새로고침' }).click();
  await page.locator('#network-error').waitFor({ state: 'hidden' }); checks.push('network failure and recovery');
  const unexpected = errors.filter(error => !error.includes('ERR_FAILED') && !error.includes('400'));
  assert.deepEqual(unexpected, []);
  const report = { httpLAN, checks, screenshots, consoleErrors: errors }; await writeFile(path.join(output, 'browser-report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
} catch (error) {
  console.error({ error: error.message, consoleErrors: errors, checks });
  if (page) { await page.screenshot({ path: path.join(output, 'failure.png'), fullPage: false, timeout: 4000 }).catch(() => {}); }
  throw error;
} finally { await browser.close(); }
