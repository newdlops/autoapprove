import {execFileSync} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const directory = path.resolve('.runtime/lan-interface-type-check'), cache = path.resolve('.build/cache/LANInterfaceTypeCheck');
await mkdir(directory,{recursive:true,mode:0o700}); await mkdir(cache,{recursive:true});
const binary = path.join(directory,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,
  'Sources/AutoApproveCore/RemoteLANInterfaceTypeCache.swift','Tests/fixtures/lan-interface-type-check.swift','-o',binary],{stdio:'inherit'});
const report = JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:10_000}));
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600}); console.log(JSON.stringify(report));
