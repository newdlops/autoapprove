import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const out=path.resolve(option('output','.runtime/automation-target-check/current')),cache=path.resolve('.build/cache/AutomationTarget');
await mkdir(out,{recursive:true});await mkdir(cache,{recursive:true});
const source=await readFile('Sources/AutoApproveCore/TerminalWindowCapture.swift','utf8');
const start=source.indexOf('    nonisolated private static func liveAutomationPermission('),end=source.indexOf('\n    private static func livePermissions(',start);
assert.ok(start>=0&&end>start);
const implementation=source.slice(start,end).replace('nonisolated private static func','private func')
 .replaceAll('NSRunningApplication','FixtureRunningApplication').replaceAll('AEDeterminePermissionToAutomateTarget','fixturePermission');
const fixture=await readFile('Tests/fixtures/automation-target-check.swift','utf8'),generated=path.join(out,'AutomationTargetCheck.swift'),binary=path.join(out,'AutomationTargetCheck');
await writeFile(generated,fixture+'\n'+implementation+'\n');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,generated,'-o',binary],{stdio:'inherit',timeout:120000});
const sha=b=>createHash('sha256').update(b).digest('hex');
await writeFile(path.join(out,'provenance.json'),JSON.stringify({sourceSHA256:sha(source),fixtureSHA256:sha(fixture),binarySHA256:sha(await readFile(binary))},null,2)+'\n');
execFileSync(binary,[],{stdio:'inherit',timeout:10000});
