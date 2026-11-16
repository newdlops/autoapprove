// Real official CLI, empty isolated credential home and an app-owned PTY.
import assert from 'node:assert/strict';
import path from 'node:path';
import {mkdtemp,mkdir,writeFile,rm,access} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const cli=process.argv.find(value=>value.startsWith('--codex='))?.slice(8);
const profileStandalone=process.argv.includes('--profile-standalone');
assert.ok(cli&&path.isAbsolute(cli),'Provide the original official native Codex path');
const root=await mkdtemp('/private/tmp/aa-official-launch-'),build=path.resolve('.build/debug');
try {
 await mkdir(root+'/home');
 await writeFile(root+'/home/config.toml',`cli_auth_credentials_store="file"\ncheck_for_update_on_startup=false\n[features]\ndaemon_auto_start=${profileStandalone}\n[analytics]\nenabled=false\n`);
 if(profileStandalone){
  const current=root+'/home/packages/app-server-daemon/current/bin';
  await mkdir(current,{recursive:true});
  await writeFile(current+'/codex',`#!/bin/sh\ntouch '${root}/legacy-executed'\nexit 1\n`,{mode:0o700});
 }
 await writeFile(root+'/.zshrc','export AUTOAPPROVE_NATIVE_RUNTIME_ROOT=/owned-stale-root\nexport AUTOAPPROVE_SELECTED_TRANSITION_SOCKET=/owned-stale-socket\nexport CODEX_HOME=/owned-wrong-home\n');
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/OfficialLaunch'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),...await coreSwiftObjects(build),'Tests/fixtures/codex-official-launch.swift',...await coreLinkArguments(build),'-lsqlite3','-o',root+'/check'],{stdio:'inherit',timeout:120000});
 const environment={HOME:root,ZDOTDIR:root,PATH:'/usr/bin:/bin',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'127.0.0.1,localhost'};
 const result=JSON.parse(execFileSync(root+'/check',[root,cli,...(profileStandalone?['--profile-standalone']:[])],{encoding:'utf8',env:environment,timeout:30000}));
 assert.equal(result.verified,true);
 if(profileStandalone){
  assert.equal(result.newProfileStandalone,true);
  await assert.rejects(access(root+'/legacy-executed'),{code:'ENOENT'});
 }
 console.log(JSON.stringify({...result,realCredentialsUsed:false,userSessionsTouched:false}));
} finally {await rm(root,{recursive:true,force:true});}
