// Native 0.166 protocol evidence, not a user-session migration test.
// Requires an explicit CLI; fresh anonymous home and loopback inference only.
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {mkdtemp, mkdir, writeFile, rm, stat} from 'node:fs/promises';
import {createServer} from 'node:http';
import path from 'node:path';
import {coreLinkArguments, coreSwiftObjects} from './swift-core-link.mjs';

const opt = name => process.argv.find(v => v.startsWith('--' + name + '='))?.slice(name.length + 3);
const cli = opt('codex');
assert.ok(cli && path.isAbsolute(cli), 'Provide --codex=/absolute/path/to/codex');
const build = path.resolve(opt('build') || '.build/debug');
const output = path.resolve(opt('output') || '.runtime/codex-client-ownership');
await mkdir(output, {recursive: true});
const root = await mkdtemp('/private/tmp/aa-owner-');
const home = root + '/h', socket = home + '/app-server-control/app-server-control.sock';
const env = {HOME: home, CODEX_HOME: home, PATH: '/usr/bin:/bin'};
const delay = ms => new Promise(r => setTimeout(r, ms));
let server, child, requests = 0;
const provider = createServer(async (req, res) => {
  for await (const _ of req) {}
  if (req.url !== '/v1/responses') { res.writeHead(404); res.end(); return; }
  requests++;
  const id = 'fixture-' + requests;
  const item = {id: 'message-' + id, type: 'message', role: 'assistant', status: 'completed',
    content: [{type: 'output_text', text: 'Owned synthetic ownership context.', annotations: []}]};
  res.writeHead(200, {'Content-Type': 'text/event-stream', Connection: 'close'});
  for (const value of [{type: 'response.created', response: {id, status: 'in_progress', output: []}},
    {type: 'response.output_item.added', output_index: 0, item},
    {type: 'response.output_item.done', output_index: 0, item},
    {type: 'response.completed', response: {id, status: 'completed', output: [item],
      usage: {input_tokens: 1, output_tokens: 1, total_tokens: 2}}}]) {
    res.write('data: ' + JSON.stringify(value) + '\n\n');
  }
  res.end();
});
async function stop(process) {
  if (!process || process.exitCode !== null || process.signalCode !== null) return;
  try { globalThis.process.kill(-process.pid, 'SIGTERM'); } catch {}
  const end = Date.now() + 3000;
  while (process.exitCode === null && process.signalCode === null && Date.now() < end) await delay(50);
  if (process.exitCode === null && process.signalCode === null) {
    const exited = new Promise(resolve => process.once('exit', resolve));
    try { globalThis.process.kill(-process.pid, 'SIGKILL'); } catch {}
    await exited;
  }
}
try {
  await mkdir(home + '/app-server-control', {recursive: true, mode: 0o700});
  const version = execFileSync(cli, ['--version'], {cwd: root, env, encoding: 'utf8', timeout: 10000}).trim();
  assert.equal(version, 'codex-cli 0.166.0', 'Native proof is pinned to 0.166.0');
  const binary = root + '/check';
  execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path',
    path.resolve('.build/cache/ClientOwnershipCheck'), '-I', build + '/Modules', '-I',
    path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
    ...await coreSwiftObjects(build), 'Tests/fixtures/codex-client-ownership.swift', '-o', binary],
  {stdio: 'inherit', timeout: 180000});
  await new Promise((resolve, reject) => { provider.once('error', reject); provider.listen(0, '127.0.0.1', resolve); });
  const port = provider.address().port;
  await writeFile(home + '/config.toml', `model="fixture-model"\nmodel_provider="fixture"\ncli_auth_credentials_store="file"\nchatgpt_base_url="http://127.0.0.1:${port}"\ncheck_for_update_on_startup=false\n[features]\napps=false\nplugins=false\n[model_providers.fixture]\nname="Fixture"\nbase_url="http://127.0.0.1:${port}/v1"\nwire_api="responses"\nrequires_openai_auth=false\nsupports_websockets=false\n`, {mode: 0o600});
  server = spawn(cli, ['app-server', '--listen', 'unix://' + socket], {cwd: root, env, stdio: 'ignore', detached: true});
  const readyDeadline = Date.now() + 15000;
  let ready = false;
  while (Date.now() < readyDeadline && server.exitCode === null && server.signalCode === null) {
    try { ready = (await stat(socket)).isSocket(); if (ready) break; } catch {}
    await delay(50);
  }
  assert.ok(ready, 'Owned Unix server failed to start');
  child = spawn(binary, [home, String(server.pid)], {cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'], detached: true});
  let stdout = '', stderr = '';
  child.stdout.on('data', b => stdout += b);
  child.stderr.on('data', b => stderr += b);
  const timer = setTimeout(() => { void stop(child); }, 60000);
  let code;
  try { code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); }); }
  finally { clearTimeout(timer); }
  assert.equal(code, 0, stderr);
  const report = {...JSON.parse(stdout), cliVersion: version, providerRequests: requests};
  assert.equal(report.verified, true);
  assert.equal(report.sideForkEphemeral, true);
  assert.equal(report.sideForkParentMatchesRoot, false);
  assert.equal(report.sideForkSessionMatchesRoot, false);
  assert.equal(report.sideForkForkedFromMatchesRoot, true);
  assert.equal(requests, 1, 'Exactly one local synthetic inference required');
  await writeFile(output + '/report.json', JSON.stringify(report, null, 2) + '\n', {mode: 0o600});
  console.log(JSON.stringify(report));
} finally {
  await stop(child);
  await stop(server);
  provider.closeAllConnections();
  await new Promise(resolve => provider.close(resolve));
  await rm(root, {recursive: true, force: true});
}
