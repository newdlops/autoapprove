// Read-only package/preflight validation. Never registers a service, requests
// administrator approval, or sends input to a user terminal.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import path from 'node:path';

const app=path.resolve(process.argv[2]||'dist/AutoApprove.app');
const service='local.autoapprove.tty-input';
const run=(binary,args,input)=>execFileSync(binary,args,{input,stdio:['pipe','pipe','pipe'],timeout:10000});
const plist=data=>JSON.parse(run('/usr/bin/plutil',['-convert','json','-o','-','-'],data));
const info=plist(readFileSync(path.join(app,'Contents/Info.plist')));
const helper=path.join(app,'Contents/Library/LaunchServices',service);
const binary=readFileSync(helper);
function section(name) {
  assert.equal(binary.readUInt32LE(0),0xfeedfacf,'Expected a 64-bit little-endian helper');
  let offset=32;
  for(let i=0;i<binary.readUInt32LE(16);i++) {
    const command=binary.readUInt32LE(offset),size=binary.readUInt32LE(offset+4);
    assert.ok(size>=8&&offset+size<=binary.length);
    if(command===0x19) {
      const count=binary.readUInt32LE(offset+64);
      for(let index=0;index<count;index++) {
        const entry=offset+72+index*80;
        assert.ok(entry+80<=offset+size);
        const text=start=>binary.subarray(start,start+16).toString().replace(/\0.*$/s,'');
        if(text(entry)===name&&text(entry+16)==='__TEXT') {
          const length=Number(binary.readBigUInt64LE(entry+40)),start=binary.readUInt32LE(entry+48);
          assert.ok(length>0&&start+length<=binary.length);
          return plist(binary.subarray(start,start+length));
        }
      }
    }
    offset+=size;
  }
  assert.fail('Missing native installation section '+name);
}
const helperInfo=section('__info_plist'),launch=section('__launchd_plist');
const helperRequirement=info.SMPrivilegedExecutables?.[service];
assert.match(helperRequirement,/^identifier "local\.autoapprove\.tty-input" and certificate leaf = H"[a-f0-9]{40}"$/);
const appRequirement=helperRequirement.replace('"'+service+'"','"local.autoapprove.mac"');
assert.deepEqual(helperInfo.SMAuthorizedClients,[appRequirement]);
assert.equal(helperInfo.CFBundleIdentifier,service);
assert.equal(helperInfo.CFBundleVersion,info.CFBundleVersion);
assert.equal(helperInfo.CFBundleShortVersionString,info.CFBundleShortVersionString);
assert.deepEqual(launch,{Label:service,MachServices:{[service]:true},UserName:'root',RunAtLoad:true,
  KeepAlive:{SuccessfulExit:false},ThrottleInterval:10});
run('/usr/bin/codesign',['--verify','--deep','--strict','-R='+appRequirement,app]);
for(const file of [helper,path.join(app,'Contents/MacOS/AutoApproveTTYService')]) {
  run('/usr/bin/codesign',['--verify','--strict','-R='+helperRequirement,file]);
}
const plan=JSON.parse(run(path.join(app,'Contents/MacOS/autoapprove'),['terminal-input','prepare']));
assert.equal(plan.registration,'SMJobBless');assert.equal(plan.application,app);
assert.equal(plan.program,'Contents/Library/LaunchServices/'+service);
assert.equal(plan.developerIDRequired,false);assert.equal(plan.administratorShell,false);
console.log('PASS: packaged CLI validates sealed native installation metadata, exact root job and version, mutually pinned publisher signatures, and no Developer ID requirement; no installation or permission changes performed.');
