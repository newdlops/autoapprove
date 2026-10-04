import { coreLinkArguments } from './swift-core-link.mjs';
import { execFileSync } from 'node:child_process';
import { mkdir, readdir } from 'node:fs/promises';
import path from 'node:path';
const build = path.resolve('.build/debug');
const output = path.resolve('.build/qa/NamedAccessChecks');
await mkdir(path.dirname(output), { recursive: true });
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', path.resolve('.build/cache/NamedAccessChecks'), '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build), ...(await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name)), 'Tests/fixtures/named-access-check.swift', '-o', output], { stdio: 'inherit' });
execFileSync(output, [], { stdio: 'inherit' });
