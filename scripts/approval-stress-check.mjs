// Invoked by screen-integration-check.mjs with isolated PTYs and a separate state directory.
// Measures the production engine and mock bridge; it does not type into Terminal.app.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { writeFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import path from 'node:path';
import assert from 'node:assert/strict';

const exec = promisify(execFile);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const percentile = (values, fraction) => {
  const sorted = [...values].sort((a, b) => a - b);
  return Math.round((sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)] ?? 0) * 10) / 10;
};

export async function runApprovalStress({ bridge, fixtures, sessions, actions, serverPID, home, count, reportPath, binary }) {
  const pending = new Map();
  const actionIDs = new Set();
  const latency = [];
  const checkpoints = [];
  const milestones = new Set([10, 100, 1000, 5000, 10000, 50000, 100000, count]);
  const expectedTotal = count * fixtures.length;
  let completed = 0, repeatedFrames = 0, duplicateInputs = 0, wrongInputs = 0, timeouts = 0;
  let failure;
  const start = performance.now();
  const memory = async () => Number((await exec('/bin/ps', ['-o', 'rss=', '-p', String(serverPID)])).stdout.trim());
  const initialRSSKB = await memory();
  const record = async stage => {
    const checkpoint = { stage, completed, seconds: Math.round((performance.now() - start) / 100) / 10,
      p95Milliseconds: percentile(latency, .95), maxMilliseconds: percentile(latency, 1), rssKB: await memory() };
    checkpoints.push(checkpoint); console.log(JSON.stringify(checkpoint));
  };
  bridge.onApproval = message => {
    const waiting = pending.get(message.terminalID);
    try {
      if (!waiting || actionIDs.has(message.id)) { duplicateInputs++; throw Error('Unexpected duplicate approval input'); }
      if (message.dialog !== waiting.screen || message.answer !== '1' || message.agent !== 'codex'
          || message.generation !== 'stress-same-process') { wrongInputs++; throw Error('Approval content or target differs'); }
      actionIDs.add(message.id);
      latency.push(performance.now() - waiting.started);
      completed++;
      pending.delete(message.terminalID);
      clearTimeout(waiting.timer);
      waiting.resolve();
    } catch (error) {
      failure = error;
      for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); }
      pending.clear();
    }
  };
  const makeScreen = (lane, index) => {
    const command = `rg -n 'fixture-${lane}-${index}|error|warn' .cache/product-evaluation/server-clean.log`;
    return 'Would you like to run the following command?\n\nEnvironment: local\n\n$ ' + command
      + "\n\n› 1. Yes, proceed (y)\n  2. Yes, and don't ask again for commands that start with `" + command
      + '` (p)\n  3. No, and tell Codex what to do differently (esc)\n\nPress enter to confirm or esc to cancel';
  };
  const show = (terminalID, screen) => bridge.request('screen', { terminalID, screen, generation: 'stress-same-process' });
  const result = () => ({ binary, perTerminal: count, terminals: fixtures.length, expectedTotal, completed,
    missing: expectedTotal - completed, duplicateInputs, wrongInputs, timeouts, repeatedFrames,
    durationSeconds: Math.round((performance.now() - start) / 100) / 10,
    p50Milliseconds: percentile(latency, .5), p95Milliseconds: percentile(latency, .95),
    p99Milliseconds: percentile(latency, .99), maxMilliseconds: percentile(latency, 1),
    initialRSSKB, checkpoints, scope: 'isolated real PTYs, production engine, mock VS Code bridge; no Terminal.app input' });
  try {
    await bridge.request('register', { terminals: fixtures });
    for (const session of sessions) await bridge.request('automatic', { sessionID: session.id, enabled: true });
    console.log(JSON.stringify({ stage: 'start', perTerminal: count, terminals: fixtures.length, expectedTotal, initialRSSKB }));
    const workers = await Promise.allSettled(fixtures.map(async (fixture, lane) => {
      for (let index = 1; index <= count; index++) {
        if (failure) throw failure;
        const screen = makeScreen(lane, index);
        const approval = new Promise((resolve, reject) => {
          const timer = setTimeout(() => { timeouts++; failure = Error(`No approval for terminal ${lane}, request ${index}`); reject(failure); }, 12000);
          pending.set(fixture.id, { screen, started: performance.now(), resolve, reject, timer });
        });
        await Promise.all([show(fixture.id, screen), approval]);
        if (index % 10 === 0) {
          await show(fixture.id, screen); repeatedFrames++;
          const wrapped = 'Older output\n' + screen.replaceAll('product-evaluation', 'product-\n    evaluation').replace(' (p)', ' (a)');
          await show(fixture.id, wrapped); repeatedFrames++;
        }
        if (lane === 0 && milestones.has(index)) await record(`terminal-0:${index}`);
      }
    }));
    const failed = workers.find(worker => worker.status === 'rejected');
    if (failed) throw failed.reason;
    if (failure) throw failure;
    assert.equal(completed, expectedTotal); assert.equal(actions.length, expectedTotal);
    assert.equal(actionIDs.size, expectedTotal);
    for (const fixture of fixtures) await show(fixture.id, 'Working (esc to interrupt)');

    // Persisted history must include every request, even though snapshots show only the latest 200.
    const database = path.join(home, 'state.sqlite');
    let audit;
    for (let attempt = 0; attempt < 20; attempt++) {
      audit = JSON.parse((await exec('/usr/bin/sqlite3', ['-readonly', '-json', database,
        "SELECT COUNT(*) AS total, COUNT(DISTINCT json_extract(json, '$.request')) AS distinctRequests, SUM(json_extract(json, '$.outcome') = '승인 입력 전달') AS delivered FROM events;"])).stdout)[0];
      if (audit.delivered === expectedTotal) break;
      await sleep(100);
    }
    assert.equal(audit.total, expectedTotal); assert.equal(audit.distinctRequests, expectedTotal); assert.equal(audit.delivered, expectedTotal);
    await record('complete');
    // Allow the engine's 8-second delivery observers to drain before the last memory sample.
    await sleep(9000);
    await record('after-observers');
    const report = { passed: true, ...result(), audit };
    if (reportPath) await writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
    console.log('PASS approval stress ' + JSON.stringify(report));
  } catch (error) {
    const report = { passed: false, ...result(), error: error.message };
    if (reportPath) await writeFile(reportPath, JSON.stringify(report, null, 2) + '\n');
    console.error('FAIL approval stress ' + JSON.stringify(report));
    throw error;
  } finally {
    bridge.onApproval = undefined;
    for (const request of pending.values()) clearTimeout(request.timer);
  }
}
