import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const baseline=process.argv.includes('--baseline'),build=path.resolve(option('build-dir')||'.build/release');
const out=path.resolve(option('output')||'.runtime/terminal-connection-bench/'+(baseline?'baseline':'current'));
await mkdir(out,{recursive:true});const binary=path.join(out,'TerminalConnectionBench');
const cache=path.resolve('.build/release/ModuleCache');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library',...(!baseline?['-D','CONNECTION_OPTIMIZED']:[]),
 '-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
 'Tests/fixtures/terminal-connection-bench.swift','-o',binary],{stdio:'inherit',timeout:300000});
const report=JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:60000,maxBuffer:2_000_000}));
Object.assign(report,{baseline,binarySHA256:createHash('sha256').update(await readFile(binary)).digest('hex')});
await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(report));
