// Inert PTYs and a private Claude registry. No real agent receives a reply or input.
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, copyFile, writeFile, rm } from 'node:fs/promises';
import net from 'node:net';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

const exec = promisify(execFile);
const binary = path.resolve(process.argv[2] || '.build/debug/autoapprove');
const root = await mkdtemp('/private/tmp/aa-claude-parent-');
const state = path.join(root, 'state'), config = path.join(root, 'claude');
const children = [], pending = new Map();
const inputs = [];
let socket, diagnostics = '';
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function until(check, label) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) { const value = await check(); if (value) return value; await delay(100); }
  throw Error(`Timed out: ${label}\n${diagnostics}`);
}
function request(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = randomUUID();
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`No response: ${method}`)); }, 5000);
    pending.set(id, message => { clearTimeout(timer); message.error ? reject(Error(message.error)) : resolve(message.result); });
    socket.write(JSON.stringify({ id, method, params }) + '\n');
  });
}
function start(executable, args, options = {}) {
  const child = spawn(executable, args, { stdio: ['ignore', 'pipe', 'pipe'], ...options });
  child.stdout.resume(); child.stderr.on('data', chunk => { diagnostics += chunk; }); children.push(child); return child;
}
try {
  await mkdir(path.join(config, 'sessions'), { recursive: true });
  const holder = path.join(root, 'pty-holder');
  await exec('/usr/bin/cc', ['Tests/fixtures/pty-holder.c', '-o', holder]);
  const fixtures = [];
  for (let index = 0; index < 2; index++) {
    const directory = path.join(root, `fixture-${index}`);
    await mkdir(directory); await copyFile(holder, path.join(directory, 'claude'));
    const host = start(holder, [path.join(directory, 'claude')], { cwd: directory });
    fixtures.push({ id: `fixture-${index}`, name: `검증 ${index}`, shellPID: host.pid, directory, streamAttached: true, host });
  }
  start(binary, ['serve', '--home', state], { env: { ...process.env, CLAUDE_CONFIG_DIR: config, TZ: 'Asia/Seoul' } });
  socket = await until(async () => {
    try { return await new Promise((resolve, reject) => {
      const client = net.createConnection(path.join(state, 'bridge.sock'));
      client.once('connect', () => resolve(client)); client.once('error', reject);
    }); } catch { return undefined; }
  }, 'isolated server');
  let buffer = '';
  socket.setEncoding('utf8');
  socket.on('data', chunk => {
    buffer += chunk;
    while (buffer.includes('\n')) {
      const end = buffer.indexOf('\n'), message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
      if (message.method === 'approve') { inputs.push(message); continue; }
      const callback = pending.get(message.id); pending.delete(message.id); callback?.(message);
    }
  });
  const sessions = await until(async () => {
    const status = await request('status');
    const found = fixtures.map(f => status.sessions.find(s => s.cwd === f.directory));
    return found.every(Boolean) ? found : undefined;
  }, 'PTY discovery');
  const [main, child] = sessions;
  const base = { session_id: 'isolated-child', agentPID: child.pid, agentStarted: child.started, tty: child.tty,
    cwd: child.cwd, requestID: 'start', hook_event_name: 'SessionStart' };
  await request('hook', base);
  await request('automatic', { sessionID: child.id, enabled: true });
  await request('register', { terminals: [{ ...fixtures[0], host: undefined }] });
  async function registration(session, values) {
    const started = (await exec('/bin/ps', ['-p', String(session.pid), '-o', 'lstart='], { env: { ...process.env, TZ: 'UTC', LC_ALL: 'C' } })).stdout.trim();
    await writeFile(path.join(config, 'sessions', `${session.pid}.json`), JSON.stringify({ pid: session.pid,
      pidDomain: 'darwin', procStart: started, ...values }));
  }
  await registration(main, { kind: 'interactive', parkedJobId: 'fixture-job' });
  await registration(child, { kind: 'bg', jobId: 'fixture-job' });
  const grouped = await until(async () => (await request('status')).sessions.find(s => s.id === main.id && s.backgroundSessions?.length === 1), 'registry parent grouping');
  assert.equal(grouped.automatic, false); assert.equal(grouped.backgroundSessions[0].automatic, false);
  assert.equal((await request('status')).sessions.some(s => s.id === child.id), false);
  const questions = [{ question: '이 작업을 허용할까요?', multiSelect: false, options: [{ label: '허용' }, { label: '항상 허용' }, { label: '거부' }] }];
  const changedAt = Date.now();
  await mkdir(path.join(config, 'jobs/fixture-job'), { recursive: true });
  await writeFile(path.join(config, 'jobs/fixture-job/state.json'), JSON.stringify({
    daemonShort: 'fixture-job', backend: 'daemon', state: 'working', tempo: 'blocked',
    resumeSessionId: 'isolated-child', updatedAt: new Date(changedAt + 1).toISOString(), block: { questions }
  }));
  await registration(child, { kind: 'bg', jobId: 'fixture-job', sessionId: 'isolated-child',
    status: 'waiting', waitingFor: 'input needed', statusUpdatedAt: changedAt });
  const recovered = await until(async () => {
    const main = (await request('status')).sessions.find(s => s.id === grouped.id);
    return main?.phase === 'input' && main.backgroundSessions[0].pendingRequestID?.startsWith('claude-state:') ? main : undefined;
  }, 'already open question without a new hook');
  assert.match(recovered.backgroundSessions[0].pendingSummary, /항상 허용/);
  assert.match(recovered.activityDetail, /이번 요청은 터미널에서/);
  assert.equal((await request('status')).events.length, 0, 'Read-only recovery must not report a fabricated response');
  const ask = { ...base, hook_event_name: 'PreToolUse', tool_name: 'AskUserQuestion', tool_input: { questions }, tool_use_id: 'off', requestID: 'off' };
  assert.deepEqual(await request('hook', ask), {});
  await request('automatic', { sessionID: main.id, enabled: true });
  ask.tool_use_id = 'once'; ask.requestID = 'once';
  const hook = spawn(binary, ['hook', '--home', state], { env: { ...process.env, TZ: 'Asia/Seoul' }, stdio: ['pipe', 'pipe', 'pipe'] });
  children.push(hook); let response = ''; hook.stdout.on('data', chunk => { response += chunk; }); hook.stdin.end(JSON.stringify(ask));
  assert.equal(await new Promise(resolve => hook.once('close', resolve)), 0);
  assert.deepEqual(JSON.parse(response).hookSpecificOutput.updatedInput, { questions, answers: { '이 작업을 허용할까요?': '허용' } });
  assert.deepEqual(await request('hook', { ...ask, hook_event_name: 'PermissionRequest' }), {});
  const audit = (await request('status')).events.find(e => e.answer === '허용');
  assert.equal(audit.sessionID, main.id); assert.equal(audit.originSessionID, child.id); assert.equal(audit.context.tty, child.tty);
  await request('pause', { paused: true });
  assert.deepEqual(await request('hook', { ...ask, tool_use_id: 'paused', requestID: 'paused' }), {});
  await request('pause', { paused: false });
  await request('screen', { terminalID: fixtures[0].id, generation: 'mirror', screen: 'Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel' });
  await delay(350);
  assert.equal(inputs.length, 0, 'The main screen must never receive duplicate input');
  fixtures[0].host.kill('SIGTERM');
  // The next child hook revalidates its main process without waiting for the next poll.
  await until(async () => {
    try { await exec('/bin/ps', ['-p', String(main.pid), '-o', 'pid=']); return false; } catch { return true; }
  }, 'main process exit');
  assert.deepEqual(await request('hook', { ...ask, tool_use_id: 'orphan', requestID: 'orphan' }), {});
  const orphan = (await request('status')).sessions.find(s => s.id === child.id);
  assert.equal(orphan.automatic, false);
  console.log('PASS real inert PTYs, UTC registry identity, recovered waiting question, one main row, inherited opt-in, Korean helper round trip, deduplication, audit origin, pause, mirrored-screen suppression and parent exit');
} finally {
  socket?.destroy();
  for (const child of children.reverse()) {
    if (child.exitCode === null && child.signalCode === null) {
      child.kill('SIGTERM'); await new Promise(resolve => child.once('close', resolve));
    }
  }
  await rm(root, { recursive: true, force: true });
}
