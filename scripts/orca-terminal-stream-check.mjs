// Real source against private mock Orca Unix transports; never calls Orca/user CLI.
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtemp, mkdir, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import path from 'node:path';
import { coreLinkArguments } from './swift-core-link.mjs';

const temporary = await mkdtemp('/private/tmp/autoapprove-orca-');
const binary = path.join(temporary, 'OrcaTerminalStreamCheck');
const servers = [], sockets = new Set(), checks = [];
const ansi = '\x1b[?25l\x1b[38;2;255;0;0mRED 한글\x1b[0m\x1b[2;4H';
const ptyID = 'workspace@@pty-original', handle = 'terminal-exact';
try {
  const cache = '/private/tmp/autoapprove-orca-module-cache'; await mkdir(cache, { recursive: true });
  if (process.argv.includes('--baseline')) {
    const build = path.resolve('.build', process.argv.includes('--release') ? 'release' : 'debug');
    const objects = (await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name));
    execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-D', 'ORCA_STREAM_BASELINE', '-module-cache-path', cache,
      '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
      ...objects, 'Tests/fixtures/orca-terminal-stream.swift', '-o', binary], { stdio: 'inherit' });
    execFileSync(binary, [], { stdio: 'inherit' });
  } else {
    execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', cache,
      'Sources/AutoApproveCore/OrcaTerminalStream.swift', 'Tests/fixtures/orca-terminal-stream.swift', '-o', binary], { stdio: 'inherit' });
    async function server(endpoint, receive) {
      const value = createServer(socket => {
        sockets.add(socket); socket.once('close', () => sockets.delete(socket)); socket.on('error', () => {});
        let buffer = ''; socket.setEncoding('utf8'); socket.on('data', data => {
          buffer += data;
          while (buffer.includes('\n')) { const end = buffer.indexOf('\n'), line = buffer.slice(0, end); buffer = buffer.slice(end + 1); if (line) receive(JSON.parse(line), socket); }
        });
      });
      servers.push(value); await new Promise((resolve, reject) => { value.once('error', reject); value.listen(endpoint, resolve); });
      return value;
    }
    function reply(socket, value, fragmented = false) {
      const data = Buffer.from(JSON.stringify(value) + '\n');
      if (!fragmented) { socket.write(data); return; }
      // Split even inside a multibyte code point; a line is decoded only when complete.
      let offset = 0; const timer = setInterval(() => {
        if (socket.destroyed || offset >= data.length) { clearInterval(timer); return; }
        socket.write(data.subarray(offset, offset + 17)); offset += 17;
      }, 1); timer.unref();
    }
    async function fixture(name, options = {}) {
      const directory = path.join(temporary, name); await mkdir(directory); await mkdir(path.join(directory, 'daemon'));
      const endpoint = path.join(directory, 'runtime.sock');
      await writeFile(path.join(directory, 'orca-runtime.json'), JSON.stringify({ runtimeId: 'runtime-one', pid: 111111,
        transports: [{ kind: 'unix', endpoint }], authToken: 'private-fixture-runtime-token' }));
      let shows = 0, lists = 0, daemonConnections = 0;
      const requests = [], disconnected = new Set();
      await server(endpoint, (request, socket) => {
        requests.push(request.method); assert.equal(request.authToken, 'private-fixture-runtime-token');
        assert.equal(request.method, 'terminal.show'); assert.deepEqual(request.params, { terminal: handle }); shows++;
        if (options.runtimeStall) { socket.write('{'); return; }
        const terminal = { handle, ptyId: options.changedTarget && shows > 1 ? 'workspace@@other' : ptyID,
          connected: !options.ended, title: 'Fixture', leafId: 'leaf-one', tabId: 'tab-one', rendererGraphEpoch: 7 };
        reply(socket, { id: options.wrongID ? 'wrong-id' : request.id, ok: true, result: { terminal },
          _meta: { runtimeId: options.runtimeChanged && shows > 1 ? 'runtime-two' : 'runtime-one' } }, options.fragmented);
      });
      const daemonIdentity = { pid: 222222, startedAtMs: 123456000, launchNonce: 'fixture-daemon-generation', entryPath: '/private/mock/daemon-entry.js' };
      await writeFile(path.join(directory, 'daemon', 'daemon-v36.token'), 'private-fixture-daemon-token\n');
      await writeFile(path.join(directory, 'daemon', 'daemon-v36.pid'), JSON.stringify(daemonIdentity));
      await server(path.join(directory, 'daemon', 'daemon-v36.sock'), (request, socket) => {
        requests.push(request.type);
        if (request.type === 'hello') {
          assert.equal(request.role, 'control'); assert.equal(request.version, 36);
          assert.equal(request.token, 'private-fixture-daemon-token'); assert.ok(request.clientId);
          const connection = ++daemonConnections; socket.fixtureConnection = connection;
          socket.once('close', () => disconnected.add(connection));
          reply(socket, { type: 'hello', ok: true, daemonIdentity: options.badDaemonIdentity ? { ...daemonIdentity, launchNonce: 'wrong-generation' } : daemonIdentity }); return;
        }
        assert.ok(['listSessions', 'getSnapshot'].includes(request.type), 'Only read operations are allowed');
        if (request.type === 'listSessions') {
          lists++;
          const session = { sessionId: ptyID, incarnationId: options.changedIncarnation && lists > 1 ? 'incarnation-two' : 'incarnation-one',
            terminalHandle: options.wrongHandle ? 'different-terminal' : handle, isAlive: true,
            pid: options.invalidOwnerPID ? 2147483648 : options.changedOwnerPID && lists > 1 ? 333334 : 333333,
            cols: 80, rows: 24, state: 'running', shellState: 'ready', cwd: '/private/mock', createdAt: 0, agentSessionOwners: [] };
          reply(socket, { id: request.id, ok: true, payload: { sessions: options.noSession ? [] : [session] } }); return;
        }
        assert.deepEqual(request.payload, { sessionId: ptyID, scrollbackRows: 0 });
        if (options.stall || (options.stallFirst && socket.fixtureConnection === 1)) { socket.write('{'); return; }
        if (options.oversized) { socket.write('x'.repeat(4 * 1024 * 1024 + 100)); return; }
        const snapshot = options.deadSnapshot ? null : { snapshotAnsi: ansi.slice(6), rehydrateSequences: '\x1b[?25l', scrollbackAnsi: '',
          cols: 80, rows: 24, modes: { alternateScreen: false, cursorHidden: true, cursorStyle: 'bar' }, outputSequence: 712,
          cwd: '/private/mock', oscLinks: [], scrollbackLines: 0 };
        reply(socket, { id: request.id, ok: true, payload: { snapshot } }, options.fragmented);
      });
      if (options.staleCandidates) {
        for (const version of [32, 35]) {
          // Orca publishes a separate socket name; closing its bind path can
          // leave that published inode after PID/token cleanup on an upgrade.
          const bind = path.join(directory, 'daemon', `old-bind-${version}.sock`);
          const old = await server(bind, () => {});
          await rename(bind, path.join(directory, 'daemon', `daemon-v${version}.sock`));
          await new Promise(resolve => old.close(resolve));
          if (['refused', 'missing-pid'].includes(options.staleCandidates)) {
            await writeFile(path.join(directory, 'daemon', `daemon-v${version}.token`), 'obsolete-fixture-token');
          }
          if (['refused', 'missing-token'].includes(options.staleCandidates)) {
            await writeFile(path.join(directory, 'daemon', `daemon-v${version}.pid`), JSON.stringify(daemonIdentity));
          }
        }
      }
      if (options.liveDuplicate || options.badLegacyIdentity) {
        await writeFile(path.join(directory, 'daemon', 'daemon-v35.token'), 'private-legacy-fixture-token');
        await writeFile(path.join(directory, 'daemon', 'daemon-v35.pid'), JSON.stringify(daemonIdentity));
        await server(path.join(directory, 'daemon', 'daemon-v35.sock'), (request, socket) => {
          if (request.type === 'hello') {
            assert.equal(request.role, 'control'); assert.equal(request.version, 35);
            assert.equal(request.token, 'private-legacy-fixture-token');
            reply(socket, { type: 'hello', ok: true, daemonIdentity: options.badLegacyIdentity ? { ...daemonIdentity, launchNonce: 'wrong-legacy-generation' } : daemonIdentity });
          } else {
            assert.equal(request.type, 'listSessions');
            reply(socket, { id: request.id, ok: true, payload: { sessions: [{ sessionId: ptyID, incarnationId: 'legacy-incarnation', terminalHandle: handle, isAlive: true, pid: 444444 }] } });
          }
        });
      }
      return { directory, requests, disconnected };
    }
    function run(directory, mode = 'snapshot') {
      return new Promise((resolve, reject) => {
        const child = spawn(binary, [directory, mode], { stdio: ['ignore', 'pipe', 'pipe'] });
        let stdout = '', stderr = ''; child.stdout.on('data', data => stdout += data); child.stderr.on('data', data => stderr += data);
        const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('Mock source test exceeded 8s')); }, 8000);
        child.once('error', reject); child.once('exit', code => { clearTimeout(timer); if (code) reject(new Error(stderr)); else try { resolve(JSON.parse(stdout)); } catch { reject(new Error(stdout + stderr)); } });
      });
    }
    const exact = await fixture('exact', { fragmented: true }); let value = await run(exact.directory);
    assert.equal(value.status, 'ok'); assert.equal(value.ansi, ansi); assert.equal(value.columns, 80); assert.equal(value.rows, 24);
    assert.equal(value.sequence, 712); assert.equal(value.runtimeID, 'runtime-one'); assert.equal(value.ptyID, ptyID);
    assert.equal(value.incarnationID, 'incarnation-one'); assert.equal(value.ownerPID, 333333);
    assert.equal(value.alternateScreen, false); assert.ok(Math.abs(value.observedAt * 1000 - Date.now()) < 2000);
    assert.deepEqual(exact.requests, ['terminal.show', 'hello', 'listSessions', 'getSnapshot', 'listSessions', 'terminal.show']);
    checks.push('Current RGB/UTF-8/cursor ANSI survives fragmented frames with original geometry and exact identity');
    for (const [name, options] of Object.entries({ target: { changedTarget: true }, incarnation: { changedIncarnation: true }, runtime: { runtimeChanged: true }, handle: { wrongHandle: true }, response: { wrongID: true }, daemon: { badDaemonIdentity: true }, ended: { ended: true }, dead: { deadSnapshot: true }, absent: { noSession: true }, owner: { invalidOwnerPID: true }, 'owner-swap': { changedOwnerPID: true } })) {
      const item = await fixture(name, options); value = await run(item.directory); assert.equal(value.status, 'error', name);
      if (name === 'ended') assert.deepEqual(item.requests, ['terminal.show']);
    }
    checks.push('Target/runtime/daemon/incarnation/owner swaps, out-of-range owner PIDs, wrong handles/response IDs and ended sessions fail closed');
    for (const staleCandidates of ['missing-files', 'missing-pid', 'missing-token', 'refused']) {
      const item = await fixture('stale-' + staleCandidates, { staleCandidates }); value = await run(item.directory);
      assert.equal(value.status, 'ok', 'Obsolete version artifacts must not disable a healthy exact v36 source');
      assert.equal(value.ansi, ansi);
    }
    checks.push('Healthy v36 source survives normal legacy v32/v35 socket artifacts with missing files or refused connections');
    for (const [name, options] of [['duplicate-live', { liveDuplicate: true }], ['legacy-identity', { badLegacyIdentity: true }]]) {
      const item = await fixture(name, options); assert.equal((await run(item.directory)).status, 'error');
    }
    checks.push('A healthy v36 source still rejects authenticated legacy identity mismatch or duplicate live exact PTYs');
    const huge = await fixture('huge', { oversized: true }); assert.equal((await run(huge.directory)).status, 'error');
    checks.push('Oversized daemon responses are bounded before JSON decode');
    for (const options of [{ stall: true }, { runtimeStall: true }]) {
      const item = await fixture(options.stall ? 'deadline-daemon' : 'deadline-runtime', options), start = Date.now();
      assert.equal((await run(item.directory, 'deadline')).status, 'timeout'); assert.ok(Date.now() - start < 900);
    }
    checks.push('One total deadline bounds runtime lookup and partial daemon frames');
    for (const mode of ['cancel', 'admission']) {
      const item = await fixture(mode, { stallFirst: true }); value = await run(item.directory, mode);
      assert.equal(value.status, 'ok'); assert.equal(value.ansi, ansi); assert.ok(value.cancelElapsed < 0.6);
      await new Promise(resolve => setTimeout(resolve, 30)); assert.ok(item.disconnected.has(1));
    }
    checks.push('Cancellation closes held sockets promptly and capacity is available for the next read');
    console.log(JSON.stringify({ checks, actualAppCalls: 0, createdPTYs: 0 }, null, 2));
  }
} finally {
  for (const socket of sockets) socket.destroy();
  await Promise.all(servers.map(server => new Promise(resolve => server.close(resolve))));
  await rm(temporary, { recursive: true, force: true });
}
