// Injectable adapter and installer preparation only; never opens a user TTY,
// registers a daemon, sends native events, or requests administrator approval.
import {execFileSync} from 'node:child_process';
import {mkdtemp,readdir,mkdir,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const configuration=process.argv.includes('--release')?'release':'debug';
const build=path.resolve('.build',configuration);
const directory=await mkdtemp(path.join(tmpdir(),'autoapprove-original-tty-adapter-'));
try {
  const cache=path.resolve('.build/cache/OriginalTTYAdapterChecks');await mkdir(cache,{recursive:true});
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name));
  const binary=path.join(directory,'OriginalTTYAdapterChecks');
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library',...(configuration==='debug'?['-D','DEBUG']:[]),'-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',
    ...await coreLinkArguments(build),...objects,'Tests/fixtures/original-tty-adapter-check.swift','-o',binary],{stdio:'inherit'});
  execFileSync(binary,[],{stdio:'inherit',timeout:15000});
} finally {await rm(directory,{recursive:true,force:true});}
