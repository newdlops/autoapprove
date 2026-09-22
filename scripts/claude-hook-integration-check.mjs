// A copied inert PTY fixture and a private socket/database; never opens a real terminal or Claude job.
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, copyFile, rm } from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

const exec = promisify(execFile), binary = path.resolve(process.argv[2] || '.build/release/autoapprove');
const root = await mkdtemp('/private/tmp/aa-hooks-'), state = path.join(root, 'state'), proxyHome = path.join(root, 'proxy');
const children = [], connections = new Set();
let daemon, proxy, dropped = false, diagnostics = '';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function request(method, params = {}) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(path.join(state, 'bridge.sock'));
    let buffer = '';
    const timer = setTimeout(() => { socket.destroy(); reject(Error(`Timeout ${method}`)); }, 6000);
    socket.on('error', error => { clearTimeout(timer); reject(error); });
    socket.on('connect', () => socket.write(JSON.stringify({ method, params }) + '\n'));
    socket.on('data', chunk => {
      buffer += chunk;
      if (!buffer.includes('\n')) return;
      clearTimeout(timer); socket.destroy();
      const reply = JSON.parse(buffer.slice(0, buffer.indexOf('\n')));
      reply.error ? reject(Error(reply.error)) : resolve(reply.result);
    });
  });
}
async function until(check, label, timeout = 18000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = await check(); if (value) return value; await delay(100); }
  throw Error(`Timed out: ${label}\n${diagnostics}`);
}
function start(executable, args, options = {}) {
  const child = spawn(executable, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options });
  child.stderr.on('data', chunk => { diagnostics += chunk; }); children.push(child); return child;
}
async function startServer() {
  daemon = start(binary, ['serve', '--home', state], { env: { ...process.env, CLAUDE_CONFIG_DIR: path.join(root, 'config') } });
  await until(async () => { try { return await request('status'); } catch { return false; } }, 'server');
}
async function stop(child) {
  if (child.exitCode === null && child.signalCode === null) { child.kill('SIGTERM'); await new Promise(resolve => child.once('close', resolve)); }
}
function helper(session, index, home = state) {
  const question = `[${index}] 이 작업을 허용할까요?`;
  const payload = { hook_event_name: 'PreToolUse', session_id: 'fixture', agentPID: session.pid, agentStarted: session.started,
    tty: session.tty, cwd: session.cwd, tool_name: 'AskUserQuestion', tool_use_id: randomUUID(),
    tool_input: { questions: [{ question, multiSelect: false, options: [{ label: '거부' }, { label: '항상 허용' }, { label: '허용' }] }] } };
  const child = start(binary, ['hook', '--home', home], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '', ended = false;
  child.stdout.on('data', chunk => { output += chunk; });
  const completion = new Promise((resolve, reject) => child.once('close', code => {
    ended = true;
    if (code !== 0) reject(Error(`Helper exited ${code}: ${diagnostics}`));
    else { try { resolve(JSON.parse(output)); } catch (error) { reject(error); } }
  }));
  child.stdin.end(JSON.stringify(payload));
  return { child, completion, question, ended: () => ended };
}
async function current(session) {
  return until(async () => (await request('status')).sessions.find(s => s.id === session.id)?.claudeApprovals?.[0], 'pending app approval');
}
function assertAnswer(result, question) { assert.deepEqual(result.hookSpecificOutput.updatedInput.answers, { [question]: '허용' }); }

try {
  await mkdir(proxyHome); await mkdir(path.join(root, 'config'));
  const holder = path.join(root, 'holder'), fixture = path.join(root, 'claude');
  await exec('/usr/bin/cc', ['Tests/fixtures/pty-holder.c', '-o', holder]);
  await copyFile(holder, fixture);
  start(holder, [fixture], { cwd: root });
  await startServer();
  const session = await until(async () => (await request('status')).sessions.find(s => s.cwd === root && s.agent === 'claude'), 'inert process');
  const manual = helper(session, 1), first = await current(session);
  await delay(5200); assert.equal(manual.ended(), false, 'Manual requests remain available beyond the old timeout');
  await request('claudeApprove', { sessionID: session.id, requestID: first.id, enableAutomatic: true });
  assertAnswer(await manual.completion, manual.question);

  const started = Date.now(), next = helper(session, 2);
  assertAnswer(await next.completion, next.question);
  assert(Date.now() - started >= 4900, 'The next question gets its own five-second countdown');

  const duringRestart = helper(session, 3);
  await current(session); await stop(daemon); await delay(1200); await startServer();
  assertAnswer(await duringRestart.completion, duringRestart.question);

  // Drop exactly the first response containing an approval. The helper must retry its same UUID.
  proxy = net.createServer(client => {
    connections.add(client); client.on('close', () => connections.delete(client)); client.on('error', () => {});
    const upstream = net.createConnection(path.join(state, 'bridge.sock'));
    connections.add(upstream); upstream.on('close', () => connections.delete(upstream)); upstream.on('error', () => client.destroy());
    client.pipe(upstream); let buffer = '';
    upstream.on('data', chunk => {
      buffer += chunk;
      while (buffer.includes('\n')) {
        const end = buffer.indexOf('\n'), line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        const message = JSON.parse(line);
        if (!dropped && message.result?.autoapproveBridge?.response?.hookSpecificOutput) { dropped = true; client.destroy(); upstream.destroy(); }
        else client.write(line + '\n');
      }
    });
    client.on('close', () => upstream.destroy());
  });
  await new Promise(resolve => proxy.listen(path.join(proxyHome, 'bridge.sock'), resolve));
  const lost = helper(session, 4, proxyHome);
  assertAnswer(await lost.completion, lost.question); assert(dropped);
  const status = await request('status');
  assert.equal(status.events.length, 4, 'A dropped response must not create duplicate approvals');
  assert(status.events.every(event => event.outcome === '질문 응답 전달' && event.answer === '허용'));
  assert.equal(status.sessions.find(s => s.id === session.id).claudeApprovals, undefined);

  await request('automatic', { sessionID: session.id, enabled: false });
  const handoff = helper(session, 5), pending = await current(session);
  await request('claudeRelease', { sessionID: session.id, requestID: pending.id });
  assert.deepEqual(await handoff.completion, {});
  console.log('PASS real helper: manual app approval, next automatic response after five seconds, in-flight app restart, dropped response replay exactly once, delivery receipts and terminal handoff');
} finally {
  for (const socket of connections) socket.destroy();
  if (proxy) await new Promise(resolve => proxy.close(resolve));
  for (const child of children.reverse()) await stop(child);
  await rm(root, { recursive: true, force: true });
}
