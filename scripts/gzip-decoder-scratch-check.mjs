import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {coreLinkArguments} from './swift-core-link.mjs';

// Build the matching Core first. A preserved --baseline-build and matching
// --baseline-source-root enable state/error and live-heap comparisons.
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fixture=path.resolve(option('fixture','Tests/fixtures/gzip-decoder-scratch-check.swift'));
const sharedFixture=path.resolve(option('shared-fixture','Tests/fixtures/gzip-scratch-check.swift'));
const gzipScript=path.resolve(option('gzip-script','scripts/gzip-scratch-check.mjs'));
const variants={candidate:{build:path.resolve(option('build','.build/release')),source:path.resolve(option('source-root','.'))}};
if(option('baseline-build')){assert.ok(option('baseline-source-root'),'Supply source matching the baseline build');variants.baseline={build:path.resolve(option('baseline-build')),source:path.resolve(option('baseline-source-root'))}}
const parent=path.resolve('.runtime/gzip-decoder-scratch-check');fs.mkdirSync(parent,{recursive:true,mode:0o700});const out=fs.mkdtempSync(parent+'/run-');
const cache=path.resolve(option('cache',out+'/module-cache')),hashes={[fixture]:sha(fixture),[sharedFixture]:sha(sharedFixture),[gzipScript]:sha(gzipScript),[import.meta.filename]:sha(import.meta.filename)};
const verify=()=>{for(const[file,digest]of Object.entries(hashes))assert.equal(sha(file),digest,file)};
const save=(name,value)=>fs.writeFileSync(out+'/'+name,JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});

// Reuse the existing synthetic corpus generator. This runs without an encoder
// baseline: the comparison below concerns the decoder and uses identical wire
// bytes for both variants, including when the encoder itself is unchanged.
verify();
const generated=JSON.parse(execFileSync(process.execPath,[gzipScript,'--build='+variants.candidate.build,'--source-root='+variants.candidate.source,'--fixture='+sharedFixture,'--cache='+cache],{encoding:'utf8',timeout:300000,maxBuffer:1048576}));
assert.equal(generated.passed,true);const corpusDirectory=path.dirname(generated.report),corpus=corpusDirectory+'/corpus.bin';
hashes[corpus]=sha(corpus);hashes[generated.report]=sha(generated.report);
const references=Object.fromEntries([1,2,6,9].map(level=>[level,corpusDirectory+'/candidate-level'+level+'.bin']));
for(const file of Object.values(references))hashes[file]=sha(file);

const marker='@main enum GzipScopedScratchCheck',original=fs.readFileSync(sharedFixture,'utf8');assert.equal(original.split(marker).length,2);
const helper=out+'/helper.swift';fs.writeFileSync(helper,original.replace(marker,'enum GzipScopedScratchCheck'),{flag:'wx',mode:0o600});hashes[helper]=sha(helper);
for(const[label,value]of Object.entries(variants)){
 const objects=fs.readdirSync(value.build+'/AutoApproveCore.build').filter(name=>name.endsWith('.swift.o')).sort().map(name=>value.build+'/AutoApproveCore.build/'+name),links=await coreLinkArguments(value.build);assert.ok(objects.length>0,'Build the matching release Core first');
 for(const file of [value.build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o')),...['RemoteGzipDecoder.swift','RemoteGzipEncoder.swift'].map(name=>value.source+'/Sources/AutoApproveCore/'+name)])hashes[file]=sha(file);
 value.binary=out+'/'+label;value.coreObjects=objects.length;value.moduleSHA256=sha(value.build+'/Modules/AutoApproveCore.swiftmodule');verify();
 execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',value.build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3','-lz',...links,...objects,helper,fixture,'-o',value.binary],{stdio:'inherit',timeout:300000});hashes[value.binary]=sha(value.binary);verify();
}
const environment={...process.env};delete environment.SWIFT_DETERMINISTIC_HASHING;let sequence=0;
function run(label,args,input){verify();const text=execFileSync(variants[label].binary,args,{input,encoding:'utf8',env:environment,timeout:120000,maxBuffer:4*1048576});verify();const rows=text.trim().split('\n').map(JSON.parse);save(label+'-'+args[0]+'-'+(++sequence)+'.json',rows);return rows}
const cases={},stacks={},memory={},smokes={};
for(const label of Object.keys(variants)){
 cases[label]=[];
 for(const[level,file]of Object.entries(references)){const value=run(label,['cases',corpus,file])[0];assert.equal(value.passed,true);assert.equal(value.events,527);assert.equal(value.fragmentedCases.length,44);cases[label].push({level:Number(level),...value})}
 stacks[label]=run(label,['stack'])[0];assert.equal(stacks[label].passed,true);
 memory[label]=run(label,['memory-batch','0']);assert.equal(memory[label].length,10);for(const row of memory[label]){assert.equal(row.passed,true);assert.ok(row.afterReleaseGrowth<=65536)}
 const modes=['heartbeat','metadata','ansi','patch','opaque32768','mixed'],requests=modes.map(mode=>({id:'public/'+mode,mode,iterations:16}));
 const rows=run(label,['bench'],requests.concat({command:'stop'}).map(value=>JSON.stringify(value)+'\n').join(''));assert.equal(rows.shift().compressedFramesPreparedOutsideWindow,true);assert.equal(rows.length,6);
 smokes[label]=rows.map((row,index)=>{assert.equal(row.mode,modes[index]);return{mode:row.mode,checksum:row.checksum,decodedBytes:row.decodedBytes,compressedBytes:row.compressedBytes,decodeReads:row.decodeReads}});
}
const savedHeap=[];
if(variants.baseline){
 assert.deepEqual(cases.candidate,cases.baseline);assert.deepEqual(smokes.candidate,smokes.baseline);
 for(let index=0;index<memory.candidate.length;index++){
  const before=memory.baseline[index],after=memory.candidate[index];assert.equal(before.level,after.level);assert.equal(before.count,after.count);assert.equal(before.encodedBytes,after.encodedBytes);const saved=before.retainedHeap-after.retainedHeap;
  if(after.count>=8)assert.ok(saved>=after.count*32000);else assert.ok(after.retainedHeap<=before.retainedHeap+4096);
  savedHeap.push({level:after.level,count:after.count,saved,savedPerStream:after.count?saved/after.count:null});
 }
}
verify();save('report.json',{passed:true,actualCompiledCore:true,groups:16,events:2108,fragmentedCases:176,sameWireInputs:true,baselineComparisonRun:!!variants.baseline,exactStatesAndErrorsCompared:!!variants.baseline,cases,stacks,memory,savedHeap,smokes,variants,inputs:hashes,corpusReport:generated.report,memoryScope:'Live malloc heap held by drained decoders awaiting more input;not whole-app RSS.',noRuntimeSpeedClaim:true,originalTerminalActions:0,realPowerCommands:0});
console.log(JSON.stringify({passed:true,groups:16,events:2108,fragmentedCases:176,baselineComparisonRun:!!variants.baseline,report:out+'/report.json'}));
