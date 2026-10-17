// Exercise the production pool using handle-allocation/notification injection.
import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const option=(name,fallback)=>process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const source=option('source','Sources/AutoApproveCore/TerminalObservationPool.swift');
const fixture='Tests/fixtures/terminal-observation-check.swift';
const root=path.resolve('.runtime/terminal-observation-check',label),cache=path.resolve('.build/cache/TerminalObservationCheck');
await mkdir(root,{recursive:true,mode:0o700});await mkdir(cache,{recursive:true});
const binary=path.join(root,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-swift-version','5','-O','-parse-as-library','-module-cache-path',cache,source,fixture,'-o',binary],{stdio:'inherit',timeout:60000});
const result=spawnSync(binary,[],{encoding:'utf8',timeout:15000});
const hash=async file=>createHash('sha256').update(await readFile(file)).digest('hex');
const report={sourceSHA256:await hash(source),integrationSourceSHA256:await hash('Sources/AutoApproveCore/TerminalCursorReader.swift'),fixtureSHA256:await hash(fixture),binarySHA256:await hash(binary),status:result.status,signal:result.signal,stdout:result.stdout,stderr:result.stderr,originalInputPosts:0};
await writeFile(path.join(root,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
assert.equal(result.status,0,result.stderr||result.error?.message);console.log(JSON.stringify(report));
