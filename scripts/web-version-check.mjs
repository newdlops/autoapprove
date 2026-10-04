import { coreLinkArguments } from './swift-core-link.mjs';
// Real Swift HTTP servers and Chromium, isolated profiles and synthetic terminals only.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtemp, mkdir, readFile, readdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';

const { chromium } = await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const build = path.resolve('.build', process.argv.includes('--release') ? 'release' : 'debug');
const binary = path.resolve('.build/qa/WebVersionPreview');
await mkdir(path.dirname(binary), { recursive: true });
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/WebVersionPreview'), '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build), ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)), 'Tests/fixtures/network-preview.swift', '-o', binary], { stdio: 'inherit' });
const root = await mkdtemp(path.join(tmpdir(), 'autoapprove-web-version-'));
const output = path.resolve('dist/qa/web-version'); await mkdir(output, { recursive: true });
const children = [], probes = [], checks = [], errors = [], views = [];
let browser;
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function start(label, version) {
  const child = spawn(binary, [path.join(root, label), label, '--direct-only', '--web-version=' + version], { stdio: ['ignore', 'pipe', 'pipe'] }); children.push(child);
  let stdout = '', stderr = '';
  child.stderr.on('data', data => { stderr += data; });
  return await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Fixture startup: ' + stderr)), 20000);
    child.stdout.on('data', data => {
      stdout += data;
      for (const line of stdout.split('\n')) {
        if (!line.startsWith('{')) continue;
        try { const info = JSON.parse(line); if (info.url) { clearTimeout(timer); resolve({ ...info, child }); return; } } catch (_) {}
      }
    });
    child.once('exit', code => { clearTimeout(timer); reject(new Error(`Fixture exited (${code}): ${stderr}`)); });
  });
}
async function get(node, route = '/api/state') {
  const response = await fetch(node.url + route, { signal: AbortSignal.timeout(12000) });
  assert.equal(response.status, 200); return await response.json();
}
async function until(check, label) {
  for (let i = 0; i < 50; i++) { if (await check()) return; await wait(200); }
  throw new Error('Timed out: ' + label);
}
async function rootResponse(node) { return await fetch(node.url + '/', { redirect: 'manual', signal: AbortSignal.timeout(12000) }); }
try {
  const [older, newer, latest, legacy] = await Promise.all([start('A', '0.2.9:20'), start('B', '0.2.10:11'), start('C', '0.2.10:12'), start('Legacy', 'legacy')]);
  const oldState = await get(older), newState = await get(latest), legacyState = await get(legacy);
  assert.deepEqual(oldState.release, { version: '0.2.9', build: 20, api: 1 });
  assert.deepEqual(newState.release, { version: '0.2.10', build: 12, api: 1 });
  assert.equal(legacyState.release, undefined);
  browser = await chromium.launch({ headless: true, executablePath: process.env.AUTOAPPROVE_CHROMIUM_PATH || undefined });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(older.url);
  await page.locator('.session-row').first().click();
  const input = page.locator('#terminal-input');
  await page.waitForFunction(() => !document.getElementById('terminal-input').disabled);
  if (!await input.isVisible()) {
    if (!await page.locator('#terminal-settings').evaluate(details => details.open)) await page.locator('#terminal-settings summary').click();
    await page.locator('#compose-input').check();
  }
  const draft = '전송하지 않은 한글 초안 · keep this draft'; await input.fill(draft);
  const sessionHash = new URL(page.url()).hash;
  await writeFile(path.join(root, 'direct-peers.json'), JSON.stringify([older.url, newer.url, latest.url, legacy.url]));
  await until(async () => (await get(older, '/api/network')).preferredGateway?.id === latest.id, 'highest version and build discovery');
  await page.locator('#web-update').waitFor({ state: 'visible', timeout: 20000 });
  assert.equal(new URL(page.url()).origin, older.url);
  assert.equal(await input.inputValue(), draft);
  assert.match(await page.locator('#web-update-message').innerText(), /0\.2\.10 \(빌드 12\)/);
  checks.push('Numeric 0.2.9 < 0.2.10, build 11 < 12; unknown legacy release does not win');
  checks.push('Already-open page keeps terminal selection, draft and URL when a newer client arrives');

  for (const [width, height, scheme] of [[320,740,'light'],[390,844,'dark'],[768,1024,'light'],[1440,900,'dark'],[844,390,'light']]) {
    await page.setViewportSize({ width, height }); await page.emulateMedia({ colorScheme: scheme });
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const inputBox = await input.boundingBox(), linkBox = await page.locator('#open-latest-web').boundingBox(), notice = await page.locator('#web-update').boundingBox();
    assert.ok(linkBox.height >= 44); assert.ok(inputBox.y + inputBox.height <= height + 2);
    assert.ok(notice.y + notice.height <= (await page.locator('.terminal-heading').boundingBox()).y + 2);
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);
    assert.equal(await input.inputValue(), draft);
    const file = `notice-${width}-${scheme}.png`; await page.screenshot({ path: path.join(output, file) }); views.push({ width, height, scheme, file });
  }
  await page.setViewportSize({ width:390, height:844 });
  await page.evaluate(() => { Object.defineProperty(window.visualViewport, 'height', { configurable:true, value:280 }); window.visualViewport.dispatchEvent(new Event('resize')); });
  const compactInput = await input.boundingBox(); assert.ok(compactInput.y + compactInput.height <= 282);
  assert.equal(await page.locator('body').evaluate(body => body.classList.contains('terminal-compact')), true);
  await page.screenshot({ path: path.join(output,'notice-keyboard-height-280.png') });
  await page.evaluate(() => { delete window.visualViewport.height; window.visualViewport.dispatchEvent(new Event('resize')); });
  await page.locator('#open-latest-web').focus();
  await page.keyboard.press('Tab'); await page.keyboard.press('Shift+Tab');
  assert.equal(await page.locator('#open-latest-web').evaluate(element => getComputedStyle(element).outlineStyle), 'solid');
  checks.push('Notice fits mobile/tablet/desktop/light/dark/landscape and simulated 280px keyboard viewport; 44px link and visible focus');

  const popupPromise = page.waitForEvent('popup'); await page.locator('#open-latest-web').click(); const popup = await popupPromise;
  popup.on('pageerror',error => errors.push(error.message));
  await popup.waitForLoadState('domcontentloaded');
  try { await popup.waitForFunction(() => document.body.classList.contains('detail-open'),null,{timeout:12000}); }
  catch(error) { throw new Error(error.message+' '+JSON.stringify(await popup.evaluate(() => ({url:location.href,width:innerWidth,body:document.body.className,error:document.getElementById('network-error')?.textContent,content:document.body.innerText.slice(0,1500),sessions:document.querySelectorAll('.session-row').length,title:document.getElementById('session-title')?.textContent})))+' '+JSON.stringify(errors)); }
  assert.equal(new URL(popup.url()).origin, latest.url); assert.equal(new URL(popup.url()).hash, sessionHash);
  assert.equal(await input.inputValue(), draft); assert.equal(new URL(page.url()).origin, older.url);
  checks.push('Explicit latest link opens a new tab, preserves exact session hash and leaves original draft intact');

  const redirect = await rootResponse(older);
  assert.equal(redirect.status,302); assert.equal(redirect.headers.get('cache-control'),'no-store');
  assert.equal(new URL(redirect.headers.get('location')).origin, latest.url);
  assert.equal(new URL(redirect.headers.get('location')).searchParams.get('webNode'),latest.id);
  for (const route of ['/app.js','/app.css','/api/state','/api/network']) assert.equal((await fetch(older.url + route,{redirect:'manual'})).status,200,'Only entry documents redirect');
  assert.equal((await rootResponse(latest)).status,200);
  const entry = await browser.newPage({viewport:{width:390,height:844}}); entry.on('pageerror', error => errors.push(error.message));
  await entry.goto(older.url + '/' + sessionHash);
  await entry.waitForFunction(() => document.body.classList.contains('terminal-focus'));
  assert.equal(new URL(entry.url()).origin, latest.url); assert.equal(new URL(entry.url()).hash,sessionHash);
  assert.equal(await entry.locator('meta[name="autoapprove-web-version"]').getAttribute('content'),'0.2.10:12:1');
  const stableURL = entry.url(); await entry.waitForTimeout(2800); assert.equal(entry.url(),stableURL);
  checks.push('Fresh numeric entry redirects to newest verified Mac; fragment survives HTTP redirect and equal versions do not loop');
  const bootstrap = await browser.newPage({viewport:{width:390,height:844}}); bootstrap.on('pageerror',error => errors.push(error.message));
  const bootstrapURL = older.url+'/?bootstrap';
  await bootstrap.route(bootstrapURL, async route => route.fulfill({status:200,contentType:'text/html',body:(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/index.html','utf8')).replace('__AUTOAPPROVE_WEB_VERSION__','0.2.9:20:1')}));
  await bootstrap.goto(bootstrapURL+sessionHash,{waitUntil:'commit'});
  await bootstrap.waitForURL(url => url.origin === latest.url);
  await bootstrap.waitForFunction(() => document.body.classList.contains('terminal-focus'));
  assert.equal(new URL(bootstrap.url()).hash,sessionHash);
  checks.push('An untouched page loaded before discovery redirects on its first network response');

  // A registered endpoint whose discovery identity disagrees with its state must not win.
  const fakeID = randomUUID(), wrongID = randomUUID();
  let fakeURL;
  const fake = createServer((req,res) => {
    const release = {version:'9.0.0',build:99,api:1};
    const body = JSON.stringify(req.url === '/api/state' ? {...oldState,id:fakeID,name:'Identity mismatch fixture',release,webURLs:[fakeURL],webPort:new URL(fakeURL).port*1} : {service:'autoapprove',version:1,id:wrongID,name:'Wrong Mac',release,urls:[fakeURL],port:new URL(fakeURL).port*1});
    res.writeHead(200,{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body),Connection:'close'}); res.end(body);
  });
  await new Promise(resolve => fake.listen(0,'127.0.0.1',resolve)); probes.push(fake); fakeURL='http://127.0.0.1:'+fake.address().port;
  assert.equal((await fetch(older.url+'/api/peers',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({address:fakeURL})})).status,200);
  assert.equal((await get(older,'/api/network')).preferredGateway?.id,latest.id);
  assert.equal(new URL((await rootResponse(older)).headers.get('location')).origin,latest.url);
  checks.push('Mismatched discovery identity cannot displace a verified latest client');
  const wrongEntry = await fetch(latest.url+'/?webNode='+older.id,{redirect:'manual'}); assert.equal(wrongEntry.status,409);

  latest.child.kill(); await wait(250);
  await until(async () => (await get(older,'/api/network')).preferredGateway?.id === newer.id,'fallback to next online version');
  assert.equal(new URL((await rootResponse(older)).headers.get('location')).origin,newer.url);
  newer.child.kill(); await wait(250);
  const fallback = await rootResponse(older); assert.equal(fallback.status,200); assert.match(await fallback.text(),/0\.2\.9:20:1/);
  assert.equal((await get(older)).id,older.id);
  checks.push('Latest Mac offline falls back to next release; all newer clients offline serves own page and API');
  assert.deepEqual(errors,[]);
  await writeFile(path.join(output,'report.json'),JSON.stringify({checks,views,javascriptErrors:errors},null,2)+'\n');
  console.log(JSON.stringify({checks,views,javascriptErrors:errors},null,2));
} finally {
  await browser?.close(); children.forEach(child => child.kill());
  await Promise.all(probes.map(server => new Promise(resolve => server.close(resolve))));
  await rm(root,{recursive:true,force:true});
}
