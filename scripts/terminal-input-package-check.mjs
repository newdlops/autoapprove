// Read-only validation. No permission prompts, service installation or terminal input.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync,realpathSync,existsSync} from 'node:fs';
import path from 'node:path';
const app=path.resolve(process.argv[2]||'dist/AutoApprove.app');
const run=(binary,args,input)=>execFileSync(binary,args,{input,stdio:['pipe','pipe','pipe'],timeout:10000,maxBuffer:64*1024*1024});
const info=JSON.parse(run('/usr/bin/plutil',['-convert','json','-o','-','-'],readFileSync(path.join(app,'Contents/Info.plist'))));
assert.equal(info.CFBundleIdentifier,'local.autoapprove.mac');
assert.equal(info.SMPrivilegedExecutables,undefined);
for(const relative of ['Contents/MacOS/AutoApproveTTYService','Contents/Library/LaunchServices/local.autoapprove.tty-input','Contents/Library/LaunchDaemons/local.autoapprove.tty-input.plist']) {
  assert.equal(existsSync(path.join(app,relative)),false,'Retired privileged payload must not ship: '+relative);
}
run('/usr/bin/codesign',['--verify','--deep','--strict',app]);
const cli=path.join(app,'Contents/MacOS/autoapprove');
run('/usr/bin/codesign',['--verify','--strict',cli]);
const plan=JSON.parse(run(cli,['terminal-input','prepare']));
assert.equal(plan.registration,'Accessibility');assert.equal(realpathSync(plan.application),realpathSync(app));
assert.equal(plan.administratorShell,false);assert.equal(plan.privilegedService,false);assert.equal(plan.requiresAccessibility,true);
// The removed injection backend must not remain linked into either executable.
for(const binary of [cli,path.join(app,'Contents/MacOS/AutoApproveApp')]) {
  const symbols=run('/usr/bin/nm',['-g',binary]).toString();
  assert.ok(!/SMJobBless|AuthorizationExecuteWithPrivileges|\b_ap_tty_write\b/.test(symbols),'Privileged installer or TTY injection symbol must not remain');
  assert.equal(readFileSync(binary).includes(Buffer.from('local.autoapprove.tty-input')),false,'Retired Mach service must not remain in the executable');
}
console.log('PASS: signed app/CLI use Accessibility; no privileged helper, launch daemon, SMJobBless metadata or privileged installation calls.');
