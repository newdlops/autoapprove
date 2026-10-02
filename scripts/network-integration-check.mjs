import { mkdtemp, mkdir, readdir, rm, writeFile } from 'node:fs/promises';
import { execFileSync, spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

const root = await mkdtemp(path.join(tmpdir(), 'autoapprove-network-'));
const build = path.resolve('.build/debug');
const binary = path.resolve('.build/qa/RemotePreview');
await mkdir(path.dirname(binary), { recursive: true });
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/RemotePreview'), '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)), 'Tests/fixtures/network-preview.swift', '-o', binary], { stdio: 'inherit' });
const children = [];
async function start(label) {
  const child = spawn(binary, [path.join(root, label), label], { stdio: ['ignore', 'pipe', 'pipe'] }); children.push(child);
  let buffer = '', errors = '';
  child.stderr.on('data', data => { errors += data; });
  return await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { child.kill(); reject(new Error('Fixture startup timed out: ' + errors)); }, 15000);
    child.stdout.on('data', data => {
      buffer += data;
      for (const line of buffer.split('\n')) {
        if (!line.startsWith('{')) continue;
        try { const node = JSON.parse(line); if (node.url) { clearTimeout(timer); resolve({ ...node, child }); return; } } catch {}
      }
    });
    child.on('exit', code => { clearTimeout(timer); reject(new Error(`Fixture exited (${code}): ${errors}`)); });
  });
}
async function request(node, route, body, headers = {}) {
  const response = await fetch(node.url + route, { method: body ? 'POST' : 'GET', headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...headers }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(20000) });
  const data = await response.json(); return { status: response.status, data };
}
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function ready(node) { for (let attempt = 0; attempt < 50; attempt++) { try { const result = await request(node, '/api/state'); if (result.status === 200) return result.data; } catch {} await wait(100); } throw new Error('HTTP listener was not ready'); }
try {
  const first = await start('A'), second = await start('B');
  const firstState = await ready(first), secondState = await ready(second);
  for (const node of [first, second]) {
    assert.match(node.namedURL, /^http:\/\/autoapprove-[a-f0-9]{12}\.local:\d+$/);
    const named = await (await fetch(node.namedURL + '/api/state')).json();
    assert.equal(named.id, node.id, 'A Mac-specific Bonjour name must resolve to the exact instance/port');
  }
  assert.equal(firstState.sessions.length, 6); assert.equal(secondState.sessions.length, 6);
  const html = await fetch(first.url); assert.equal(html.status, 200); assert.ok((await html.text()).includes('터미널 화면'));
  assert.match(html.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  let discovery = false;
  for (let attempt = 0; attempt < 15; attempt++) {
    const result = await request(first, '/api/network');
    if (result.data.nodes.some(node => node.id === second.id && node.online)) { discovery = true; break; }
    await wait(300);
  }
  assert.equal(discovery, true, 'Bonjour must automatically discover the second isolated instance');
  const manual = await request(first, '/api/peers', { address: second.url }); assert.equal(manual.status, 200);
  const dashboard = await request(first, '/api/network'); assert.ok(dashboard.data.nodes.find(node => node.id === second.id)?.online);
  const wrongMac = await request(second, '/api/action', { action: 'pause', paused: true, requestID: randomUUID() }, { 'X-AutoApprove-Node': first.id });
  assert.equal(wrongMac.status, 409); assert.equal((await request(second, '/api/state')).data.snapshot.paused, false);
  const paused = await request(first, `/api/action?node=${second.id}`, { action: 'pause', paused: true, requestID: randomUUID() }); assert.equal(paused.status, 200);
  assert.equal((await request(second, '/api/state')).data.snapshot.paused, true);
  assert.equal((await request(first, '/api/state')).data.snapshot.paused, false);
  await request(first, `/api/action?node=${second.id}`, { action: 'pause', paused: false, requestID: randomUUID() });
  const id = secondState.sessions.find(view => view.session.id.includes('+'))?.session.id;
  assert.ok(id, 'Encoded identity fixture must be present');
  assert.ok(id.includes('+') && id.includes(' '), 'Forwarded fixture identity covers literal plus and spaces');
  const enabled = await request(first, `/api/action?node=${second.id}`, { action: 'automatic', sessionID: id, enabled: true, requestID: randomUUID() }); assert.equal(enabled.status, 200);
  assert.equal((await request(second, '/api/state')).data.sessions.find(view => view.session.id === id).session.automatic, true);
  await request(first, `/api/action?node=${second.id}`, { action: 'automatic', sessionID: id, enabled: false, requestID: randomUUID() });
  const route = '/api/terminal?' + new URLSearchParams({ node: second.id, session: id });
  const frame = await request(first, route); assert.equal(frame.status, 200); assert.match(frame.data.screen, /합성 데이터 · B/);
  const compact = await request(first, route + '&revision=' + encodeURIComponent(frame.data.revision));
  assert.equal(compact.status, 200); assert.equal(compact.data.screen, undefined);
  assert.equal(compact.data.revision, frame.data.revision); assert.deepEqual(compact.data.keys, frame.data.keys);
  const legacy = await request(first, route); assert.equal(legacy.data.screen, frame.data.screen, 'Clients without a revision keep the full frame protocol');
  const input = { requestID: randomUUID(), sessionID: id, revision: frame.data.revision, kind: 'text', text: '웹에서 보낸 한글 · 검증용' };
  const sent = await request(first, `/api/input?node=${second.id}`, input); assert.equal(sent.status, 200);
  const replay = await request(first, `/api/input?node=${second.id}`, input); assert.deepEqual(replay, sent);
  const after = await request(first, route); assert.equal(after.data.screen.split(input.text).length - 1, 1);
  for (let index = 0; index < 70; index++) assert.equal((await request(first, '/api/state')).status, 200, 'Repeated polling must not exhaust the listener');
  const denied = await request(first, '/api/action', { action: 'pause', paused: true, requestID: randomUUID() }, { Origin: 'https://unrelated.example' }); assert.equal(denied.status, 403);
  const publicAddress = await request(first, '/api/peers', { address: 'http://8.8.8.8:8765' }); assert.equal(publicAddress.status, 400);
  const unsupported = await request(first, '/api/action', { action: 'hook', requestID: randomUUID() }); assert.equal(unsupported.status, 404);
  console.log('PASS: Bonjour discovery/named URLs, code-free HTTP, cross-Mac pause/automatic/input, exact Mac/terminal, duplicate prevention, origin checks and private addresses');
  const info = { root, first: { id: first.id, url: first.url }, second: { id: second.id, url: second.url } };
  await writeFile(path.join(root, 'preview.json'), JSON.stringify(info, null, 2));
  if (process.argv.includes('--serve')) {
    console.log(JSON.stringify(info));
    await new Promise(resolve => { process.once('SIGINT', resolve); process.once('SIGTERM', resolve); });
  } else {
    second.child.kill(); await wait(200);
    const disconnected = await request(first, '/api/network'); assert.equal(disconnected.data.nodes.find(node => node.id === second.id)?.online, false);
    const restored = await start('B'); await ready(restored);
    let restoredPeer, restoredFrame, durable;
    const recoveryDeadline = Date.now() + 60000;
    while (Date.now() < recoveryDeadline) {
      const restoredDashboard = await request(first, '/api/network');
      restoredPeer = restoredDashboard.data.nodes.find(node => node.id === second.id);
      if (restoredPeer?.online) {
        restoredFrame = await request(first, route);
        if (restoredFrame.status === 200) {
          // Replay this already-completed request ID only, never a new input.
          durable = await request(first, `/api/input?node=${second.id}`, input);
          if (durable.status === 200) break;
        }
      }
      await wait(300); // Bonjour advertisement and endpoint resolution settle asynchronously.
    }
    assert.ok(restoredPeer?.online, 'Restarted Mac must be rediscovered: ' + (restoredPeer?.error || 'missing peer'));
    assert.equal(durable?.status, 200, 'Stored receipt must return after rediscovery: ' + JSON.stringify(durable?.data));
    assert.equal(restoredFrame?.status, 200, 'Restored terminal must be readable: ' + JSON.stringify(restoredFrame?.data));
    assert.equal(restoredFrame.data.screen.includes(input.text), false, 'Restarted receipt must not replay input');
    console.log('PASS: disconnect, rediscovery, stored peer address and durable input receipt after restart');
  }
} finally {
  for (const child of children) child.kill();
  await wait(100); await rm(root, { recursive: true, force: true });
}
