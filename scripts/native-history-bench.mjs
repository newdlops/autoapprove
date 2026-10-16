import { coreLinkArguments } from './swift-core-link.mjs';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const argument = (name, fallback) => process.argv.find(value => value.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const label = argument('label', 'current'); assert.match(label, /^[a-z0-9-]+$/);
const gated = process.argv.includes('--gate');
const build = path.resolve('.build/release'), output = path.resolve('.runtime/native-history-bench', label);
const app = path.join(output, 'NativeHistoryBench.app'), binary = path.join(app, 'Contents/MacOS/NativeHistoryBench');
await mkdir(path.dirname(binary), { recursive: true, mode: 0o700 });
// Compile the actual production disclosure, including its own state and layout.
// Adjacent session controls have no role in this isolated rendering workload.
const source = await readFile(argument('source', 'Sources/AutoApproveApp/SessionWindow.swift'), 'utf8');
const start = source.indexOf('struct ApprovalEventDisclosure: View {'), end = source.indexOf('\nstruct CodexQuestionList:', start);
assert.ok(start >= 0 && end > start);
const component = path.join(output, 'ApprovalEventDisclosure.swift');
await writeFile(component, 'import SwiftUI\nimport AutoApproveCore\n' + source.slice(start, end));
execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/NativeHistoryBench'),
  ...(gated ? ['-D', 'NATIVE_HISTORY_GATE'] : []),
  '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
  ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)),
  'Sources/AutoApproveApp/AppHelp.swift', 'Sources/AutoApproveApp/WindowViewUpdates.swift', component, 'Tests/fixtures/native-history-bench.swift', '-o', binary], { stdio: 'inherit' });
await writeFile(path.join(app, 'Contents/Info.plist'), `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autoapprove.native-history-bench.${label}</string>
<key>CFBundleExecutable</key><string>NativeHistoryBench</string><key>CFBundleName</key><string>NativeHistoryBench</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/></dict></plist>`);
execFileSync('/usr/bin/codesign', ['--force', '--sign', '-', app], { stdio: 'inherit' });
if (process.argv.includes('--package-only')) { console.log(app); process.exit(0); }
const reports = [];
for (let trial = 0; trial < 3; trial++) {
  const report = path.join(output, `trial-${trial}.json`);
  execFileSync(binary, ['--measure', `--report=${report}`], { encoding: 'utf8', timeout: 45000 });
  reports.push(JSON.parse(await readFile(report, 'utf8')));
}
const median = values => values.sort((a, b) => a - b)[Math.floor(values.length / 2)];
assert.ok(reports.every(report => report.latestOnReveal), 'Showing the window must immediately reflect updates received while hidden');
assert.ok(reports.every(report => report.continuesAfterReveal && report.latestAfterMinimize && report.latestAfterAppHide),
  'Visible updates and restoration after minimizing/hiding the app must remain live');
if (gated) assert.ok(reports.every(report => report.phases[1].renders <= 1), 'Hidden model updates must not redraw the window');
const result = { result: 'PASS', label, gated, trials: reports.length, events: 40, latestOnReveal: true,
  phases: reports[0].phases.map((phase, index) => ({ ...phase,
    cpuSeconds: median(reports.map(report => report.phases[index].cpuSeconds)),
    wallSeconds: median(reports.map(report => report.phases[index].wallSeconds)) })),
  peakResidentBytes: median(reports.map(report => report.peakResidentBytes)), reports };
await writeFile(path.join(output, 'report.json'), JSON.stringify(result, null, 2));
const { reports: raw, ...summary } = result; console.log(JSON.stringify(summary, null, 2));
