// Private original transport/capture opt-in checks. Never reads a real window or CLI.
import {execFileSync} from 'node:child_process';
import {mkdtemp,readdir,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const bridge=process.argv.includes('--bridge');
const directory=await mkdtemp(path.join(bridge?'/private/tmp':tmpdir(),bridge?'aa-source-':'autoapprove-terminal-view-check-'));
try {
  const cache=path.resolve('.build/cache/TerminalViewChecks');await mkdir(cache,{recursive:true});
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary=path.join(directory,'TerminalViewChecks');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,bridge?'Tests/fixtures/terminal-source-relay-check.swift':'Tests/fixtures/terminal-view-check.swift','-o',binary],{stdio:'inherit'});
  execFileSync(binary,[directory],{stdio:'inherit',timeout:30000});
} finally {await rm(directory,{recursive:true,force:true});}
