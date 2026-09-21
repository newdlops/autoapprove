import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import net from 'node:net';
import assert from 'node:assert/strict';

const exec = promisify(execFile);
const home = await mkdtemp(path.join(tmpdir(), 'aa-e2e-'));
const binary = path.resolve(process.argv[2] || '.build/debug/autoapprove');
const server = spawn(binary, ['serve', '--home', home], { stdio: ['ignore', 'pipe', 'pipe'] });
let diagnostics = '';
server.stderr.on('data', data => { diagnostics += data; });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function request(method, params = {}, fragment = false) {
  return new Promise((resolve, reject) => {
    const socket = net.createConnection(path.join(home, 'bridge.sock'));
    socket.setTimeout(3000);
    let buffer = '';
    socket.on('connect', () => {
      const message = JSON.stringify({ id: 'integration', method, params }) + '\n';
      if (fragment) { socket.write(message.slice(0, 9)); setTimeout(() => socket.write(message.slice(9)), 5); }
      else { socket.write(message); }
    });
    socket.on('data', data => {
      buffer += data;
      if (buffer.includes('\n')) { socket.end(); const response = JSON.parse(buffer.split('\n')[0]); response.error ? reject(Error(response.error)) : resolve(response.result); }
    });
    socket.on('error', reject);
    socket.on('timeout', () => { socket.destroy(); reject(Error('Timed out')); });
  });
}

try {
  let ready = false;
  for (let i = 0; i < 60; i++) {
    try { await request('status'); ready = true; break; } catch { await sleep(100); }
  }
  assert.ok(ready, `Bridge startup failed: ${diagnostics}`);
  const base = { session_id: 'integration-only', cwd: '/tmp/AutoApprove integration test', hook_event_name: 'SessionStart', requestID: 'start' };
  assert.deepEqual(await request('hook', base, true), {});
  const permission = { ...base, hook_event_name: 'PermissionRequest', requestID: 'one', tool_name: 'Bash', tool_input: { command: 'printf test' } };
  assert.deepEqual(await request('hook', permission), {});
  await request('automatic', { sessionID: 'claude:integration-only', enabled: true });
  permission.requestID = 'two';
  assert.equal((await request('hook', permission)).hookSpecificOutput.decision.behavior, 'allow');
  assert.deepEqual(await request('hook', permission), {});
  await request('pause', { paused: true });
  permission.requestID = 'three';
  assert.deepEqual(await request('hook', permission), {});
  await request('pause', { paused: false });
  const hook = spawn(binary, ['hook', '--home', home], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '';
  hook.stdout.on('data', data => { output += data; });
  hook.stdin.end(JSON.stringify({ ...permission, requestID: undefined }));
  const code = await new Promise(resolve => hook.on('close', resolve));
  assert.equal(code, 0);
  assert.equal(JSON.parse(output).hookSpecificOutput.decision.behavior, 'allow');
  const question = '지금 이 워크트리의 미커밋·브랜치 현황을 먼자 훑어볼까요?';
  const questions = [{ question, header: '작업 위치', multiSelect: false, options: [{ label: '아니오', description: '다른 위치' }, { label: '예', description: '현재 위치에서 진행' }] }];
  const ask = { ...base, hook_event_name: 'PreToolUse', requestID: 'ask', tool_use_id: 'ask-one', tool_name: 'AskUserQuestion', tool_input: { questions } };
  const answerHook = spawn(binary, ['hook', '--home', home], { stdio: ['pipe', 'pipe', 'pipe'] });
  let answerOutput = '';
  answerHook.stdout.on('data', data => { answerOutput += data; });
  answerHook.stdin.end(JSON.stringify(ask));
  assert.equal(await new Promise(resolve => answerHook.on('close', resolve)), 0);
  const answered = JSON.parse(answerOutput).hookSpecificOutput;
  assert.equal(answered.hookEventName, 'PreToolUse');
  assert.equal(answered.permissionDecision, 'allow');
  assert.deepEqual(answered.updatedInput, { questions, answers: { [question]: '예' } });
  assert.deepEqual(await request('hook', { ...ask, hook_event_name: 'PermissionRequest', requestID: 'ask-again' }), {});
  const choose = { ...ask, tool_use_id: 'choose-three', requestID: 'choose', tool_input: { questions: [{
    question: '지금 제가 뭐부터 하면 될까요?', options: [
      { label: '미커물 현황 훑기', description: '워크트리 상태를 정리합니다.' },
      { label: '여는 PR 상태 점검', description: 'CI와 리뷰를 확인합니다.' },
      { label: '지정해 주시는 일', description: '입력한 작업을 진행합니다.' }
    ]
  }] } };
  assert.deepEqual(await request('hook', choose), {});
  await request('hook', { ...base, hook_event_name: 'Notification', notification_type: 'permission_prompt', message: 'Claude needs your permission', requestID: 'reminder' });
  const status = await request('status');
  assert.equal(status.events.filter(event => event.outcome === '승인 전달').length, 2);
  assert.equal(status.events.filter(event => event.outcome === '질문 응답 전달' && event.answer === '예').length, 1);
  const waiting = status.sessions.find(session => session.id === 'claude:integration-only');
  assert.equal(waiting.phase, 'input');
  assert.ok(waiting.pendingSummary.includes('3. 지정해 주시는 일'));
  assert.ok(waiting.pendingRequestID.endsWith(':choose-three'));
  const cli = await exec(binary, ['status', '--home', home], { timeout: 5000 });
  assert.ok(JSON.parse(cli.stdout).sessions.some(session => session.id === 'claude:integration-only'));
  console.log('PASS Unix socket framing, opt-in, deduplication, pause/resume, CLI permission and question hook round trips, saved answers, CLI status');
} finally {
  server.kill('SIGTERM');
  await new Promise(resolve => { if (server.exitCode !== null) resolve(); else server.once('close', resolve); });
  await rm(home, { recursive: true, force: true });
}
