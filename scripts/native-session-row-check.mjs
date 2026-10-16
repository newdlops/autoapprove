import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const build=path.resolve('.build/release'),directory=path.resolve('.runtime/native-session-row-check');
await mkdir(directory,{recursive:true,mode:0o700});
const source=await readFile('Sources/AutoApproveApp/SessionWindow.swift','utf8');
const start=source.indexOf('private struct SessionRow:'),end=source.indexOf('\nprivate struct SessionDetail:',start);
assert.ok(start>=0&&end>start&&source.includes('struct SessionRowDisplay:'));
const editor=await readFile('Sources/AutoApproveApp/SessionCustomizationEditor.swift','utf8');
const a=editor.indexOf('extension SessionColor {'),b=editor.indexOf('\nstruct SessionCustomizationEditor:',a);
assert.ok(a>=0&&b>a);
const component=path.join(directory,'ProductionRow.swift');
await writeFile(component,'import SwiftUI\nimport AutoApproveCore\n'+source.slice(start,end).replace(/^private /gm,'')+'\n'+editor.slice(a,b));
const cache=path.resolve('.build/cache/NativeSessionRowCheck');await mkdir(cache,{recursive:true});
const binary=path.join(directory,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),
  '-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
  'Sources/AutoApproveApp/AppHelp.swift',component,'Tests/fixtures/native-session-row-check.swift','-o',binary],{stdio:'inherit',timeout:300000});
const report=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:15000}));
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report));
