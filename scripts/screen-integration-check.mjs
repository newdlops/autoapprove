// Real PTYs containing inert test processes, never the user's Claude/Codex sessions.
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, copyFile, rm } from 'node:fs/promises';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

const exec = promisify(execFile);
const root = await mkdtemp('/private/tmp/aa-screen-');
const binary = path.resolve(process.argv[2] || '.build/debug/autoapprove');
const home = path.join(root, 'state');
const children = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let bridge;
let diagnostics = '';
const actions = [];
const prompt = 'Would you like to run the following command?\n\n$ printf fixture\n\n› 1. Yes, proceed (y)\n  2. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel';
const claudePrompt = 'Do you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel';

async function until(check, label, timeout = 8000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = await check(); if (value) return value; await sleep(30); }
  throw new Error(`Timed out: ${label}\n${diagnostics}`);
}
class Bridge {
  waiting = new Map();
  rejections = 0;
  constructor(socket) {
    this.socket = socket;
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      buffer += chunk;
      let index;
      while ((index = buffer.indexOf('\n')) >= 0) {
        const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
        if (message.method === 'approve') {
          actions.push(message);
          // This fake extension acknowledges the intended terminal only; no UI input is sent.
          const success = this.rejections <= 0;
          if (!success) this.rejections--;
          void this.request('actionResult', { actionID: message.id, success });
        } else {
          const callback = this.waiting.get(message.id);
          this.waiting.delete(message.id);
          callback?.(message);
        }
      }
    });
    socket.on('error', error => { diagnostics += error.message; });
  }
  request(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const timer = setTimeout(() => { this.waiting.delete(id); reject(Error(`No response: ${method}`)); }, 3000);
      this.waiting.set(id, response => { clearTimeout(timer); response.error ? reject(Error(response.error)) : resolve(response.result); });
      this.socket.write(JSON.stringify({ id, method, params }) + '\n');
    });
  }
}

