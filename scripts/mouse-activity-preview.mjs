import {execFileSync} from 'node:child_process';
import {readdir, mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const build = path.resolve('.build', process.argv.includes('--release') ? 'release' : 'debug');
const output = path.resolve('dist/qa/mouse-activity');
await mkdir(output, {recursive:true});
const objects = (await readdir(path.join(build, 'AutoApproveCore.build'))).filter(name => name.endsWith('.swift.o')).map(name => path.join(build, 'AutoApproveCore.build', name));
const cache = path.resolve('.build/cache/MouseActivityPreview');
await mkdir(cache, {recursive:true});
const binary = path.join(output, 'MouseActivityPreview');
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', cache,
  '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build), ...objects,
  'Sources/AutoApproveApp/MouseActivitySettings.swift', 'Tests/fixtures/mouse-activity-preview.swift', '-o', binary], {stdio:'inherit'});
execFileSync(binary, [output], {stdio:'inherit', timeout:15000});
