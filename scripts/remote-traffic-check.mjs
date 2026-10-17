// Compile the actual actor source, with a transport-only fake in the fixture.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const option=(key,fallback)=>process.argv.find(arg=>arg.startsWith('--'+key+'='))?.slice(key.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const directory=path.resolve('.runtime/remote-traffic-check',label),source=path.resolve(option('source','Sources/AutoApproveCore/RemoteDiscoveryTraffic.swift'));
await mkdir(directory,{recursive:true,mode:0o700});await mkdir('.build/cache/RemoteTrafficCheck',{recursive:true});
const binary=path.join(directory,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/RemoteTrafficCheck'),source,'Tests/fixtures/remote-traffic-check.swift','-o',binary],{stdio:'inherit',timeout:120000});
const baseline=process.argv.includes('--baseline');
const raw=execFileSync(binary,baseline?['--baseline']:[],{encoding:'utf8',timeout:30000});
const report={sourceSHA256:createHash('sha256').update(await readFile(source)).digest('hex'),fixtureSHA256:createHash('sha256').update(await readFile('Tests/fixtures/remote-traffic-check.swift')).digest('hex'),...JSON.parse(raw)};
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report));
