import { coreLinkArguments } from './swift-core-link.mjs';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const build = path.resolve('.build/release');
const label = process.argv.find(value => value.startsWith('--label='))?.slice(8) || 'current';
assert.match(label, /^[a-z0-9-]+$/);
const output = path.resolve('.runtime/polling-performance-check', label);
await mkdir(output, { recursive: true });
const binary = path.join(output, 'check');
if (!process.argv.includes('--reuse-binary')) {
  execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/PollingPerformanceCheck'),
    '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
    ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)),
    'Tests/fixtures/polling-performance-check.swift', '-o', binary], { stdio: 'inherit' });
}
const reports = [];
for (let sample = 0; sample < 3; sample++) {
  const directory = await mkdtemp('/private/tmp/aa-polling-perf-');
  try { reports.push(JSON.parse(execFileSync(binary, [directory], { encoding: 'utf8', timeout: 90000 }))); }
  finally { await rm(directory, { recursive: true, force: true }); }
}
const median = values => values.sort((a,b) => a-b)[Math.floor(values.length / 2)];
const workloads = reports[0].workloads.map((workload,index) => ({...workload,
  cpuSeconds: median(reports.map(report => report.workloads[index].cpuSeconds)),
  wallSeconds: median(reports.map(report => report.workloads[index].wallSeconds)),
  ...(workload.publications === undefined ? {} : {publications: median(reports.map(report => report.workloads[index].publications))})}));
const result = {result:'PASS',label,samples:reports.length,workloads,
  peakResidentBytes:median(reports.map(report => report.peakResidentBytes)),preserved:reports[0].preserved};
if (process.argv.includes('--assert-quiet')) {
  assert.ok(workloads[0].publications <= 2, `Unchanged screen polls caused ${workloads[0].publications} publications`);
  assert.ok(workloads[1].publications <= 50, `Changing screen polls caused ${workloads[1].publications} publications`);
}
const compare = process.argv.find(value => value.startsWith('--compare='))?.slice(10);
if (compare) {
  assert.match(compare,/^[a-z0-9-]+$/);
  const baseline=JSON.parse(await readFile(path.resolve('.runtime/polling-performance-check',compare,'report.json'),'utf8'));
  result.comparison = workloads.map((workload,index) => ({name:workload.name,
    cpuReductionPercent:100*(1-workload.cpuSeconds/baseline.workloads[index].cpuSeconds),
    wallReductionPercent:100*(1-workload.wallSeconds/baseline.workloads[index].wallSeconds)}));
}
await writeFile(path.join(output,'report.json'),JSON.stringify({...result,reports},null,2));
console.log(JSON.stringify(result,null,2));
