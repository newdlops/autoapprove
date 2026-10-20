import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const label=option('label','current');assert.match(label,/^[a-z0-9-]+$/);
const source=path.resolve(option('source-dir','Sources/AutoApproveApp')),build=path.resolve(option('core-build','.build/release'));
const output=path.resolve('.runtime/native-session-selection-bench',label),app=output+'/SessionSelectionBench.app',binary=app+'/Contents/MacOS/SessionSelectionBench';
await mkdir(path.dirname(binary),{recursive:true,mode:0o700});
const sha=v=>createHash('sha256').update(v).digest('hex'),inputs={},files=[];
let hasDrafts=false;
for(const name of ['SessionWindow.swift','WindowViewUpdates.swift','AppHelp.swift','SessionCustomizationEditor.swift']) {
 let text=await readFile(source+'/'+name,'utf8');inputs[name]=sha(text);
 if(name==='SessionWindow.swift') {
  hasDrafts=text.includes('final class QuestionReplyDrafts:');
  assert.ok(text.includes('@State private var selection: Set<String> = []'));
  text=text.replace('@State private var selection: Set<String> = []','@ObservedObject private var interaction = SessionSelectionState.shared\n    private var selection: Set<String> { get { interaction.selection } nonmutating set { interaction.selection = newValue } }').replaceAll('$selection','$interaction.selection');
  if(hasDrafts)text=text.replace('    var body: some View {','    var body: some View {\n        let _ = { SelectionBenchCounts.drafts = questionDrafts }()');
  for(const [name,statement] of [['SessionDetail','SelectionBenchCounts.detailSession = session.id; SelectionBenchCounts.details += 1'],['QuestionReplyEditor','SelectionBenchCounts.editors += 1']]) {
   const start=text.indexOf('struct '+name+':'),body=text.indexOf('    var body: some View {',start);assert.ok(start>=0&&body>start);
   const at=body+'    var body: some View {'.length;text=text.slice(0,at)+'\n        let _ = { '+statement+' }()'+text.slice(at);
  }
 }
 const target=output+'/'+name;await writeFile(target,text);files.push(target);
}
const fixture=await readFile('Tests/fixtures/native-session-selection-bench.swift');await writeFile(output+'/Fixture.swift',fixture);
const objects=(await readdir(build+'/AutoApproveCore.build')).filter(v=>v.endsWith('.swift.o')).sort();
await mkdir('.build/cache/SessionSelectionBench',{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library',...(hasDrafts?['-DNATIVE_QUESTION_DRAFTS']:[]),'-module-cache-path',path.resolve('.build/cache/SessionSelectionBench'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects.map(n=>build+'/AutoApproveCore.build/'+n),...files,output+'/Fixture.swift','-o',binary],{stdio:'inherit',timeout:300000});
await writeFile(app+'/Contents/Info.plist',`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.autoapprove.session-selection.${label}</string><key>CFBundleExecutable</key><string>SessionSelectionBench</string><key>CFBundleName</key><string>SessionSelectionBench</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>CFBundleDevelopmentRegion</key><string>ko</string><key>NSHighResolutionCapable</key><true/></dict></plist>`);
execFileSync('/usr/bin/codesign',['--force','--sign','-',app],{stdio:'inherit'});
await writeFile(output+'/provenance.json',JSON.stringify({label,inputs,hasDrafts,fixtureSHA256:sha(fixture),binarySHA256:sha(await readFile(binary)),coreModuleSHA256:sha(await readFile(build+'/Modules/AutoApproveCore.swiftmodule')),coreObjects:Object.fromEntries(await Promise.all(objects.map(async n=>[n,sha(await readFile(build+'/AutoApproveCore.build/'+n))])))},null,2)+'\n');
console.log(app);
