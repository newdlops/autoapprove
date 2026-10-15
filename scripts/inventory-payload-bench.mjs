import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const build=path.resolve('.build/release'),out=path.resolve(process.argv.find(arg=>arg.startsWith('--output='))?.slice(9)||'dist/qa/inventory-payload'),cache=path.resolve('.build/cache/InventoryPayloadBench');
await mkdir(out,{recursive:true});await mkdir(cache,{recursive:true});
const binary=path.join(out,'fixture');
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...(await readdir(build+'/AutoApproveCore.build')).filter(name=>name.endsWith('.swift.o')).map(name=>build+'/AutoApproveCore.build/'+name),'Tests/fixtures/inventory-payload-bench.swift','-o',binary],{stdio:'inherit'});
const report=JSON.parse(execFileSync(binary,{encoding:'utf8'}));await writeFile(path.join(out,'comparison.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
