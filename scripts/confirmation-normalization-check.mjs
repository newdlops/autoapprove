import { coreLinkArguments } from './swift-core-link.mjs';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';

const option = name => process.argv.find(value => value.startsWith('--' + name + '='))?.slice(name.length + 3);
const baseline = option('baseline');
if (!baseline) throw new Error('Pass --baseline=path/to/original/YesNoConfirmation.swift');
const build = path.resolve('.build/release'), output = path.resolve('.runtime/confirmation-normalization-check');
await mkdir(output, { recursive: true, mode: 0o700 });
const source = await readFile('Sources/AutoApproveCore/YesNoConfirmation.swift', 'utf8');
const previous = await readFile(baseline, 'utf8');
const fixture = await readFile('Tests/fixtures/confirmation-normalization-check.swift', 'utf8');
const generated = path.join(output, 'Check.swift'), binary = path.join(output, 'check');
await writeFile(generated, 'import AutoApproveCore\n' + previous.replaceAll('YesNoConfirmation', 'BaselineYesNoConfirmation') + '\n' + source + '\n' + fixture);
const names = (await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o'));
execFileSync('/usr/bin/xcrun', ['swiftc', '-O', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/ConfirmationNormalizationCheck'),
  '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build),
  ...names.map(name => path.join(build, 'AutoApproveCore.build', name)), generated, '-o', binary], { stdio: 'inherit', timeout: 120000 });
const report = JSON.parse(execFileSync(binary, [], { encoding: 'utf8', timeout: 120000 }));
const sha = value => createHash('sha256').update(value).digest('hex');
report.provenance = { baselineSHA256: sha(previous), sourceSHA256: sha(source), fixtureSHA256: sha(fixture), binarySHA256: sha(await readFile(binary)) };
await writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n', { mode: 0o600 });
console.log(JSON.stringify(report));
