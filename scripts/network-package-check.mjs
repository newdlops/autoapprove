// Exercise the packaged helper in an isolated profile; screen connections stay off.
import { chmod, cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { once } from 'node:events';
import { createServer } from 'node:net';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

// macOS Unix-domain sockets have a short path limit.
const root = await mkdtemp('/private/tmp/aa-web-');
// Use ordinary application-directory permissions for the relocated copy.
await chmod(root, 0o755);
const app = path.join(root, 'RelocatedAutoApprove.app');
const home = path.join(root, 'isolated-profile');
const run = promisify(execFile), wait = ms => new Promise(resolve => setTimeout(resolve, ms));
let child, stderr = '';
const preferredPortBlocker = createServer();
async function reserveDefaultPort() {
  await new Promise((resolve, reject) => {
    preferredPortBlocker.once('error', error => error.code === 'EADDRINUSE' ? resolve() : reject(error));
    preferredPortBlocker.listen(8765, '127.0.0.1', resolve);
  });
}
async function start() {
  stderr = '';
  child = spawn(path.join(app, 'Contents/MacOS/autoapprove'), ['serve', '--home', home], { stdio: ['ignore', 'pipe', 'pipe'], env: { ...process.env, HOME: home, ZDOTDIR: home } });
  child.stdout.resume(); child.stderr.on('data', data => { stderr += data; });
}
async function stop() {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const closed = once(child, 'close'); child.kill(); await closed; child = null;
}
async function web(mode) {
  const { stdout } = await run(path.join(app, 'Contents/MacOS/autoapprove'), ['web', ...(mode ? [mode] : []), '--home', home], { timeout: 5000 });
  return JSON.parse(stdout);
}
async function status(predicate) {
  let lastStatus;
  for (let attempt = 0; attempt < 30; attempt++) {
    try { const value = await web(); lastStatus = value; if (predicate(value)) return value; } catch {}
    if (child?.exitCode !== null) throw new Error('Packaged helper exited: ' + stderr);
    await wait(150);
  }
  throw new Error('Packaged web status did not settle: ' + JSON.stringify(lastStatus) + ' ' + stderr);
}
try {
  await cp(path.resolve(process.argv[2] || 'dist/AutoApprove.app'), app, { recursive: true });
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  const cssPath = path.join(app, 'Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/app.css');
  const originalCSS = await readFile(cssPath);
  const versionPath = path.join(app, 'Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json');
  const originalVersion = await readFile(versionPath);
  const versionMarker = {version:'0.0.1',build:2,api:1};
  await writeFile(versionPath, JSON.stringify(versionMarker));
  const marker = '/* isolated relocated resource probe */';
  await writeFile(cssPath, Buffer.concat([originalCSS, Buffer.from('\n' + marker)]));
  // Re-sign the disposable fixture after adding the resource marker.
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--preserve-metadata=identifier,entitlements', app]);
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  await reserveDefaultPort();
  await start();
  const on = await status(value => value.enabled && value.ready);
  const port = on.port;
  assert.ok(port > 0 && port !== 8765, 'A busy default port must automatically choose an available port');
  let url = 'http://127.0.0.1:' + port;
  const css = await fetch(url + '/app.css'); assert.equal(css.status, 200);
  assert.ok((await css.text()).includes(marker), 'Relocated helper must use its packaged resources');
  const first = await (await fetch(url + '/api/state')).json();
  assert.deepEqual(first.release, versionMarker, 'Relocated helper must read its bundled version, not the build machine resources');
  assert.deepEqual((await (await fetch(url + '/api/discovery')).json()).release, versionMarker);
  assert.ok(first.sessions.every(view => !view.session.automatic), 'Isolated profile must never enable existing sessions');
  for (const resource of ['/pty.js', '/vendor/xterm.js', '/vendor/xterm-fit.js', '/vendor/xterm.css']) {
    const response = await fetch(url + resource);
    assert.equal(response.status, 200, 'Packaged PTY resource: ' + resource);
    assert.ok((await response.text()).length > 100);
  }
  async function ptyPost(route, body) {
    const response = await fetch(url + route, { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({requestID:randomUUID(), ...body}), signal: AbortSignal.timeout(5000) });
    const value = await response.json(); assert.equal(response.status, 200, value.error); return value;
  }
  const pty = await ptyPost('/api/pty', {cwd:home,program:'shell',columns:80,rows:24}), clientID = randomUUID();
  await ptyPost('/api/pty/input', {ptyID:pty.ptyID,streamID:pty.streamID,clientID,sequence:1,data:Buffer.from("printf 'PACKAGED-PTY-OK\\n'\r").toString('base64')});
  let ptyText = '', offset;
  for (let attempt = 0; attempt < 20 && !/PACKAGED-PTY-OK\r?\n/.test(ptyText); attempt++) {
    const response = await fetch(url + '/api/pty/output?' + new URLSearchParams({pty:pty.ptyID,stream:pty.streamID,...(offset == null ? {} : {offset:String(offset)})}), {signal:AbortSignal.timeout(5000)});
    assert.equal(response.status,200); const value = await response.json(); offset = value.offset; ptyText += Buffer.from(value.data,'base64').toString();
  }
  assert.match(ptyText,/PACKAGED-PTY-OK\r?\n/, 'The relocated signed helper must create a controlling PTY');
  await ptyPost('/api/pty/close',{ptyID:pty.ptyID,streamID:pty.streamID});
  await stop();
  assert.equal(execFileSync('/usr/bin/sqlite3', [path.join(home, 'state.sqlite'), "SELECT value FROM settings WHERE key = 'webPort'"], { encoding: 'utf8' }).trim(), String(port), 'Actual port must be saved as the restart preference');
  await writeFile(cssPath, originalCSS);
  await writeFile(versionPath, originalVersion);
  execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', '--preserve-metadata=identifier,entitlements', app]);
  execFileSync('/usr/bin/codesign', ['--verify', '--deep', '--strict', app]);
  await start();
  const restarted = await status(value => value.enabled && value.ready);
  assert.ok(restarted.port > 0);
  url = 'http://127.0.0.1:' + restarted.port;
  const restored = await (await fetch(url + '/api/state')).json();
  assert.equal(restored.id, first.id, 'Mac identity must survive restart');
  assert.deepEqual(restored.release, JSON.parse(originalVersion), 'Restart must publish the restored bundled web version');
  await web('off'); await status(value => !value.enabled && !value.ready);
  await assert.rejects(fetch(url + '/api/state', { signal: AbortSignal.timeout(1500) }));
  await stop(); await start();
  assert.equal((await status(value => !value.enabled)).ready, false);
  console.log('PASS: relocated packaged resources/signature, real packaged PTY and local xterm assets, automatic web publishing on first run, busy-port fallback, persisted port preference/identity/ON, immediate OFF and respected persisted OFF');
} finally {
  await stop();
  if (preferredPortBlocker.listening) await new Promise(resolve => preferredPortBlocker.close(resolve));
  await rm(root, { recursive: true, force: true });
}
