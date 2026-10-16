import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir, readdir, readFile, writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';

const label = process.argv[2] || 'current'; assert.match(label, /^[a-z0-9-]+$/);
const build = path.resolve('.build/release'), directory = path.resolve('.runtime/lan-interface-bench', label);
await mkdir(directory, {recursive:true, mode:0o700});
const binary = path.join(directory, 'LANInterfaceBench'), cache = path.resolve('.build/cache/LANInterfaceBench');
await mkdir(cache, {recursive:true});
execFileSync('/usr/bin/xcrun', ['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),
  '-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
  'Tests/fixtures/lan-interface-bench.swift','-o',binary], {stdio:'inherit', timeout:300_000});
const report = JSON.parse(execFileSync(binary, [], {encoding:'utf8', timeout:60_000}));
report.label = label; report.binarySHA256 = createHash('sha256').update(await readFile(binary)).digest('hex');
await writeFile(path.join(directory,'report.json'), JSON.stringify(report,null,2)+'\n', {mode:0o600});
console.log(JSON.stringify(report));
