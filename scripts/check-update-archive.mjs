import {execFileSync} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
if(process.argv.length!==3)throw Error('Expected update ZIP');
const build=path.resolve('.build/release'),directory=path.resolve('.build/qa/update-archive');
await mkdir(directory,{recursive:true});
const binary=path.join(directory,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',directory,
 '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',
 ...await coreLinkArguments(build),...await coreSwiftObjects(build),
 'Tests/fixtures/lan-update-archive-check.swift','-o',binary],{stdio:'inherit'});
execFileSync(binary,[path.resolve(process.argv[2])],{stdio:'inherit'});
