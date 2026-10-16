import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';

const option = (name, fallback) => process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3) ?? fallback;
const label = option('label','current'); assert.match(label,/^[a-z0-9-]+$/);
const build = path.resolve('.build/release'), directory = path.resolve('.runtime/native-session-row-bench',label);
const app = path.join(directory,'NativeSessionRowBench.app'), binary = path.join(app,'Contents/MacOS/NativeSessionRowBench');
await mkdir(path.dirname(binary),{recursive:true,mode:0o700});
const source = await readFile(option('source','Sources/AutoApproveApp/SessionWindow.swift'),'utf8');
const start=source.indexOf('private struct SessionRow:'), end=source.indexOf('\nprivate struct SessionDetail:',start);
assert.ok(start>=0&&end>start);
let component=source.slice(start,end).replace(/^private /gm,'');
const optimized=component.includes('struct SessionRowDisplay:');
function instrument(name, statements) {
  const at=component.indexOf('struct '+name+':'); assert.ok(at>=0);
  const marker='var body: some View {', body=component.indexOf(marker,at); assert.ok(body>at);
  component=component.slice(0,body+marker.length)+'\n        '+statements+'\n'+component.slice(body+marker.length);
}
instrument('SessionRow','let _ = { RowBenchCounts.rows += 1; '+(!optimized?'RowBenchCounts.labels += 1':'')+' }()');
if(optimized) {
  instrument('SessionRowDisplay','let _ = { RowBenchCounts.labels += 1 }()');
  const at=component.indexOf('final class SessionRowActions:'),brace=component.indexOf('{',at);
  assert.ok(at>=0&&brace>at);
  component=component.slice(0,brace+1)+'\n    init() { RowBenchCounts.track(self) }\n'+component.slice(brace+1);
}
const editor=await readFile('Sources/AutoApproveApp/SessionCustomizationEditor.swift','utf8');
const colorStart=editor.indexOf('extension SessionColor {'), colorEnd=editor.indexOf('\nstruct SessionCustomizationEditor:',colorStart);
assert.ok(colorStart>=0&&colorEnd>colorStart);
const file=path.join(directory,'ProductionRow.swift');
await writeFile(file,'import SwiftUI\nimport AutoApproveCore\n'+component+'\n'+editor.slice(colorStart,colorEnd));
const cache=path.resolve('.build/cache/NativeSessionRowBench');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),
  '-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
  ...(optimized?['-D','NATIVE_ROW_ACTIONS']:[]),
  'Sources/AutoApproveApp/AppHelp.swift',file,'Tests/fixtures/native-session-row-bench.swift','-o',binary],{stdio:'inherit',timeout:300000});
await writeFile(path.join(app,'Contents/Info.plist'),`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autoapprove.native-row-bench.${label}</string>
<key>CFBundleExecutable</key><string>NativeSessionRowBench</string><key>CFBundleName</key><string>NativeSessionRowBench</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/></dict></plist>`);
execFileSync('/usr/bin/codesign',['--force','--sign','-',app],{stdio:'inherit'});
const provenance={label,optimized,binarySHA256:createHash('sha256').update(await readFile(binary)).digest('hex'),
  sourceSHA256:createHash('sha256').update(source).digest('hex'),fixtureSHA256:createHash('sha256').update(await readFile('Tests/fixtures/native-session-row-bench.swift')).digest('hex')};
await writeFile(path.join(directory,'provenance.json'),JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
if(process.argv.includes('--package-only')){console.log(app);process.exit(0);}
const reports=[];
for(let trial=0;trial<3;trial++) {
  const report=path.join(directory,`trial-${trial}.json`);
  execFileSync(binary,['--measure','--report='+report],{stdio:'pipe',timeout:60000,maxBuffer:100000});
  reports.push(JSON.parse(await readFile(report,'utf8')));
}
assert.ok(reports.every(r=>r.phases.length===4&&r.phases.every(p=>p.latestGenerationApplied)));
if(optimized)assert.ok(reports.every(r=>r.actionsCreated>0&&r.actionsAliveAfterRemoval===0),'Removed row callbacks must be released');
const result={...provenance,reports};await writeFile(path.join(directory,'report.json'),JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(result));
