import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';

const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const directory=path.resolve('.runtime/terminal-cursor-read-check'),build=path.resolve('.build/release');
await mkdir(directory,{recursive:true,mode:0o700});
const source=await readFile('Sources/AutoApproveCore/TerminalCursorReader.swift','utf8');
const end=source.indexOf('\nextension TerminalCursor {');assert.ok(end>0);
const component=directory+'/ProductionCursor.swift';
await writeFile(component,'import AutoApproveCore\n'+source.slice(0,end)+'\n');
const files=[component],inputs={production:createHash('sha256').update(source).digest('hex')};
const baseline=option('baseline');
if(baseline) {
  const previous=await readFile(baseline,'utf8');
  const helpers=previous.indexOf('        func point('),body=previous.indexOf('        let windows = attribute(application, kAXWindowsAttribute)'),stop=previous.indexOf('\n    }\n}\n',body);
  assert.ok(helpers>=0&&body>helpers&&stop>body);
  let logic=previous.slice(helpers,previous.indexOf('        let application = AXUIElementCreateApplication(',helpers))+previous.slice(body,stop);
  const old='                var values: CFArray?\n                let names = [kAXValueAttribute, kAXSelectedTextRangeAttribute, kAXVisibleCharacterRangeAttribute] as CFArray\n                if AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,\n                   let fields = values as? [Any], fields.count == 3';
  assert.ok(logic.includes(old));
  logic=logic.replace(old,'                let names = [kAXValueAttribute, kAXSelectedTextRangeAttribute, kAXVisibleCharacterRangeAttribute]\n                if let fields = attributes(element, names), fields.count == 3');
  const file=directory+'/BaselineCursor.swift';
  await writeFile(file,`import AppKit\nimport ApplicationServices\nimport AutoApproveCore\nenum BaselineCursorReader {
    static func accessibilitySnapshot(screen: String, title: String?, bounds: TerminalWindowBounds,
        application: AXUIElement, deadline: Date, attributes: (AXUIElement,[String])->[Any]?) -> TerminalTextSnapshot? {
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard Date() < deadline, let fields = attributes(element,[name]), fields.count == 1 else { return nil }
            let value = fields[0] as CFTypeRef
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { return nil }
            return value
        }
${logic}
    }
}
`);
  files.push(file);inputs.baseline=createHash('sha256').update(previous).digest('hex');
}
const fixture=await readFile('Tests/fixtures/terminal-cursor-read-check.swift');
await writeFile(directory+'/Fixture.swift',fixture);
inputs.fixture=createHash('sha256').update(fixture).digest('hex');
const cache=path.resolve('.build/cache/TerminalCursorReadCheck');await mkdir(cache,{recursive:true});
const binary=directory+'/check';
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,
  '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).map(n=>build+'/AutoApproveCore.build/'+n),
  ...(baseline?['-D','CURSOR_BASELINE']:[]),...files,directory+'/Fixture.swift','-o',binary],{stdio:'inherit',timeout:300000});
const report=JSON.parse(execFileSync(binary,process.argv.includes('--live-window-bench')?['--live-window-bench']:[],{encoding:'utf8',timeout:30000}));
const result={inputs,binarySHA256:createHash('sha256').update(await readFile(binary)).digest('hex'),...report};
await writeFile(directory+'/report.json',JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(result));
