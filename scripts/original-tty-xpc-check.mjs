// Real signed XPC transport on disposable per-user launchd jobs. No root daemon,
// TTY access, permission dialog, new signing identity, or original CLI input.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,copyFile,writeFile,readFile,readdir,rm} from 'node:fs/promises';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {signApp} from './sign-app.mjs';
const root=process.cwd(),build=path.resolve('.build/debug'),domain='gui/'+process.getuid();
await mkdir('.runtime/tty-xpc-qa',{recursive:true,mode:0o700});
const directory=await mkdtemp(path.resolve('.runtime/tty-xpc-qa/check-'));
const app=path.join(directory,'AutoApprove.app'),macOS=path.join(app,'Contents/MacOS');
const jobs=[];
const run=(file,args)=>execFileSync(file,args,{encoding:'utf8',timeout:15000});
const xml=value=>String(value).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
try {
  await mkdir(macOS,{recursive:true});
  const binary=path.join(macOS,'AutoApproveApp');
  const objects=(await readdir(path.join(build,'TerminalInputSupport.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'TerminalInputSupport.build',name));
  run('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OriginalTTYAdapterChecks'),
    '-I',path.join(build,'Modules'),'-I',path.join(build,'CTTYInput.build'),'Tests/fixtures/original-tty-xpc-check.swift',...objects,
    path.join(build,'CTTYInput.build/tty_input.c.o'),'-o',binary]);
  const cli=path.join(macOS,'autoapprove'),service=path.join(macOS,'AutoApproveTTYService');
  await copyFile(binary,cli);await copyFile(binary,service);
  await writeFile(path.join(app,'Contents/Info.plist'),'<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.autoapprove.mac</string><key>CFBundleExecutable</key><string>AutoApproveApp</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
  await signApp(app,{allowProvisioning:false});
  const certificate=path.join(directory,'publisher');
  run('/usr/bin/codesign',['-d','--extract-certificates='+certificate,service]);
  const fingerprint=createHash('sha1').update(await readFile(certificate+'0')).digest('hex');
  const requirement=id=>'identifier "'+id+'" and certificate leaf = H"'+fingerprint+'"';
  const serverRequirement=requirement('local.autoapprove.tty-input');
  const clientRequirement='('+requirement('local.autoapprove.mac')+') or ('+requirement('local.autoapprove.helper')+')';
  async function start(executable,extra=[]){
    const name='local.autoapprove.tty-input.qa.'+randomUUID(),plist=path.join(directory,name+'.plist'),log=path.join(directory,name+'.log');
    await writeFile(log,'',{mode:0o600});
    const args=[executable,'serve',name,log,...extra];
    await writeFile(plist,'<?xml version="1.0"?><plist version="1.0"><dict><key>Label</key><string>'+name+'</string><key>ProgramArguments</key><array>'+args.map(arg=>'<string>'+xml(arg)+'</string>').join('')+'</array><key>MachServices</key><dict><key>'+name+'</key><true/></dict><key>RunAtLoad</key><true/><key>WorkingDirectory</key><string>'+xml(root)+'</string></dict></plist>',{mode:0o600});
    run('/bin/launchctl',['bootstrap',domain,plist]);jobs.push(name);return {name,log};
  }
  const trusted=await start(service);
  for(const client of [binary,cli])assert.match(run(client,['client',trusted.name,'accept']),/packet accepted/);
  assert.match(run(service,['client',trusted.name,'refuse']),/peer refused/,'Same signer with service ID must not be accepted as an app/CLI client');
  const untrusted=path.join(directory,'adhoc-client');await copyFile(cli,untrusted);
  run('/usr/bin/codesign',['--force','--sign','-','--identifier','local.autoapprove.helper',untrusted]);
  assert.match(run(untrusted,['client',trusted.name,'refuse',serverRequirement]),/peer refused/,'Matching ID with another signer must be refused');
  const originalLog=(await readFile(trusted.log,'utf8')).trim().split('\n');
  assert.deepEqual(originalLog.filter(line=>line.startsWith('status:')),['status:'+process.getuid(),'status:'+process.getuid()]);
  assert.deepEqual(originalLog.filter(line=>line.startsWith('bytes:')),Array(2).fill('bytes:'+process.getuid()+':'+Buffer.from('한글🙂\x1b[D\r').toString('base64')));
  const badServer=path.join(directory,'adhoc-server');await copyFile(service,badServer);
  run('/usr/bin/codesign',['--force','--sign','-','--identifier','local.autoapprove.tty-input',badServer]);
  const impostor=await start(badServer,[clientRequirement]);
  assert.match(run(cli,['client',impostor.name,'refuse']),/peer refused/,'Client must reject a service with the correct ID but another signer');
  // Client-side requirements reject incoming service messages. A harmless
  // status probe can arrive first; it must not authorize any input delivery.
  assert.deepEqual((await readFile(impostor.log,'utf8')).trim().split('\n'),['status:'+process.getuid()],
    'An untrusted status reply must prevent input payload delivery');
  console.log('PASS: real signed App/CLI XPC acceptance, exact UTF-8 packets, same-signer wrong-ID refusal, ad-hoc client refusal and client-side wrong-signer service refusal; unprivileged fixtures only');
} finally {
  for(const name of jobs.reverse())try{run('/bin/launchctl',['bootout',domain+'/'+name]);}catch{}
  await rm(directory,{recursive:true,force:true});
}
