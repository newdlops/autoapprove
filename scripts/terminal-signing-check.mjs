// Isolated signature update compatibility; no GUI, permission changes, or terminal input.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {cp,readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {signApp} from './sign-app.mjs';
const directory=await mkdtemp(path.join(tmpdir(),'autoapprove-signing-check-'));
const run=(args)=>execFileSync('/usr/bin/codesign',args,{stdio:['ignore','pipe','pipe'],encoding:'utf8'});
try {
  const original=path.resolve(process.argv[2]||'dist/AutoApprove.app');
  const update=path.join(directory,'Update.app'),other=path.join(directory,'AdHoc.app');
  await cp(original,update,{recursive:true});await cp(original,other,{recursive:true});
  run(['--verify','--deep','--strict',original]);
  const requirement=run(['-d','-r-',original]).trim().replace(/^designated => /,'');
  assert.ok(/certificate|anchor/.test(requirement)&&!requirement.includes('cdhash'));
  const file=path.join(update,'Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/app.css');
  await writeFile(file,(await readFile(file,'utf8'))+'\n/* signing update test */\n');
  await signApp(update,{allowProvisioning:false});
  const updated=run(['-d','-r-',update]).trim().replace(/^designated => /,'');
  assert.equal(updated,requirement,'An update must keep the signer-bound designated requirement');
  run(['--verify','--deep','--strict','-R='+requirement,update]);
  run(['--verify','--deep','--strict','-R='+updated,original]);
  run(['--force','--sign','-','--preserve-metadata=identifier,entitlements',other]);
  assert.throws(()=>run(['--verify','-R='+requirement,other]),'Same bundle ID with a different signer must not inherit privacy identity');
  console.log('PASS: signer-bound identity survives updated resources; mutually compatible requirements; ad-hoc impersonation rejected; no permissions or GUI touched');
} finally { await rm(directory,{recursive:true,force:true}); }
