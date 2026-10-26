// Exact persisted raw fingerprints, using released source as the independent oracle.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {spawn, execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const out = path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT || fs.mkdtempSync(path.join(os.tmpdir(), 'aa-fingerprint-check-')));
fs.mkdirSync(out, {recursive: true, mode: 0o700});
const sourceFile = 'Sources/AutoApproveCore/ApprovalPrompt.swift', fixture = 'Tests/fixtures/fingerprint-preparation-check.swift';
const sha = data => createHash('sha256').update(data).digest('hex');
const baseline = execFileSync('git', ['-c', 'core.fsmonitor=false', 'show', 'v0.2.168:' + sourceFile], {encoding: 'utf8'});
const candidate = fs.readFileSync(sourceFile, 'utf8');
function section(source) {
    const start = source.indexOf('    private static let hexDigits'), end = source.indexOf('    /// Matches complete', start);
    assert.ok(start > 0 && end > start);
    return source.slice(start, end);
}
const generated = 'import Foundation\nimport CryptoKit\nenum BaselineFingerprint {\n' + section(baseline) + '}\nenum CandidateFingerprint {\n' + section(candidate) + '}\n' + fs.readFileSync(fixture, 'utf8');
fs.writeFileSync(out + '/probe.swift', generated, {flag: 'wx', mode: 0o600});
const proof = {baselineTag: 'v0.2.168', originalPromptSHA256: sha(baseline), candidatePromptSHA256: sha(candidate), candidateFingerprintSectionSHA256: sha(section(candidate)), fixtureSHA256: sha(fs.readFileSync(fixture)), generatedSHA256: sha(generated)};
fs.writeFileSync(out + '/inputs.json', JSON.stringify(proof, null, 2) + '\n', {flag: 'wx', mode: 0o600});
async function run(command, args, name) {
    const fd = fs.openSync(out + '/' + name + '.log', 'wx', 0o600), start = performance.now();
    const child = spawn(command, args, {stdio: ['ignore', fd, fd]});
    fs.writeFileSync(out + '/' + name + '-started.json', JSON.stringify({pid: child.pid, at: new Date().toISOString()}) + '\n', {flag: 'wx', mode: 0o600});
    const result = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', (code, signal) => resolve({code, signal})); });
    fs.closeSync(fd);
    fs.writeFileSync(out + '/' + name + '-job.json', JSON.stringify({...result, seconds: (performance.now() - start) / 1000}) + '\n', {flag: 'wx', mode: 0o600});
    assert.equal(result.code, 0, fs.readFileSync(out + '/' + name + '.log', 'utf8').slice(-4000));
    return fs.readFileSync(out + '/' + name + '.log', 'utf8');
}
const cache = path.resolve(process.env.AUTOAPPROVE_QA_MODULE_CACHE || out + '/module-cache');
await run('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', cache, out + '/probe.swift', '-o', out + '/probe'], 'compile');
const result = JSON.parse((await run(out + '/probe', [], 'check')).trim());
assert.equal(result.matched, true); assert.equal(result.cases, 846); assert.equal(result.foreignCases, 407);
assert.equal(result.digest, 'c5eb762a7b5ad5b387896a4fcfc7c9d484ed93e63b66defe78284b97fae34191');
assert.equal(sha(fs.readFileSync(sourceFile)), proof.candidatePromptSHA256); assert.equal(sha(fs.readFileSync(fixture)), proof.fixtureSHA256);
fs.writeFileSync(out + '/result.json', JSON.stringify({...result, binarySHA256: sha(fs.readFileSync(out + '/probe'))}, null, 2) + '\n', {flag: 'wx', mode: 0o600});
console.log(JSON.stringify({matched: true, cases: result.cases, foreignCases: result.foreignCases, digest: result.digest, out,
    scope: 'Actual fingerprint source only. Engine CPU/wall/RSS, approval policy, input receipts and release checks require separate verification.'}));
