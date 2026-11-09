import {execFileSync} from 'node:child_process';
import {mkdtemp,readdir,rm,mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const build=path.resolve('.build/debug'),directory=await mkdtemp('/private/tmp/aa-lid-update-');
try {
 const cache=path.resolve('.build/cache/UpdateSleepChecks');await mkdir(cache,{recursive:true});
 const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(n=>n.endsWith('.swift.o')).map(n=>path.join(build,'AutoApproveCore.build',n));
 const binary=path.join(directory,'check');
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/lan-update-sleep-check.swift','-o',binary],{stdio:'inherit',timeout:60000});
 execFileSync(binary,[],{stdio:'inherit',timeout:20000});
} finally {await rm(directory,{recursive:true,force:true});}
