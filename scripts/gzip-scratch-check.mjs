import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { coreLinkArguments } from './swift-core-link.mjs';

// Build the matching release Core first. Supply --baseline-build and
// --baseline-source-root to compare against a preserved pre-change build.
const option = (name, fallback) => process.argv.find(value => value.startsWith('--' + name + '='))?.slice(name.length + 3) ?? fallback;
const sha = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fixture = path.resolve(option('fixture', 'Tests/fixtures/gzip-scratch-check.swift'));
const parent = path.resolve('.runtime/gzip-scratch-check');
fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
const out = fs.mkdtempSync(parent + '/run-');
const hashes = { [fixture]: sha(fixture), [import.meta.filename]: sha(import.meta.filename) };
const verify = () => { for (const [file, digest] of Object.entries(hashes)) assert.equal(sha(file), digest, file); };
const save = (name, value) => fs.writeFileSync(out + '/' + name, JSON.stringify(value, null, 2) + '\n', { flag: 'wx', mode: 0o600 });

// Only synthetic terminal-like events; no terminal access or captured output.
let seed = 0x19791025;
function entropy(length) {
  const bytes = Buffer.alloc(length);
  for (let index = 0; index < length; index++) {
    seed ^= seed << 13; seed ^= seed >>> 17; seed ^= seed << 5;
    bytes[index] = seed & 255;
  }
  return bytes;
}
const event = (name, body, id) => Buffer.from('event: ' + name + '\n' + (id ? 'id: ' + id + '\n' : '') + 'data: ' + JSON.stringify(body) + '\n\n');
const frame = (index, screen) => ({ sessionID: 'fixture/original', screen, revision: 'frame-' + index, streamID: 'fixture-stream-7d2d7fc5', sequence: index, observedAt: '2026-10-25T00:00:' + String(index % 60).padStart(2, '0') + 'Z', keys: ['characters', 'enter', 'backspace', 'escape', 'up', 'down', 'left', 'right'] });
const groups = [];
const add = (name, events) => groups.push({ name, events: [...events.map(bytes => ({ final: false, bytes })), { final: true, bytes: Buffer.alloc(0) }] });
add('empty', []);
add('idle-alive', [Buffer.alloc(0), ...Array.from({ length: 80 }, (_, index) => event('alive', { streamID: 'fixture-stream-7d2d7fc5', revision: 'stable-frame', sequence: index, observedAt: '2026-10-25T00:' + String(index / 60 | 0).padStart(2, '0') + ':' + String(index % 60).padStart(2, '0') + 'Z' }))]);
const code = 'Synthetic compiler output /fixture/main.swift:120 warning fixture\n'.repeat(240);
add('working-code', Array.from({ length: 16 }, (_, index) => event('screen', frame(index, code + '\n• Working ' + index + '\n›\n? for shortcuts'), 'frame-' + index)));
const ansi = '\u001b[32m원본 ANSI 색상🙂\u001b[0m /fixture/project e\u0301 · 한글\n'.repeat(1500);
add('unicode-ansi', Array.from({ length: 12 }, (_, index) => event('screen', frame(index, ansi + '\n› ' + index), 'frame-' + index)));
add('patch-updates', Array.from({ length: 64 }, (_, index) => event('screen', { ...frame(index, undefined), screenPatch: { baseRevision: 'frame-' + (index - 1), offset: 1200, removed: 3, text: '작업 ' + index + '\n' } }, 'frame-' + index)));
add('scroll-copy', Array.from({ length: 24 }, (_, index) => event('screen', { ...frame(index, undefined), screenCopy: { baseRevision: 'frame-' + (index - 1), start: 128, length: 8192, head: 'fixture header\n', tail: code.slice(0, 1200) + index } }, 'frame-' + index)));
add('questions-controls', Array.from({ length: 32 }, (_, index) => event('screen', { ...frame(index, 'Which fixture environment?\n› 1. Dev\n  2. Test\nEnter to select'), question: { question: '어느 검증 환경을 사용할까요?', options: ['개발', '검증', '배포 취소'], selected: index % 3 }, cursor: { offset: 33 }, inputReason: index % 2 ? 'Read-only fixture' : null }, 'frame-' + index)));
add('truecolor-runs', Array.from({ length: 16 }, (_, index) => event('screen', { ...frame(index, code.slice(0, 7000) + index), appearance: { runs: Array.from({ length: 96 }, (_, row) => ({ offset: row * 40, length: 20, foreground: '#' + ((row * 971 + index) % 0xffffff).toString(16).padStart(6, '0'), bold: row % 2 === 0 })) } }, 'frame-' + index)));
add('escaped-strings', Array.from({ length: 24 }, (_, index) => event('screen', frame(index, (Array.from({ length: 32 }, (_, value) => String.fromCharCode(value)).join('') + '\\\"/ e\u0301 🙂 \ud800\udfff\n').repeat(90) + index), 'frame-' + index)));
add('long-id-metadata', Array.from({ length: 32 }, (_, index) => event('alive', { streamID: 'fixture-' + 'a'.repeat(504), revision: 'revision-' + 'b'.repeat(503), sequence: index, observedAt: '2026-10-25T01:00:' + String(index).padStart(2, '0') + 'Z' })));
add('opaque-small', Array.from({ length: 128 }, () => entropy(257)));
add('opaque-window', Array.from({ length: 12 }, () => entropy(32768)));
add('opaque-large', [entropy(2_100_000)]);
add('repeated-large', [Buffer.alloc(2_100_000, 0x78)]);
add('all-byte-values', Array.from({ length: 8 }, () => Buffer.from(Array.from({ length: 65536 }, (_, index) => index & 255))));
const incremental = Buffer.from(ansi.slice(0, 11000)), chunks = [];
for (let offset = 0, index = 0; offset < incremental.length; index++) {
  const length = [1, 2, 3, 5, 8, 13, 21, 89, 521, 2048][index % 10];
  chunks.push(incremental.subarray(offset, Math.min(incremental.length, offset + length))); offset += length;
}
add('incremental-utf8', chunks);
const number = value => { const bytes = Buffer.alloc(4); bytes.writeUInt32LE(value); return bytes; };
const parts = [Buffer.from('AGZ1'), number(groups.length)];
for (const group of groups) {
  const name = Buffer.from(group.name); parts.push(number(name.length), name, number(group.events.length));
  for (const value of group.events) parts.push(number(value.final ? 1 : 0), number(value.bytes.length), value.bytes);
}
const corpus = out + '/corpus.bin'; fs.writeFileSync(corpus, Buffer.concat(parts), { flag: 'wx', mode: 0o600 });
assert.equal(sha(corpus), 'c0f2cd6ccc15789c03d8f6939536b5ae0bac4aa2629951895167d4144b3fa1d9');
hashes[corpus] = sha(corpus);

