import { coreLinkArguments } from './swift-core-link.mjs';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const option = name => process.argv.find(value => value.startsWith('--' + name + '='))?.slice(name.length + 3);
const label = option('label') || 'current', compare = option('compare');
assert.match(label, /^[a-z0-9-]+$/);
const build = path.resolve('.build/release'), output = path.resolve('.runtime/remote-frame-performance-check', label);
await mkdir(output, { recursive: true });
const binary = path.join(output, 'check');
execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/RemoteFramePerformanceCheck'),
  '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
  ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)),
  'Tests/fixtures/remote-frame-performance-check.swift', '-o', binary], { stdio: 'inherit' });
const reports = [];
for (let sample = 0; sample < 3; sample++) {
  const root = await mkdtemp('/private/tmp/aa-remote-frame-perf-');
  try { reports.push(JSON.parse(execFileSync(binary, [root], { encoding: 'utf8', timeout: 90000 }))); }
  finally { await rm(root, { recursive: true, force: true }); }
}
const median = values => values.sort((a, b) => a - b)[Math.floor(values.length / 2)];
const workloads = reports[0].workloads.map((workload, index) => ({ ...workload,
  cpuSeconds: median(reports.map(report => report.workloads[index].cpuSeconds)),
  wallSeconds: median(reports.map(report => report.workloads[index].wallSeconds)) }));
const result = { label, samples: reports.length, workloads,
  peakResidentBytes: median(reports.map(report => report.peakResidentBytes)), preserved: reports[0].preserved };
if (compare) {
  assert.match(compare, /^[a-z0-9-]+$/);
  const baseline = JSON.parse(await readFile(path.resolve('.runtime/remote-frame-performance-check', compare, 'report.json'), 'utf8'));
  result.comparison = workloads.map(workload => {
    const before = baseline.workloads.find(item => item.name === workload.name);
    assert.ok(before, 'Missing baseline workload ' + workload.name);
    return { name: workload.name, cpuReductionPercent: 100 * (1 - workload.cpuSeconds / before.cpuSeconds),
      wallReductionPercent: 100 * (1 - workload.wallSeconds / before.wallSeconds) };
  });
}
await writeFile(path.join(output, 'report.json'), JSON.stringify({ ...result, reports }, null, 2));
console.log(JSON.stringify(result, null, 2));
