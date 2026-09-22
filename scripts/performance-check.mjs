import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readdir, rm } from 'node:fs/promises';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';

// Build the same workload against either the original or optimized release core.
const build = path.resolve('.build/release');
const output = path.resolve('.runtime/performance-check');
await mkdir(output, { recursive: true });
execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/PerformanceCheck'),
  '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3',
  ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)),
  'Tests/fixtures/performance-check.swift', '-o', path.join(output, 'check')], { stdio: 'inherit' });
const home = await mkdtemp('/private/tmp/aa-perf-');
const child = spawn(path.join(output, 'check'), [home], { stdio: ['pipe', 'pipe', 'pipe'] });
const exited = new Promise(resolve => child.once('close', resolve));
let stdout = '', stderr = '';
child.stdout.on('data', data => { stdout += data; });
child.stderr.on('data', data => { stderr += data; });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const peers = [];
let sequence = 0;
function connect() {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(path.join(home, 'bridge.sock'));
    const waiting = new Map();
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('error', error => { reject(error); for (const item of waiting.values()) item.reject(error); });
    socket.on('data', data => {
      buffer += data;
      let end;
      while ((end = buffer.indexOf('\n')) >= 0) {
        const response = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
        const pending = waiting.get(response.id);
        if (pending) { waiting.delete(response.id); clearTimeout(pending.timer); response.error ? pending.reject(Error(response.error)) : pending.resolve(response.result); }
      }
    });
    socket.once('connect', () => resolve({
      socket,
      request(method, params = {}) {
        return new Promise((resolve, reject) => {
          const id = String(++sequence);
          const timer = setTimeout(() => { waiting.delete(id); reject(Error(`Timed out: ${method}`)); }, 10000);
          waiting.set(id, { resolve, reject, timer });
          socket.write(JSON.stringify({ id, method, params }) + '\n');
        });
      }
    }));
  });
}
try {
  for (let attempt = 0; !stdout.includes('READY\n'); attempt++) {
    assert.ok(child.exitCode === null && child.signalCode === null && attempt < 100, `Fixture startup failed: ${stderr}`);
    await sleep(50);
  }
  const start = performance.now();
  for (let index = 0; index < 14; index++) peers.push(await connect());
  const registrations = peers.map((_, index) => ({ terminals: [{ id: `terminal-${index}`, shellPID: 7000 + index, name: `Terminal ${index}`, streamAttached: true }] }));
  for (let round = 0; round < 30; round++) {
    for (const [index, peer] of peers.entries()) {
      const response = await peer.request('register', registrations[index]);
      assert.equal(typeof response.terminalSizes, 'object', 'Even unchanged registrations must receive size replies');
      await peer.request('screen', { terminalID: 'unmanaged-terminal', screen: 'ordinary build output', generation: 'fixture' });
    }
  }
  // A real registration change must still update the correct terminal immediately.
  registrations[0].terminals[0].name = 'Renamed terminal';
  await peers[0].request('register', registrations[0]);
  const status = await peers[0].request('status');
  assert.equal(status.sessions.find(session => session.pid === 9000).terminalTitle, 'Renamed terminal');
  assert.equal(status.sessions.length, 15);
  const wallSeconds = (performance.now() - start) / 1000;
  child.stdin.end('finish\n');
  const code = await exited;
  assert.equal(code, 0, stderr);
  const report = JSON.parse(stdout.trim().split('\n').at(-1));
  if (process.argv.includes('--assert-quiet')) assert.ok(report.publications <= 30, `Unchanged traffic caused ${report.publications} UI publications`);
  console.log(JSON.stringify({ ...report, wallSeconds, bridgeWindows: 14, heartbeatRounds: 30, messages: 842 }, null, 2));
} finally {
  for (const peer of peers) peer.socket.destroy();
  if (child.exitCode === null && child.signalCode === null) {
    child.kill('SIGTERM');
  }
  await exited;
  await rm(home, { recursive: true, force: true });
}
