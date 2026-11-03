import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import {mkdtemp, rm, realpath, readFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {coreLinkArguments, coreSwiftObjects} from './swift-core-link.mjs';

// Opt-in real 0.166 managed package; never invoke a daemon in the user's home.
const cli=await realpath(process.env.AUTOAPPROVE_CODEX_BIN || path.join(os.homedir(),'.codex/packages/app-server-daemon/current/bin/codex'));
const metadata=JSON.parse(await readFile(path.join(path.dirname(path.dirname(cli)),'codex-package.json'),'utf8'));
assert.equal(metadata.version,'0.166.0','Probe is pinned to the observed 0.166.0 protocol');
assert.equal(metadata.entrypoint,'bin/codex');
const build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD || '.build/debug');
const root=await mkdtemp('/private/tmp/aa-official-continuation-check-');
let child;
try {
  const checker=path.join(root,'check');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AccountContinuation'),
    '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
    ...await coreSwiftObjects(build),'Tests/fixtures/codex-account-continuation.swift','-o',checker],{stdio:'inherit',timeout:120000});
  const options=process.argv.slice(2);
  assert.ok(options.every(value=>['--different-account','--keep-fixture'].includes(value)),'Unknown probe option');
  child=spawn('/usr/bin/python3',['Tests/fixtures/codex-account-official-continuation.py','--cli',cli,'--check',checker,...options],{stdio:'inherit'});
  const status=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',resolve);});
  assert.equal(status,0,'Owned native TUI lifecycle failed; no existing user sessions were used');
} finally {
  if(child && child.exitCode===null)child.kill('SIGTERM');
  await rm(root,{recursive:true,force:true});
}