try {
  const holder = path.join(root, 'pty-holder');
  await exec('/usr/bin/cc', ['Tests/fixtures/pty-holder.c', '-o', holder]);
  const fixtures = [];
  for (const [index, agent] of ['codex', 'codex', 'claude'].entries()) {
    const directory = path.join(root, `fixture-${index}`);
    await mkdir(directory);
    const executable = path.join(directory, agent);
    await copyFile(holder, executable);
    const child = spawn(holder, [executable], { cwd: directory, stdio: ['ignore', 'pipe', 'pipe'] });
    children.push(child);
    child.stdout.resume(); child.stderr.on('data', data => { diagnostics += data; });
    fixtures.push({ id: `fixture-${index}`, agent, name: `검증 터미널 ${index}`, shellPID: child.pid, directory, streamAttached: true });
  }
  const server = spawn(binary, ['serve', '--home', home], { stdio: ['ignore', 'pipe', 'pipe'] });
  children.push(server); server.stdout.resume(); server.stderr.on('data', data => { diagnostics += data; });
  await until(async () => {
    try {
      const socket = await new Promise((resolve, reject) => {
        const client = net.createConnection(path.join(home, 'bridge.sock'));
        client.once('connect', () => resolve(client)); client.once('error', reject);
      });
      bridge = new Bridge(socket); return true;
    } catch { return false; }
  }, 'bridge startup');
  const sessions = await until(async () => {
    const status = await bridge.request('status');
    const found = fixtures.map(fixture => status.sessions.find(session => session.cwd === fixture.directory));
    return found.every(Boolean) ? found : undefined;
  }, 'PTY discovery');
  await bridge.request('register', { terminals: fixtures });
  assert.equal((await bridge.request('status')).sessions.find(session => session.id === sessions[0].id).terminalTitle, '검증 터미널 0');
  fixtures[0].name = '바뀐 제목';
  await bridge.request('register', { terminals: fixtures });
  assert.equal((await bridge.request('status')).sessions.find(session => session.id === sessions[0].id).terminalTitle, '바뀐 제목');
  for (let index = 0; index < 2; index++) {
    await bridge.request('screen', { terminalID: fixtures[index].id, screen: prompt, generation: 'first' });
  }
  await Promise.all(sessions.slice(0, 2).map(session => bridge.request('automatic', { sessionID: session.id, enabled: true })));
  await until(() => actions.length === 2, 'bulk enable dispatches both sessions');
  const saved = await until(async () => {
    const events = (await bridge.request('status')).events;
    return events.filter(event => event.outcome === '승인 입력 전달').length === 2 ? events : undefined;
  }, 'delivered attempts persist their final outcome');
  assert.equal(saved.length, 2, 'Dispatch and acknowledgement update one record per attempt');
  assert.ok(saved.every(event => event.context.agent === 'codex' && event.context.cwd.includes('fixture-') && event.request === prompt));
  assert.deepEqual(new Set(actions.map(action => action.terminalID)), new Set(['fixture-0', 'fixture-1']));
  for (let index = 0; index < 2; index++) {
    await bridge.request('screen', { terminalID: fixtures[index].id, screen: prompt, generation: 'first' });
  }
  await sleep(150); assert.equal(actions.length, 2, 'Unchanged prompts are single-use');

  await bridge.request('pause', { paused: true });
  await bridge.request('screen', { terminalID: fixtures[0].id, screen: prompt, generation: 'next' });
  await sleep(100); assert.equal(actions.length, 2);
  await bridge.request('pause', { paused: false });
  await until(() => actions.length === 3, 'resume dispatches waiting prompt');
  assert.equal(actions[2].terminalID, fixtures[0].id);
  assert.equal(actions[2].generation, 'next');

  const idleScreen = 'Completed.\n›\n? for shortcuts';
  await bridge.request('screen', { terminalID: fixtures[0].id, screen: idleScreen, generation: 'activity' });
  assert.equal((await bridge.request('status')).sessions.find(session => session.id === sessions[0].id).phase, 'unknown', 'One idle frame is not confirmation');
  await until(async () => {
    await bridge.request('screen', { terminalID: fixtures[0].id, screen: idleScreen, generation: 'activity' });
    return (await bridge.request('status')).sessions.find(session => session.id === sessions[0].id).phase === 'idle';
  }, 'idle composer confirmation');
  let idle = (await bridge.request('status')).sessions.find(session => session.id === sessions[0].id);
  assert.equal(typeof idle.idleSince, 'number');
  await bridge.request('screen', { terminalID: fixtures[0].id, screen: '• Working (esc to interrupt)\n' + idleScreen, generation: 'activity' });
  idle = (await bridge.request('status')).sessions.find(session => session.id === sessions[0].id);
  assert.equal(idle.phase, 'working'); assert.equal(idle.idleSince, undefined, 'New work clears the idle timer');
  assert.equal(actions.length, 3, 'Idle detection never sends approval input');

  const claude = sessions[2];
  await bridge.request('screen', { terminalID: fixtures[2].id, screen: claudePrompt, generation: 'old-screen' });
  await Promise.all([
    bridge.request('automatic', { sessionID: claude.id, enabled: true }),
    bridge.request('hook', { session_id: 'fixture-claude', agentPID: claude.pid, agentStarted: claude.started, requestID: 'takeover', hook_event_name: 'SessionStart' })
  ]);
  await sleep(200); assert.equal(actions.length, 3, 'Hook ownership cancels queued screen input');
  let status = await bridge.request('status');
  assert.equal(status.sessions.find(session => session.id === claude.id).channel, 'hook');

  const question = 'Which environment should be used?\n› 1. Development\n  2. Test\nEnter to select · Esc to cancel';
  await bridge.request('screen', { terminalID: fixtures[0].id, screen: question, generation: 'question' });
  status = await bridge.request('status');
  assert.equal(status.sessions.find(session => session.id === sessions[0].id).phase, 'input');
  assert.ok(status.sessions.find(session => session.id === sessions[0].id).pendingSummary.includes('Development'));
  await sleep(100); assert.equal(actions.length, 3, 'General questions never auto-select an answer');

  bridge.rejections = 1;
  await bridge.request('screen', { terminalID: fixtures[0].id, screen: prompt, generation: 'retry' });
  await until(() => actions.length === 4, 'first approval rejected before input');
  await until(async () => {
    await bridge.request('screen', { terminalID: fixtures[0].id, screen: 'Changed history\n' + prompt, generation: 'retry' });
    return actions.length === 5;
  }, 'fresh screen retries an explicitly unsent input');
  assert.equal(actions[4].dialog, prompt);
  await bridge.request('screen', { terminalID: fixtures[0].id, screen: 'More history\n' + prompt, generation: 'retry' });
  await sleep(150); assert.equal(actions.length, 5, 'Successful retry remains single-use');

  bridge.rejections = 10;
  await until(async () => {
    await bridge.request('screen', { terminalID: fixtures[0].id, screen: prompt, generation: 'bounded-retry' });
    return actions.length === 9;
  }, 'initial attempt plus at most three retries');
  for (let n = 0; n < 5; n++) await bridge.request('screen', { terminalID: fixtures[0].id, screen: prompt, generation: 'bounded-retry' });
  await sleep(150); assert.equal(actions.length, 9, 'Repeated validation failures stop for manual review');
  assert.equal((await bridge.request('status')).sessions.find(session => session.id === sessions[0].id).pendingInTerminal, true);
  bridge.rejections = 0;

  await bridge.request('hook', { session_id: 'fixture-claude', agentPID: claude.pid, agentStarted: claude.started, requestID: 'network-prompt', hook_event_name: 'Notification', notification_type: 'permission_prompt', message: 'Network approval pending' });
  await bridge.request('screen', { terminalID: fixtures[2].id, screen: claudePrompt, generation: 'network-screen' });
  await until(() => actions.length === 10, 'hook permission handed back to UI uses a connected screen');
  assert.equal(actions[9].terminalID, fixtures[2].id);
  assert.equal(actions[9].agent, 'claude');

  await bridge.request('register', { terminals: fixtures.map(fixture => ({ ...fixture, streamAttached: false })) });
  status = await bridge.request('status');
  const disconnected = status.sessions.find(session => session.id === sessions[0].id);
  assert.equal(disconnected.channel, 'none'); assert.equal(disconnected.automatic, true);
  await bridge.request('automatic', { sessionID: disconnected.id, enabled: false });
  status = await bridge.request('status');
  assert.equal(status.sessions.find(session => session.id === disconnected.id).automatic, false);

  const english = JSON.parse((await exec(binary, ['scan'], { env: { ...process.env, LANG: 'en_US.UTF-8', LC_ALL: 'en_US.UTF-8' } })).stdout);
  const korean = JSON.parse((await exec(binary, ['scan'], { env: { ...process.env, LANG: 'ko_KR.UTF-8', LC_ALL: 'ko_KR.UTF-8' } })).stdout);
  for (const session of sessions) {
    assert.equal(english.find(value => value.pid === session.pid)?.id, korean.find(value => value.pid === session.pid)?.id, 'Process identity must be locale independent');
  }
  console.log('PASS real PTY discovery, exact target, bulk enable, single-use screen, pause/resume, idle/work transitions, hook takeover, question display, confirmed-unsent retry, bounded retries, hook screen fallback, disconnected off, locale-independent identity');
} catch (error) {
  const processes = await exec('/bin/ps', ['-axo', 'pid=,ppid=,tty=,lstart=,comm=']);
  console.error(processes.stdout.split('\n').filter(line => line.includes(root)).join('\n'));
  console.error('Fixture processes:', children.map(child => ({ pid: child.pid, code: child.exitCode, signal: child.signalCode })));
  if (bridge) console.error('Fixture sessions:', (await bridge.request('status')).sessions.filter(session => session.cwd.includes('aa-screen')));
  throw error;
} finally {
  bridge?.socket.destroy();
  for (const child of children) { child.stdin?.end(); child.kill('SIGTERM'); }
  await Promise.all(children.map(child => new Promise(resolve => { if (child.exitCode !== null || child.signalCode !== null) resolve(); else child.once('close', resolve); })));
  await rm(root, { recursive: true, force: true });
}
