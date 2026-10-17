import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
const build=path.resolve('.build/release'),directory=path.resolve('.runtime/process-ancestry-check');
await mkdir(directory,{recursive:true,mode:0o700});const binary=path.join(directory,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ProcessAncestryCheck'),
 '-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(n=>n.endsWith('.swift.o')).map(n=>path.join(build,'AutoApproveCore.build',n)),
 'Tests/fixtures/process-ancestry-check.swift','-o',binary],{stdio:'inherit',timeout:300000});
const report=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:15000}));assert.ok(report.passed>=20);
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report));
