// Checks the production discovery factory from a detached Swift task. No UI automation.
import {execFileSync} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/terminal-profile-process-check');
const cache=path.resolve('.build/cache/TerminalProcessQA');
await mkdir(out,{recursive:true});await mkdir(cache,{recursive:true});
const executable=out+'/TerminalProcessCheck';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-swift-version','5','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/terminal-profile-process-check.swift','-o',executable],{stdio:'inherit',timeout:120000});
execFileSync(executable,[],{stdio:'inherit',timeout:30000});
