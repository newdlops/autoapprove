import {execFileSync} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const mode=process.argv.includes('--move') ? 'move':process.argv.includes('--coordinator') ? 'coordinator':'import';
const fixture=mode==='move'?'codex-session-move-live':'codex-selected-'+mode;
const build=path.resolve('.build/debug'),output=path.resolve('dist/qa/codex-selected-'+mode);
await mkdir(path.dirname(output),{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/SelectedImport'),
 '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',
 ...await coreLinkArguments(build),...await coreSwiftObjects(build),
 'Tests/fixtures/'+fixture+'.swift','-o',output],{stdio:'inherit',timeout:180000});
console.log(output);
