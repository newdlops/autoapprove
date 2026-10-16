import { coreLinkArguments } from './swift-core-link.mjs';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readdir, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';

const argument = (name, fallback) => process.argv.find(value => value.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const label = argument('label', 'current');
assert.match(label, /^[a-z0-9-]+$/);
const build = path.resolve(argument('core-build', '.build/release'));
const peerCount = Number(argument('peers', '32'));
assert.ok(Number.isInteger(peerCount) && peerCount >= 2 && peerCount <= 200);
const idleSeconds = Number(argument('idle-seconds', '1')), trials = Number(argument('trials', '3'));
assert.ok(Number.isFinite(idleSeconds) && idleSeconds >= 1 && idleSeconds <= 45);
assert.ok(Number.isInteger(trials) && trials >= 1 && trials <= 6);
const output = path.resolve('.runtime/local-resource-bench', label);
await mkdir(output, { recursive: true, mode: 0o700 });
const binary = path.join(output, 'check');
execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/LocalResourceBench'),
  '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
  ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)),
  'Tests/fixtures/local-resource-bench.swift', '-o', binary], { stdio: 'inherit' });
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const reports = [];
for (let trial = 0; trial < trials; trial++) {
  const directory = await mkdtemp('/private/tmp/aa-local-resource-');
  const child = spawn(binary, [directory], { stdio: ['pipe', 'pipe', 'pipe'] });
  const exited = new Promise(resolve => child.once('close', resolve));
  let stdout = '', stderr = '', sequence = 0;
  child.stdout.on('data', data => { stdout += data; }); child.stderr.on('data', data => { stderr += data; });
  const peers = [];
  function connect() {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(path.join(directory, 'bridge.sock'));
      let buffer = ''; const pending = new Map();
      socket.setEncoding('utf8');
      socket.on('data', chunk => {
        buffer += chunk; let end;
        while ((end = buffer.indexOf('\n')) >= 0) {
          const message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
          const request = pending.get(message.id);
          if (request) { clearTimeout(request.timer); pending.delete(message.id); request.resolve(message); }
        }
      });
      socket.on('error', reject);
      socket.once('connect', () => resolve({ socket, request(method, payload = '') {
        return new Promise((resolve, reject) => {
          const id = String(++sequence), timer = setTimeout(() => { pending.delete(id); reject(Error(`Local response timeout: ${method}, ${peers.length} connected peers`)); }, 8000);
          pending.set(id, { resolve, reject, timer });
          socket.write(JSON.stringify({ id, method, payload }) + '\n');
        });
      } }));
    });
  }
  try {
    for (let count = 0; !stdout.includes('READY\n'); count++) {
      assert.ok(child.exitCode === null && count < 100, `Fixture did not start: ${stderr}`); await sleep(25);
    }
    peers.push(await connect()); await peers[0].request('echo'); await sleep(150);
    const initial = (await peers[0].request('metrics')).result;
    // --peers=96 additionally stresses a single global worker pool's idle capacity.
    for (let index = 1; index < peerCount; index++) { const peer = await connect(); peers.push(peer); await peer.request('echo'); }
    await sleep(idleSeconds * 1000);
    const idle = (await peers[0].request('metrics')).result;
    const start = performance.now(), latencies = [], payload = '한글🙂\u001b[32moutput\u001b[0m'.repeat(128);
    for (let round = 0; round < 16; round++) {
      await Promise.all(peers.map(async peer => {
        const start = performance.now(), response = await peer.request('echo', payload);
        assert.equal(response.payload, payload); latencies.push(performance.now() - start);
      }));
    }
    const loaded = (await peers[0].request('metrics')).result;
    const socketWallSeconds = (performance.now() - start) / 1000;
    for (const peer of peers.splice(1)) peer.socket.destroy();
    await sleep(500);
    const released = (await peers[0].request('metrics')).result;
    latencies.sort((a, b) => a - b);
    const git = JSON.parse(execFileSync(binary, [path.join(directory, 'git'), '--git'], { encoding: 'utf8', timeout: 30000 }));
    assert.equal(git.gitLaunches, 1, 'Unchanged metadata must not launch Git again');
    reports.push({ initial, idle, loaded, released, git, messages: latencies.length,
      socketWallSeconds,
      responseP50ms: latencies[Math.floor(latencies.length * 0.5)], responseP95ms: latencies[Math.floor(latencies.length * 0.95)] });
  } finally {
    for (const peer of peers) peer.socket.destroy();
    child.stdin.end('finish\n');
    const timer = setTimeout(() => child.kill('SIGTERM'), 1000);
    await exited; clearTimeout(timer);
    await rm(directory, { recursive: true, force: true });
  }
}
const median = values => values.sort((a, b) => a - b)[Math.floor(values.length / 2)];
const result = { result: 'PASS', label, trials: reports.length, idlePeers: peerCount, idleSeconds,
  initialThreads: median(reports.map(report => report.initial.threads)), idleThreads: median(reports.map(report => report.idle.threads)),
  idlePeakResidentBytes: median(reports.map(report => report.idle.peakResidentBytes)),
  socketCPUSeconds: median(reports.map(report => report.loaded.cpuSeconds - report.idle.cpuSeconds)),
  responseP50ms: median(reports.map(report => report.responseP50ms)), responseP95ms: median(reports.map(report => report.responseP95ms)),
  gitCPUSeconds: median(reports.map(report => report.git.cpuSeconds)), gitWallSeconds: median(reports.map(report => report.git.wallSeconds)), reports };
await writeFile(path.join(output, 'report.json'), JSON.stringify(result, null, 2));
const { reports: raw, ...summary } = result;
console.log(JSON.stringify(summary, null, 2));
