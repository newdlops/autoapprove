// Compare the exact validation source with a fixed release. Synthetic strings only.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';

const reference=process.argv.find(value=>value.startsWith('--reference='))?.slice(12)??'v0.2.178';
assert.match(reference,/^[A-Za-z0-9][A-Za-z0-9._/-]*$/);
const file='Sources/AutoApproveCore/RemoteTerminalScreenPatch.swift';
const fixture='Tests/fixtures/native-screen-patch-check.swift';
const runner='scripts/native-screen-patch-check.mjs';
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const source={
  Reference:execFileSync('git',['-c','core.fsmonitor=false','show',reference+':'+file],{encoding:'utf8'}),
  Candidate:fs.readFileSync(file,'utf8')
};
const tracked=Object.fromEntries([file,fixture,runner].map(name=>[name,sha(fs.readFileSync(name))]));
const output=fs.mkdtempSync(path.join(os.tmpdir(),'aa-native-screen-patch-'));
let passed=false;
try {
  for(const[label,text]of Object.entries(source)) {
    let renamed=text;
    renamed=renamed.replaceAll(/\bRemoteTerminalScreenPatch\b/g,label+'Patch');
    if(label==='Candidate')renamed+='\nextension CandidatePatch { static func oracleUnits(_ text:String)->Int { text.utf8.withContiguousStorageIfAvailable { nativeUnits($0,0..<$0.count) }! } }\n';
    fs.writeFileSync(output+'/'+label+'.swift',renamed,{mode:0o600});
  }
  const cache=path.resolve(process.env.AUTOAPPROVE_SWIFT_MODULE_CACHE||'.build/module-cache');
  fs.mkdirSync(cache,{recursive:true});
  execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,
    output+'/Reference.swift',output+'/Candidate.swift',fixture,'-o',output+'/check'],{stdio:'inherit',timeout:180000});
  const report=execFileSync(output+'/check',[],{encoding:'utf8',timeout:300000,maxBuffer:8*1024*1024});
  assert.match(report,/NATIVE_PATCH scalars 1112064; utf16Units 65536; cases 269414; foreign 178010; accepted 258394; json 21275; checksum 1404785650038312242/);
  for(const[name,digest]of Object.entries(tracked))assert.equal(sha(fs.readFileSync(name)),digest,name);
  console.log(report.trim());
  console.log(JSON.stringify({reference,exactSourceComparison:true,standaloneFoundationOnly:true,
    sourceHashes:Object.fromEntries(Object.entries(source).map(([label,text])=>[label,sha(Buffer.from(text))])),
    originalTerminalActions:0,realPowerCommands:0}));
  passed=true;
} finally {
  if(passed)fs.rmSync(output,{recursive:true,force:true});
  else console.error('Synthetic diagnostic files retained at '+output);
}
