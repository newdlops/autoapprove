import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const directory=await mkdtemp(path.join(tmpdir(),'autoapprove-approval-reflow-'));
try {
  const cache=path.resolve('.build/cache/ApprovalReflowChecks');await mkdir(cache,{recursive:true});
  const binary=path.join(directory,'ApprovalReflowChecks');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-approval-reflow-check.swift','-o',binary],{stdio:'inherit'});
  execFileSync(binary,[directory],{stdio:'inherit',timeout:45000});
} finally {await rm(directory,{recursive:true,force:true});}
