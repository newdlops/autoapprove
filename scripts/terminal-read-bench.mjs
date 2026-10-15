import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const label=process.argv.find(value=>value.startsWith('--label='))?.slice(8)||'current';
assert.match(label,/^[a-z0-9-]+$/);
const targets=process.argv.find(value=>value.startsWith('--targets='))?.slice(10);
assert.ok(targets,'Pass a private JSON file of explicitly selected enrolled TTYs with --targets=');
assert.ok((JSON.parse(await readFile(targets,'utf8'))).every(tty=>typeof tty==='string'&&tty.startsWith('/dev/')));
const build=path.resolve('.build/release'),output=path.resolve('.runtime/terminal-read-bench',label);
await mkdir(output,{recursive:true});
const binary=path.join(output,'fixture');
const cache=path.resolve('.build/cache/TerminalReadBench');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,
 '-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
 'Tests/fixtures/terminal-read-bench.swift','-o',binary],{stdio:'inherit'});
const report=JSON.parse(execFileSync(binary,[path.resolve(targets)],{encoding:'utf8',timeout:60000}));
const median=values=>values.sort((a,b)=>a-b)[Math.floor(values.length/2)];
report.label=label;
report.medians=Object.fromEntries(['seconds','selfCPUSeconds','childCPUSeconds'].map(key=>[key,median(report.samples.map(sample=>sample[key]))]));
await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
