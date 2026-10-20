import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const selectedSession=option('selected-session',null);if(selectedSession)assert.match(selectedSession,/^[a-z0-9-]+$/);
const build=path.resolve(option('core-build','.build/release')),source=path.resolve(option('source-dir','Sources/AutoApproveApp'));
const output=path.resolve('.runtime/native-window-update-bench',label),app=output+'/NativeWindowUpdateBench.app';
const binary=app+'/Contents/MacOS/NativeWindowUpdateBench';
await mkdir(path.dirname(binary),{recursive:true,mode:0o700});
const inputs={};
for(const file of ['SessionWindow.swift','AuditHistoryWindow.swift']) {
  let text=await readFile(file==='SessionWindow.swift'?option('session-source',source+'/'+file):source+'/'+file,'utf8');inputs[file]=createHash('sha256').update(text).digest('hex');
  const call=file==='SessionWindow.swift'?'WindowBenchCounts.session(engine.snapshot, initial: engine.initialDiscoveryComplete, error: notifications.error)':'WindowBenchCounts.history(engine.snapshot)';
  const at=text.indexOf('    var body: some View {');assert.ok(at>=0);
  text=text.slice(0,at)+text.slice(at).replace('    var body: some View {','    var body: some View {\n        let _ = '+call);
  if(file==='SessionWindow.swift') {
    if(selectedSession) {
      const selection='@State private var selection: Set<String> = []';assert.ok(text.includes(selection));
      text=text.replace(selection,'@State private var selection: Set<String> = ["'+selectedSession+'"]');
    }
    for(const [name,counter] of [[text.includes('struct CodexQuestionListDisplay:')?'CodexQuestionListDisplay':'CodexQuestionList','queueBodies'],['QuestionReplyEditor','editorBodies']]) {
      const start=text.indexOf('struct '+name+':'),body=text.indexOf('    var body: some View {',start);
      assert.ok(start>=0&&body>start);
      const end=body+'    var body: some View {'.length;
      text=text.slice(0,end)+'\n        let _ = { WindowBenchCounts.'+counter+' += 1 }()'+text.slice(end);
    }
  }
  await writeFile(output+'/'+file,text);
}
const shared=['WindowViewUpdates.swift','AppHelp.swift','SessionCustomizationEditor.swift'];
for(const file of shared)inputs[file]=createHash('sha256').update(await readFile(source+'/'+file)).digest('hex');
const fixture=await readFile('Tests/fixtures/native-window-update-bench.swift');
await writeFile(output+'/Fixture.swift',fixture);
const objects=(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).sort();
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AutomaticQuestionPreview'),
  '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...objects.map(n=>build+'/AutoApproveCore.build/'+n),...shared.map(n=>source+'/'+n),output+'/SessionWindow.swift',output+'/AuditHistoryWindow.swift',
  output+'/Fixture.swift','-o',binary],{stdio:'inherit',timeout:300000});
await writeFile(app+'/Contents/Info.plist',`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.autoapprove.native-window-update.${label}</string>
<key>CFBundleExecutable</key><string>NativeWindowUpdateBench</string><key>CFBundleName</key><string>NativeWindowUpdateBench</string>
<key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string>
<key>CFBundleDevelopmentRegion</key><string>ko</string><key>NSHighResolutionCapable</key><true/></dict></plist>`);
execFileSync('/usr/bin/codesign',['--force','--sign','-',app],{stdio:'inherit'});
const sha=p=>readFile(p).then(v=>createHash('sha256').update(v).digest('hex'));
const provenance={label,selectedSession,inputs,fixtureSHA256:createHash('sha256').update(fixture).digest('hex'),binarySHA256:await sha(binary),
  coreModuleSHA256:await sha(build+'/Modules/AutoApproveCore.swiftmodule'),coreObjects:Object.fromEntries(await Promise.all(objects.map(async n=>[n,await sha(build+'/AutoApproveCore.build/'+n)])))};
await writeFile(output+'/provenance.json',JSON.stringify(provenance,null,2)+'\n',{mode:0o600});
console.log(app);
