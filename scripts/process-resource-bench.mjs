import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,readdir,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const argument=(name,fallback)=>process.argv.find(value=>value.startsWith(`--${name}=`))?.slice(name.length+3)??fallback;
const label=argument('label','current'),build=path.resolve(argument('core-build','.build/release'));
assert.match(label,/^[a-z0-9-]+$/);
const trials=Number(argument('trials','3'));assert.ok(Number.isInteger(trials)&&trials>=1&&trials<=6);
const directory=path.resolve('.runtime/process-resource-bench',label);await mkdir(directory,{recursive:true,mode:0o700});
const binary=path.join(directory,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ProcessResourceBench'),
  '-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
  ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(name=>name.endsWith('.swift.o')).map(name=>path.join(build,'AutoApproveCore.build',name)),
  'Tests/fixtures/process-resource-bench.swift','-o',binary],{stdio:'inherit'});
if(process.argv.includes('--compile-only')) { console.log(binary); process.exit(0); }
const reports=[];
for(let trial=0;trial<trials;trial++)reports.push(JSON.parse(execFileSync(binary,[],{encoding:'utf8',timeout:60000})));
const median=values=>values.sort((a,b)=>a-b)[Math.floor(values.length/2)];
const phases=reports[0].phases.map((phase,index)=>{
  const rows=reports.map(report=>report.phases[index]);
  return {mode:phase.mode,iterations:phase.iterations,
    ...Object.fromEntries(['wallSeconds','selfCPUSeconds','childCPUSeconds','combinedCPUSeconds','medianMS','p95MS'].map(key=>[key,median(rows.map(row=>row[key]))])),
    recordCountSumRange:[Math.min(...rows.map(row=>row.recordCountSum)),Math.max(...rows.map(row=>row.recordCountSum))]};
});
const report={label,trials,phases,peakResidentBytes:median(reports.map(report=>report.peakResidentBytes)),
  binarySHA256:createHash('sha256').update(await readFile(binary)).digest('hex'),reports,
  scope:'Current Mac process table; real linked release Core; self plus reaped-child CPU. No source records, arguments, environment or terminal content emitted. Not total installed-app or fixed-data comparison.'};
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
const {reports:raw,...summary}=report;console.log(JSON.stringify(summary,null,2));
