import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, readdir, rm, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';

const option = (name, fallback) => process.argv.find(v => v.startsWith('--' + name + '='))?.slice(name.length + 3) ?? fallback;
const label = option('label', 'current'); assert.match(label, /^[a-z0-9-]+$/);
const output = path.resolve('.runtime/screen-match-engine-check', label), build = path.resolve(option('build', '.build/release'));
const fixture = 'Tests/fixtures/screen-match-engine-check.swift', binary = path.join(output, 'check');
const sha = value => createHash('sha256').update(value).digest('hex');
await mkdir(output, {recursive: true, mode: 0o700});
let provenance;
if (process.argv.includes('--reuse-binary')) {
  provenance = JSON.parse(await readFile(path.join(output, 'provenance.json'), 'utf8'));
  assert.equal(provenance.fixtureSHA256, sha(await readFile(fixture)));
  assert.equal(provenance.binarySHA256, sha(await readFile(binary)));
} else {
  const names = (await readdir(build + '/AutoApproveCore.build')).filter(n => n.endsWith('.swift.o')).sort();
  const objects = Object.fromEntries(await Promise.all(names.map(async n => [n, sha(await readFile(build + '/AutoApproveCore.build/' + n))])));
  const cache = path.resolve('.build/cache/ScreenMatchEngineCheck'); await mkdir(cache, {recursive: true});
  execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', cache,
    '-I', build + '/Modules', '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
    ...names.map(n => build + '/AutoApproveCore.build/' + n), fixture, '-o', binary], {stdio: 'inherit', timeout: 120000});
  provenance = {fixtureSHA256: sha(await readFile(fixture)), binarySHA256: sha(await readFile(binary)),
    coreObjects: objects, coreFingerprint: sha(JSON.stringify(objects)), coreModuleSHA256: sha(await readFile(build + '/Modules/AutoApproveCore.swiftmodule'))};
  await writeFile(path.join(output, 'provenance.json'), JSON.stringify(provenance, null, 2) + '\n', {mode: 0o600});
}
const directory = await mkdtemp('/private/tmp/aa-screen-match-');
try {
  const args = process.argv.includes('--body-change') ? [directory, '--body-change'] : [directory];
  const value = JSON.parse(execFileSync(binary, args, {encoding: 'utf8', timeout: 120000}));
  const report = {label, ...value, provenance};
  await writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n', {mode: 0o600});
  console.log(JSON.stringify({label, ...value, provenance: {...provenance, coreObjects: undefined}}));
} finally { await rm(directory, {recursive: true, force: true}); }
