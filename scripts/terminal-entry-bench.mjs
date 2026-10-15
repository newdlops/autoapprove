import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const label=option('label')||'current',target=option('target');
assert.match(label,/^[a-z0-9-]+$/);assert.ok(target,'Pass a private, explicitly selected enrolled session JSON using --target');
const build=path.resolve('.build/release'),out=path.resolve(option('output')||'.runtime/terminal-entry-bench/'+label);
await mkdir(out,{recursive:true});const binary=path.join(out,'TerminalEntryBench');
// Reuse the release SDK cache instead of rebuilding AppKit imports per probe.
const cache=path.join(build,'ModuleCache');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
 'Tests/fixtures/terminal-entry-bench.swift','-o',binary],{stdio:'inherit',timeout:300000});
const result=JSON.parse(execFileSync(binary,[path.resolve(target),...(process.argv.includes('--cold-text')?['--cold-text']:[])],{encoding:'utf8',timeout:45000}));
const median=key=>result.samples.map(sample=>sample[key]).sort((a,b)=>a-b)[Math.floor(result.samples.length/2)];
Object.assign(result,{label,medianMS:median('seconds')*1000,medianChildCPUMS:median('childCPUSeconds')*1000,binarySHA256:createHash('sha256').update(await readFile(binary)).digest('hex')});
await writeFile(path.join(out,'report.json'),JSON.stringify(result,null,2)+'\n',{mode:0o600});console.log(JSON.stringify(result));
