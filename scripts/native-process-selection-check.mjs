// Source-level differential check for the exact internal discovery selection
// helpers. No process discovery, input, screen capture or system changes.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
const output=fs.mkdtempSync(path.join(os.tmpdir(),'aa-selection-check-'));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const file='Sources/AutoApproveCore/NativeProcessReader.swift',source=fs.readFileSync(file,'utf8');
const markers=['    private static let codexName','    static func read(','    static func sessionIndices(','    private static func snapshot('];
for(const marker of markers)assert.equal(source.split(marker).length,2,'Selection helper extraction requires a unique marker');
const [fieldsStart,fieldsEnd,helperStart,helperEnd]=markers.map(value=>source.indexOf(value));
assert.ok(fieldsStart<fieldsEnd&&fieldsEnd<helperStart&&helperStart<helperEnd);
const extracted='import Foundation\nimport Darwin\nenum NativeProcessReader {\n'+source.slice(fieldsStart,fieldsEnd)+source.slice(helperStart,helperEnd)+'}\n';
const helper=output+'/SelectionHelpers.swift',binary=output+'/check';fs.writeFileSync(helper,extracted,{mode:0o600});
const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');fs.mkdirSync(cache,{recursive:true});
try {
 const args=['swiftc','-O','-parse-as-library','-module-cache-path',cache,helper,'Tests/fixtures/native-process-selection-check.swift','-o',binary];
 execFileSync('/usr/bin/xcrun',args,{stdio:'inherit'});
 const report=execFileSync(binary,[],{encoding:'utf8',timeout:30000});assert.match(report,/SELECTION 3035 cases 285121 selected indices; cancellation preserved/);
 assert.equal(fs.readFileSync(file,'utf8'),source,'Production source changed during the check');
 console.log(report.trim());console.log(JSON.stringify({sourceSHA256:hash(Buffer.from(source)),helperSHA256:hash(Buffer.from(extracted)),liveProcessReads:0,inputPosts:0}));
} finally { fs.rmSync(output,{recursive:true,force:true}); }
