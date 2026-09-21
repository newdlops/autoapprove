// Installed CLI transport check. Uses a temporary CODEX_HOME, an inert synthetic
// rollout and no model turn. Never connects to or submits to a user's session.
import { mkdtemp, writeFile, mkdir, rm } from 'node:fs/promises';
import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

const root = await mkdtemp('/private/tmp/aa-codex-queue-');
const environment = { ...process.env, CODEX_HOME: root };
const thread = randomUUID(), now = new Date().toISOString();
const message = '> Fixture question?\n> Continued question\n\nA\nB; literal $(not-executed) `unchanged` "quote"';
let server, buffer = '', counter = 0;
const pending = new Map();
function request(method, params) {
  return new Promise((resolve, reject) => {
    const id = ++counter;
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timed out: ${method}`)); }, 5000);
    pending.set(id, value => { clearTimeout(timer); value.error ? reject(Error(JSON.stringify(value.error))) : resolve(value.result); });
    server.stdin.write(JSON.stringify({ id, method, params }) + '\n');
  });
}
try {
  await writeFile(root + '/config.toml', '');
  const day = root + '/sessions/' + now.slice(0, 10).replaceAll('-', '/');
  await mkdir(day, { recursive: true });
  await writeFile(`${day}/rollout-${now.slice(0, 19).replaceAll(':', '-')}-${thread}.jsonl`, JSON.stringify({
    timestamp: now, type: 'session_meta', payload: { id: thread, timestamp: now, cwd: root, originator: 'codex-tui',
      cli_version: '0.155.1', source: 'cli', model_provider: 'openai', base_instructions: { text: 'Isolated transport fixture. No model turns.' } }
  }) + '\n');
  const result = spawnSync('codex', ['queue', '--thread', thread, '--message', message], { env: environment, encoding: 'utf8', timeout: 8000 });
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  const receipt = /^Queued message ([0-9a-f-]+) for thread ([0-9a-f-]+)\.\s*$/.exec(result.stdout);
  assert.equal(receipt?.[2], thread);
  server = spawn('codex', ['app-server'], { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  server.stderr.resume();
  server.stdout.on('data', chunk => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      const value = JSON.parse(line); pending.get(value.id)?.(value); pending.delete(value.id);
    }
  });
  await request('initialize', { clientInfo: { name: 'autoapprove-queue-check', version: '1.0' }, capabilities: { experimentalApi: true } });
  server.stdin.write(JSON.stringify({ method: 'initialized' }) + '\n');
  const queued = await request('thread/queue/list', { threadId: thread });
  assert.equal(queued.data.length, 1);
  assert.equal(queued.data[0].id, receipt[1]);
  assert.deepEqual(queued.data[0].input.map(input => input.text), [message]);
  console.log('PASS installed Codex CLI queues exact multiline reply to the requested isolated thread; shell literals remain text');
} finally {
  if (server) {
    const stopped = new Promise(resolve => server.once('exit', resolve));
    server.stdin.end(); server.kill(); await stopped;
  }
  await rm(root, { recursive: true, force: true });
}
