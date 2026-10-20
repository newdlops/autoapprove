import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';

const build=path.resolve('.build/release'),directory=path.resolve('.runtime/automation-script-check');
await mkdir(directory,{recursive:true,mode:0o700});
const source=await readFile('Sources/AutoApproveCore/TerminalAdapter.swift','utf8');
const start=source.indexOf('enum AutomationScript {'),end=source.indexOf('\npublic enum TerminalDelivery:',start);
assert.ok(start>=0&&end>start);
const component=directory+'/ProductionAutomationScript.swift';
await writeFile(component,'import Foundation\nimport AutoApproveCore\n'+source.slice(start,end));
const cache=path.resolve('.build/cache/AutomationScriptCheck');await mkdir(cache,{recursive:true});
const binary=directory+'/check',objects=(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).sort();
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,
  '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...objects.map(n=>build+'/AutoApproveCore.build/'+n),component,'Tests/fixtures/automation-script-check.swift','-o',binary],{stdio:'inherit',timeout:300000});
const report=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:30000}));
const sha=v=>createHash('sha256').update(v).digest('hex');
report.sourceSHA256=sha(source);report.processSourceSHA256=sha(await readFile('Sources/AutoApproveCore/ProcessDiscovery.swift'));
report.fixtureSHA256=sha(await readFile('Tests/fixtures/automation-script-check.swift'));
report.scope='Production script transport and optimized Core CommandRunner; pure JXA values and one isolated owned shell only. No Terminal Apple events, original input or settings changes. Not a reproduction or proven fix of Apple Terminal resizing crashes.';
await writeFile(directory+'/report.json',JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report));
