import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,chmod,readFile,symlink,rm,realpath,readdir,readlink} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import net from 'node:net';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const root=await mkdtemp('/private/tmp/aa-setup-'),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD??'.build/debug'),binary=root+'/check';
const server=net.createServer(s=>s.destroy());
try {
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ManagedServer'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-managed-server-check.swift','-o',binary],{stdio:'inherit',timeout:120000});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(root+'/daemon.sock',resolve);});
 const cases=[['stopped','stopped','running',1],['path','stopped','running',1],['missing','missingCLI','missingCLI',0],['old','unsupported','unsupported',0],['no-daemon','unsupported','unsupported',0],['running','running','running',0],['stale','stopped','running',1],['stale-failed','stopped','unavailable',1],['unverified-live','unavailable','unavailable',0],['file','unavailable','unavailable',0],['mismatch','unavailable','unavailable',0],['malformed','unavailable','unavailable',0],['failed','stopped','unavailable',1],['lost-result','stopped','running',1]];
 for(const [index,[mode,before,after,starts]] of cases.entries()) {
  const dir=root+'/case-'+index,user=dir+'/shell-home',home=dir+"/한글 공백 '$(never-execute)/.codex",bin=dir+"/bin '$(never-execute)",cli=bin+'/codex';
  await mkdir(user,{recursive:true});await mkdir(home+'/app-server-control',{recursive:true});await mkdir(bin,{recursive:true});
  const q=s=>"'"+s.replaceAll("'","'\\''")+"'";
  await writeFile(user+'/.zshrc',`export PATH=${q(bin)}:/usr/bin:/bin\nprint 'synthetic shell banner'\n`);
  const text=`#!${process.execPath}
import fs from 'node:fs';const args=process.argv.slice(2),home=process.env.CODEX_HOME,mode=${JSON.stringify(mode)},dir=${JSON.stringify(dir)},socket=${JSON.stringify(root+'/daemon.sock')};
fs.appendFileSync(dir+'/calls',JSON.stringify({args,home})+'\\n');
if(args.join(' ')==='--version'){console.log('codex-cli '+(mode==='old'?'0.165.0':'0.166.0'));process.exit(0);}
if(args.join(' ')==='app-server daemon start --help'){if(mode==='no-daemon')process.exit(2);console.log('Usage: codex app-server daemon start [OPTIONS]');process.exit(0);}
if(args.join(' ')==='app-server daemon version'){
 if(mode==='malformed'){console.log('broken JSON');process.exit(0);}
 if(!fs.existsSync(dir+'/running'))process.exit(1);
 console.log(JSON.stringify({status:'running',backend:'pid',cliVersion:'0.166.0',appServerVersion:mode==='mismatch'?'0.165.0':'0.166.0',managedCodexVersion:'0.166.0',managedCodexPath:process.argv[1],socketPath:home+'/app-server-control/app-server-control.sock'}));process.exit(0);
}
if(args.join(' ')==='app-server daemon start'){
 if(['failed','stale-failed'].includes(mode))process.exit(2);
 fs.symlinkSync(socket,home+'/app-server-control/app-server-control.sock');fs.writeFileSync(dir+'/running','');process.exit(mode==='lost-result'?1:0);
}
throw Error('Unexpected command');
`;
  if(mode!=='missing'){await writeFile(cli,text);await chmod(cli,0o700);}
  if(['running','mismatch'].includes(mode)){await symlink(root+'/daemon.sock',home+'/app-server-control/app-server-control.sock');await writeFile(dir+'/running','');}
  if(['stale','stale-failed'].includes(mode))await symlink(root+'/absent.sock',home+'/app-server-control/app-server-control.sock');
  if(mode==='unverified-live')await symlink(root+'/daemon.sock',home+'/app-server-control/app-server-control.sock');
  if(mode==='file')await writeFile(home+'/app-server-control/app-server-control.sock','not a socket');
  const result=execFileSync(binary,[user,mode==='path'?'PATH':cli,home,before,after],{encoding:'utf8',timeout:30000});assert.equal(JSON.parse(result).verified,true,mode);
  const calls=(await readFile(dir+'/calls','utf8').catch(()=>'' )).trim().split('\n').filter(Boolean).map(x=>JSON.parse(x));
  const expectedHome=(await realpath(home)).normalize('NFC');
  for(const call of calls)assert.equal((await realpath(call.home)).normalize('NFC'),expectedHome,mode+' exact physical home');
  assert.equal(calls.filter(c=>c.args.join(' ')==='app-server daemon start').length,starts,mode);
  assert.ok(calls.every(c=>['--version','app-server daemon version','app-server daemon start --help','app-server daemon start'].includes(c.args.join(' '))),mode);
  assert.ok(!(await readdir(home+'/app-server-control')).some(n=>n.includes('.autoapprove-stale-')),mode+' owned link backup cleanup');
  if(mode==='stale-failed')assert.equal(await readlink(home+'/app-server-control/app-server-control.sock'),root+'/absent.sock','Failed preparation restores exact original link');
 }
 console.log(JSON.stringify({verified:true,capabilityAndFailureCases:cases.length,literalShellPaths:true,actualDaemonActions:0,userTerminalActions:0}));
} finally {if(server.listening)await new Promise(resolve=>server.close(resolve));await rm(root,{recursive:true,force:true});}
