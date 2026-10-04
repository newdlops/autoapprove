// Only private inert CLI fixtures. Never touches an installed app/user CLI.
import { execFileSync, spawn } from 'node:child_process';
import { mkdir, mkdtemp, readdir, writeFile, rename, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { coreLinkArguments } from './swift-core-link.mjs';
const build = path.resolve('.build', process.argv.includes('--release') ? 'release' : 'debug');
const root = await mkdtemp(path.join(tmpdir(), 'autoapprove-terminal-sync-'));
const children = [], streams = [], checks = [];
const binary = path.join(root, 'TerminalSyncPreview');
try {
  const moduleCache = path.resolve('.build/cache/TerminalSyncPreview'); await mkdir(moduleCache, { recursive: true });
  const objects = (await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name));
  execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', moduleCache, '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build), ...objects, 'Tests/fixtures/terminal-sync-preview.swift', '-o', binary], { stdio: 'inherit' });
  async function launch(name) {
    const directory = path.join(root, name); await mkdir(directory);
    execFileSync('/usr/bin/cc', ['Tests/fixtures/pty-agent.c', '-o', path.join(directory, 'codex')]);
    const child = spawn(binary, [directory], { stdio: ['ignore', 'pipe', 'inherit'] }); children.push(child);
    return await new Promise((resolve, reject) => {
      let output = ''; const timer = setTimeout(() => reject(new Error('Original source fixture startup timeout')), 20000);
      child.stdout.on('data', data => { output += data; for (const line of output.split('\n')) try { const value = JSON.parse(line); if (value.url) { clearTimeout(timer); resolve(value); return; } } catch {} });
      child.on('exit', code => { clearTimeout(timer); reject(new Error('Original fixture exited ' + code)); });
    });
  }
  const local = await launch('local'), peer = await launch('peer');
  async function api(node, route, body, headers = {}) {
    const response = await fetch(node.url + route, { method: body ? 'POST' : 'GET', headers: { ...headers, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(10000) });
    return { status: response.status, data: await response.json() };
  }
  async function macInput(node, value, command) {
    const temp = node.macInputPath + '.tmp';
    await writeFile(temp, JSON.stringify({ id: randomUUID(), ...(command ? { command } : { data: Buffer.from(value).toString('base64') }) })); await rename(temp, node.macInputPath);
  }
  async function stream(node, gateway = node) {
    const query = new URLSearchParams({ session: node.sessionID, ...(gateway !== node ? { node: node.nodeID } : {}) });
    const controller = new AbortController(); const timer = setTimeout(() => controller.abort(), 5000);
    let response; try { response = await fetch(gateway.url + '/api/terminal/stream?' + query, { signal: controller.signal }); } finally { clearTimeout(timer); }
    assert.equal(response.status, 200, 'Existing terminal must provide a live stream without starting a PTY');
    assert.match(response.headers.get('content-type') || '', /^text\/event-stream/);
    const reader = response.body.getReader(), decoder = new TextDecoder(); let buffer = '';
    const output = { close: () => controller.abort(), async next(timeout = 6000) {
      const timer = setTimeout(() => controller.abort(new Error('Original screen SSE timeout')), timeout);
      try { while (true) {
        const boundary = buffer.indexOf('\n\n');
        if (boundary >= 0) {
          const frame = buffer.slice(0, boundary); buffer = buffer.slice(boundary + 2);
          const event = frame.split('\n').find(line => line.startsWith('event:'))?.slice(6).trim(); if (!event) continue;
          const data = JSON.parse(frame.split('\n').filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n'));
          return { event, data };
        }
        const result = await reader.read(); if (result.done) return null; buffer += decoder.decode(result.value, { stream: true });
      } } finally { clearTimeout(timer); }
    } }; streams.push(output); return output;
  }
  async function until(source, text) {
    for (let count = 0; count < 40; count++) { const value = await source.next(); assert.ok(value); assert.equal(value.event, 'screen'); if (value.data.screen?.includes(text)) return value.data; }
    throw new Error('Expected original output: ' + text);
  }
  async function unchanged(node) {
    const state = await api(node, '/api/state'); assert.equal(state.status, 200);
    assert.equal(state.data.sessions.length, 1); const view = state.data.sessions[0];
    assert.equal(view.session.id, node.sessionID); assert.equal(view.session.pid, node.pid); assert.equal(view.session.tty, node.tty);
    assert.equal(view.pty, undefined); assert.equal(view.session.automatic, true); process.kill(node.pid, 0);
  }
  await unchanged(local); const source = await stream(local); let frame = await until(source, 'READY>');
  assert.equal(frame.sessionID, local.sessionID); assert.ok(frame.streamID); assert.ok(!Number.isNaN(Date.parse(frame.observedAt)));
  await macInput(local, 'MAC-SIDE-CHANGE\r'); frame = await until(source, 'RECEIVED:MAC-SIDE-CHANGE'); await unchanged(local);
  checks.push('Mac-side input pushes the exact pre-existing screen without new sessions');
  for (const [kind, text] of [['characters', 'PHONE-한글'], ['left', ''], ['right', ''], ['enter', '']]) {
    const value = await api(local, '/api/input', { requestID: randomUUID(), sessionID: local.sessionID, revision: frame.revision, streamID: frame.streamID, relay: true, kind, text }); assert.equal(value.status, 200, kind);
  }
  frame = await until(source, 'RECEIVED:PHONE-한글'); await unchanged(local);
  checks.push('Phone characters, Unicode, cursor keys and Return reach the original foreground PID with automation ON');
  const second = await stream(local); await until(second, 'RECEIVED:PHONE-한글'); await unchanged(local); second.close();
  const quiet = await source.next(); assert.equal(quiet.event, 'screen'); assert.equal(quiet.data.screen, undefined, 'Idle control refresh must not retransmit the screen'); assert.ok(quiet.data.observedAt);
  checks.push('Reconnection shares the same terminal and compact updates keep input fresh');
  const held = [];
  try {
    for (let count = 0; count < 11; count++) held.push(await stream(local));
    assert.equal((await api(local, '/api/terminal/stream?session=' + encodeURIComponent(local.sessionID))).status, 429);
    assert.equal((await api(local, '/api/state')).status, 200, 'Original streams must leave room for normal controls');
  } finally { held.forEach(value => value.close()); }
  await new Promise(resolve => setTimeout(resolve, 150));
  const recovered = await stream(local); await until(recovered, 'RECEIVED:PHONE-한글'); recovered.close();
  checks.push('Original streams use the bounded SSE slots and cancelling viewers releases capacity');
  assert.equal((await api(local, '/api/terminal/stream?session=missing')).status, 409);
  assert.equal((await api(local, '/api/terminal/stream?session=' + encodeURIComponent(local.sessionID), undefined, { Origin: 'https://example.com' })).status, 403);
  await api(local, '/api/peers', { address: peer.url }); const relayed = await stream(peer, local); let peerFrame = await until(relayed, 'READY>');
  await macInput(peer, 'PEER-MAC-CHANGE\r'); peerFrame = await until(relayed, 'RECEIVED:PEER-MAC-CHANGE');
  assert.equal((await api(local, '/api/input?node=' + peer.nodeID, { requestID: randomUUID(), sessionID: peer.sessionID, revision: peerFrame.revision, streamID: peerFrame.streamID, relay: true, kind: 'submit', text: 'PEER-PHONE' })).status, 409, 'A composed submit cannot masquerade as live relay');
  assert.equal((await api(local, '/api/input?node=' + peer.nodeID, { requestID: randomUUID(), sessionID: peer.sessionID, revision: peerFrame.revision, kind: 'submit', text: 'PEER-PHONE' })).status, 200);
  await until(relayed, 'RECEIVED:PEER-PHONE'); await unchanged(peer);
  checks.push('A gateway relays bidirectional original-session synchronization with exact node/source identity');
  await macInput(peer, '', 'close'); const ended = await relayed.next(); assert.equal(ended.event, 'failure');
  const stopped = await api(peer, '/api/state'); assert.equal(stopped.data.sessions.length, 0); assert.equal((await api(peer, '/api/terminal/stream?session=' + encodeURIComponent(peer.sessionID))).status, 409);
  checks.push('Original terminal exit ends synchronization, removes active inventory and never forks');
  await macInput(local, '', 'web-off'); assert.equal(await source.next(), null); process.kill(local.pid, 0);
  checks.push('Web OFF cancels streaming while preserving the Mac-owned original CLI');
  console.log(JSON.stringify({ checks, originalProcessPreserved: true, implicitPTYCreations: 0 }, null, 2));
} finally {
  for (const stream of streams) stream.close();
  for (const child of children) child.kill('SIGTERM');
  await new Promise(resolve => setTimeout(resolve, 300));
  await rm(root, { recursive: true, force: true });
}