const variants = { candidate: { build: path.resolve(option('build', '.build/release')), source: path.resolve(option('source-root', '.')) } };
const baselineBuild = option('baseline-build');
if (baselineBuild) {
  assert.ok(option('baseline-source-root'), 'Supply the source matching --baseline-build');
  variants.baseline = { build: path.resolve(baselineBuild), source: path.resolve(option('baseline-source-root')) };
}
const cache = path.resolve(option('cache', out + '/module-cache'));
for (const [label, value] of Object.entries(variants)) {
  const objects = fs.readdirSync(value.build + '/AutoApproveCore.build').filter(name => name.endsWith('.swift.o')).sort().map(name => value.build + '/AutoApproveCore.build/' + name);
  assert.ok(objects.length > 0, 'Build the matching release Core first');
  const links = await coreLinkArguments(value.build);
  for (const file of [value.build + '/Modules/AutoApproveCore.swiftmodule', ...objects, ...links.filter(file => file.endsWith('.o')), ...['RemoteGzipEncoder.swift', 'RemoteGzipDecoder.swift'].map(file => value.source + '/Sources/AutoApproveCore/' + file)]) hashes[file] = sha(file);
  value.binary = out + '/' + label; value.coreObjects = objects.length; value.moduleSHA256 = sha(value.build + '/Modules/AutoApproveCore.swiftmodule');
  verify();
  execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', cache, '-I', value.build + '/Modules', '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', '-lz', ...links, ...objects, fixture, '-o', value.binary], { stdio: 'inherit', timeout: 300000 });
  hashes[value.binary] = sha(value.binary); verify();
}
const environment = { ...process.env }; delete environment.SWIFT_DETERMINISTIC_HASHING;
let runIndex = 0;
function run(label, args, input) {
  verify();
  const output = execFileSync(variants[label].binary, args, { input, encoding: 'utf8', env: environment, timeout: 120000, maxBuffer: 1048576 });
  verify();
  const name = label + '-' + args[0] + '-' + (++runIndex); save(name + '.json', output.trim().split('\n').map(JSON.parse));
  return output.trim().split('\n').map(JSON.parse);
}
const levels = [1, 2, 6, 9], byteChecks = [];
for (const level of levels) {
  const reference = variants.baseline ? out + '/baseline-level' + level + '.bin' : '-';
  if (variants.baseline) run('baseline', ['bytes', corpus, '-', reference, String(level)]);
  const target = out + '/candidate-level' + level + '.bin';
  // Use bounded log names, independent of output paths.
  verify();
  const args = ['bytes', corpus, reference, target, String(level)];
  const output = execFileSync(variants.candidate.binary, args, { encoding: 'utf8', env: environment, timeout: 120000, maxBuffer: 1048576 });
  verify(); const result = JSON.parse(output); assert.equal(result.passed, true); assert.equal(result.groups, 16); assert.equal(result.events, 527);
  if (variants.baseline) assert.equal(sha(target), sha(reference));
  byteChecks.push(result); save('candidate-level' + level + '.json', result);
}
const stacks = Object.fromEntries(Object.keys(variants).map(label => [label, run(label, ['stack'])[0]]));
const memory = {};
for (const label of Object.keys(variants)) {
  memory[label] = [];
  for (const level of [1, 6]) for (const count of [0, 1, 8, 32, 64]) {
    const row = run(label, ['memory', String(level), String(count)])[0];
    assert.equal(row.passed, true); assert.ok(row.afterReleaseGrowth <= 65536); memory[label].push(row);
  }
}
const savedHeap = [];
if (variants.baseline) for (let index = 0; index < memory.candidate.length; index++) {
  const before = memory.baseline[index], after = memory.candidate[index];
  assert.equal(before.level, after.level); assert.equal(before.count, after.count); assert.equal(before.encodedBytes, after.encodedBytes);
  const saved = before.retainedHeap - after.retainedHeap;
  if (after.count >= 8) assert.ok(saved >= after.count * 32000); else assert.ok(after.retainedHeap <= before.retainedHeap + 4096);
  savedHeap.push({ level: after.level, count: after.count, saved, savedPerStream: after.count ? saved / after.count : null });
}
const modes = ['heartbeat', 'metadata', 'ansi', 'patch', 'opaque32768', 'mixed'];
const requests = modes.map(mode => ({ id: 'public/' + mode, mode, iterations: 16 }));
const smokes = {};
for (const label of Object.keys(variants)) {
  const rows = run(label, ['bench'], requests.concat({ command: 'stop' }).map(value => JSON.stringify(value) + '\n').join(''));
  assert.equal(rows.shift().ready, true); assert.equal(rows.length, modes.length);
  smokes[label] = rows.map((row, index) => { assert.equal(row.mode, modes[index]); return { mode: row.mode, checksum: row.checksum, encodedBytes: row.encodedBytes }; });
}
if (variants.baseline) assert.deepEqual(smokes.candidate, smokes.baseline);
verify();
const report = { passed: true, actualCompiledCore: true, groups: 16, events: 2108, levels, baselineComparisonRun: !!variants.baseline, exactCompressedBytesPreserved: !!variants.baseline, byteChecks, stacks, memory, savedHeap, smokes, variants, inputs: hashes, memoryScope: 'Live malloc heap while encoder instances remain held after initial flush; not whole-app RSS.', noRuntimeSpeedClaim: true, originalTerminalActions: 0, realPowerCommands: 0 };
save('report.json', report);
console.log(JSON.stringify({ passed: true, groups: 16, events: 2108, baselineComparisonRun: !!variants.baseline, report: out + '/report.json' }));
