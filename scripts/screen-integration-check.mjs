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
const codexOnly = process.argv.includes('--codex-only');
const home = path.join(root, 'state');
const children = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let bridge;
let diagnostics = '';
const actions = [];
const prompt = 'Would you like to run the following command?\n\n$ printf fixture\n\n› 1. Yes, proceed (y)\n  2. Yes, don’t ask\n     again for this session (a)\n  3. No, and tell Codex what\n     to do differently (esc)\n\nPress enter to\nconfirm or esc to cancel';
const claudePrompt = "Do you want to proceed?\n❯ 1. Yes\n  2. Yes, don't ask again\n  3. No\nEsc to cancel";

async function until(check, label, timeout = 8000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) { const value = await check(); if (value) return value; await sleep(30); }
  throw new Error(`Timed out: ${label}\n${diagnostics}`);
}
class Bridge {
  waiting = new Map();
  rejections = 0;
  unacknowledged = new Set();
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
          if (!this.unacknowledged.has(message.terminalID)) void this.request('actionResult', { actionID: message.id, success });
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
  for (const [index, agent] of (codexOnly ? ['codex', 'codex'] : ['codex', 'codex', 'claude']).entries()) {
    const directory = path.join(root, `fixture-${index}`);
    await mkdir(directory);
    if (index === 0) await exec('/usr/bin/git', ['-c', 'core.hooksPath=/dev/null', 'init', '--quiet', '--initial-branch=fixture-main', directory]);
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
  if (codexOnly) {
    await bridge.request('register', { terminals: fixtures });
    for (const session of sessions) await bridge.request('automatic', { sessionID: session.id, enabled: true });
    const reportedCommand = "rg -n 'lora|adapter|error|warn' .cache/product-evaluation/server-clean.log";
    const dialog = command => 'Would you like to run the following command?\n\nEnvironment: local\n\n$ ' + command
      + "\n\n› 1. Yes, proceed (y)\n  2. Yes, and don't ask again for commands that start with `" + command
      + '` (p)\n  3. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel';
    const show = (index, screen) => bridge.request('screen', { terminalID: fixtures[index].id, screen, generation: 'same-cli-process' });
    await show(0, dialog('cat .cache/product-training-clean/ablation.py'));
    await until(() => actions.length === 1, 'first Codex-only permission');
    await until(async () => (await bridge.request('status')).events.some(event => event.outcome === '승인 입력 전달'), 'first input acknowledgement');
    await show(0, dialog(reportedCommand));
    await until(() => actions.length === 2, 'next Codex permission without an intervening working frame');
    assert.equal(actions[1].dialog, dialog(reportedCommand));
    assert.equal(actions[1].answer, '1');
    for (const rendering of [dialog(reportedCommand), 'Changed history\n' + dialog(reportedCommand),
      dialog(reportedCommand).replaceAll('product-evaluation', 'product-\n    evaluation'),
      dialog(reportedCommand).replaceAll(' (p)', ' (a)'), dialog(reportedCommand)]) {
      await show(0, rendering);
    }
    await sleep(250); assert.equal(actions.length, 2, 'Wrapping, history and shortcut changes cannot replay a sent input');
    const third = dialog('rg -n completed .cache/product-evaluation/server-clean.log');
    await show(0, third);
    await until(() => actions.length === 3, 'third distinct permission in the same process');
    await show(1, third);
    await until(() => actions.length === 4, 'identical request in another Codex terminal remains independent');
    await bridge.request('pause', { paused: true });
    const fourth = dialog('cat .cache/product-evaluation/summary.json');
    await show(0, fourth);
    await sleep(150); assert.equal(actions.length, 4, 'Pause also blocks an immediately following permission');
    await bridge.request('pause', { paused: false });
    await until(() => actions.length === 5, 'resume dispatches the distinct pending permission');
    const manual = dialog('choose task').replace("Yes, and don't ask again for commands that start with `choose task` (p)", 'Yes, deploy to production (p)');
    await show(0, manual);
    await sleep(150); assert.equal(actions.length, 5, 'A three-way task choice remains manual');
    assert.equal((await bridge.request('status')).sessions.find(session => session.id === sessions[0].id).pendingInTerminal, true);

    bridge.unacknowledged.add(fixtures[0].id);
    await show(0, dialog('cat first-pending.txt'));
    await until(() => actions.length === 6, 'first unacknowledged permission');
    await show(0, dialog('cat second-pending.txt'));
    await until(() => actions.length === 7, 'new permission can progress before the previous acknowledgement');
    await bridge.request('actionResult', { actionID: actions[5].id, success: false });
    await bridge.request('actionResult', { actionID: actions[6].id, success: true });
    await show(0, dialog('cat second-pending.txt'));
    await sleep(200); assert.equal(actions.length, 7, 'Late failure for the previous command cannot reopen the current command');
    bridge.unacknowledged.clear();

    bridge.rejections = 10;
    const rejected = dialog('cat rejected.txt');
    await until(async () => { await show(0, rejected); return actions.length === 11; }, 'bounded failure fixture');
    await until(async () => (await bridge.request('status')).sessions.find(session => session.id === sessions[0].id).pendingInTerminal, 'bounded failure requests review');
    bridge.rejections = 0;
    await show(0, dialog('cat following-request.txt'));
    await until(() => actions.length === 12, 'next command does not inherit the previous command retry limit');
    console.log('PASS Codex-only consecutive permissions in one process, reported screenshot, wrapping/history/shortcut deduplication, terminal isolation, pause/resume and manual choices');
  } else {
  await until(async () => {
    const status = await bridge.request('status');
    return status.sessions.find(session => session.id === sessions[0].id)?.gitBranch?.name === 'fixture-main'
      && status.sessions.find(session => session.id === sessions[1].id)?.gitBranch?.kind === 'notRepository';
  }, 'current folder Git metadata');
  await exec('/usr/bin/git', ['-C', fixtures[0].directory, 'symbolic-ref', 'HEAD', 'refs/heads/fixture-switched']);
  await until(async () => {
    const status = await bridge.request('status');
    return status.sessions.find(session => session.id === sessions[0].id)?.gitBranch?.name === 'fixture-switched';
  }, 'branch change refreshes without manual reload');
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
  const monitoringScreen = 'Watching fixture logs\n›\n1 background terminal running · /ps to view\n? for shortcuts';
  let monitorPoll = 0;
  await until(async () => {
    await bridge.request('screen', { terminalID: fixtures[0].id, screen: monitoringScreen.replace('fixture logs', `fixture logs ${monitorPoll++}`), generation: 'activity' });
    const session = (await bridge.request('status')).sessions.find(session => session.id === sessions[0].id);
    return session.phase === 'idle' && session.backgroundMonitoring === true;
  }, 'ready composer remains idle while background output changes');
  await bridge.request('screen', { terminalID: fixtures[0].id, screen: '• Working (esc to interrupt)\n' + idleScreen, generation: 'activity' });
  idle = (await bridge.request('status')).sessions.find(session => session.id === sessions[0].id);
  assert.equal(idle.phase, 'working'); assert.equal(idle.idleSince, undefined, 'New work clears the idle timer');
  assert.equal(idle.backgroundMonitoring, undefined, 'Foreground work removes the idle monitoring marker');
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

  bridge.unacknowledged.add(fixtures[0].id);
  for (let index = 0; index < 2; index++) {
    await bridge.request('screen', { terminalID: fixtures[index].id, screen: prompt, generation: 'timeout' });
  }
  await until(() => actions.length === 12, 'missing acknowledgement and delivered-but-still-waiting fixtures');
  const missingAck = actions.find(action => action.generation === 'timeout' && action.terminalID === fixtures[0].id);
  await until(async () => {
    for (let index = 0; index < 2; index++) {
      await bridge.request('screen', { terminalID: fixtures[index].id, screen: prompt, generation: 'timeout' });
    }
    const current = await bridge.request('status');
    return sessions.slice(0, 2).every(session => current.sessions.find(value => value.id === session.id).pendingInTerminal);
  }, 'both stalled approvals request user attention within a bounded time', 12000);
  status = await bridge.request('status');
  assert.ok(status.sessions.find(session => session.id === sessions[0].id).activityDetail.includes('8초'));
  assert.ok(status.sessions.find(session => session.id === sessions[1].id).activityDetail.includes('같은 요청'));
  assert.equal(status.events.filter(event => event.outcome === '전달 확인 시간 초과 · 터미널 확인 필요').length, 1);
  await bridge.request('actionResult', { actionID: missingAck.id, success: true });
  status = await bridge.request('status');
  assert.equal(status.events.filter(event => event.outcome === '전달 확인 시간 초과 · 터미널 확인 필요').length, 1, 'Late acknowledgement cannot erase the timeout');
  assert.equal(actions.length, 12, 'Uncertain delivery must not duplicate terminal input');

  await bridge.request('screen', { terminalID: fixtures[0].id, screen: prompt, generation: 'obsolete-timeout' });
  await until(() => actions.length === 13, 'obsolete acknowledgement fixture dispatched');
  await bridge.request('screen', { terminalID: fixtures[0].id, screen: 'Working (esc to interrupt)', generation: 'obsolete-timeout' });
  await until(async () => (await bridge.request('status')).events.filter(event => event.outcome === '전달 확인 시간 초과 · 터미널 확인 필요').length === 2,
    'obsolete attempt still receives a final audit result', 12000);
  const resumed = (await bridge.request('status')).sessions.find(session => session.id === sessions[0].id);
  assert.equal(resumed.phase, 'working'); assert.equal(resumed.pendingInTerminal, false, 'A late timeout cannot mark subsequent work as pending');
  bridge.unacknowledged.clear();

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
  console.log('PASS real PTY discovery, periodic Git branch refresh, exact target, wrapped three-choice approval, single-use screen, pause/resume, idle/background monitoring/work transitions, hook takeover, manual questions, confirmed-unsent retry, bounded retries, missing acknowledgement timeout, unchanged delivered dialog attention, late result isolation, disconnected off, locale-independent identity');
  }
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
