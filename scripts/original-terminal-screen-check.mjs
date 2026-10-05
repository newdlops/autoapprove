import {execFileSync} from 'node:child_process';
import {mkdtemp, readdir, mkdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const build = path.resolve('.build', process.argv.includes('--release') ? 'release' : 'debug');
const directory = await mkdtemp(path.join(tmpdir(), 'autoapprove-original-screen-'));
try {
  const cache = path.resolve('.build/cache/OriginalScreenChecks'); await mkdir(cache, {recursive:true});
  const objects = (await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary = path.join(directory,'OriginalScreenChecks');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/original-terminal-screen-check.swift','-o',binary],{stdio:'inherit'});
  execFileSync(binary,[],{stdio:'inherit',timeout:15000});
} finally { await rm(directory,{recursive:true,force:true}); }
