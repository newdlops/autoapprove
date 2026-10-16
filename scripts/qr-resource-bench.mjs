import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
const argument=(name,fallback)=>process.argv.find(value=>value.startsWith(`--${name}=`))?.slice(name.length+3)??fallback;
const legacy=process.argv.includes('--legacy'),label=argument('label',legacy?'legacy':'current');assert.match(label,/^[a-z0-9-]+$/);
const directory=path.resolve('.runtime/qr-resource-bench',label);await mkdir(directory,{recursive:true,mode:0o700});
const binary=path.join(directory,'check');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/QRResourceBench'),
 'Sources/AutoApproveApp/QRCodeImageCache.swift','Tests/fixtures/qr-resource-bench.swift','-o',binary],{stdio:'inherit'});
if(process.argv.includes('--compile-only')) { console.log(binary);process.exit(0); }
const reports=[];
for(let trial=0;trial<3;trial++)reports.push(JSON.parse(execFileSync(binary,legacy?['--legacy']:[],{encoding:'utf8',timeout:60000})));
for(const report of reports)assert.deepEqual(report.verificationAfterMeasurement,{pixelParity:true,decodedURLs:2,changedURL:true,singleImageRetention:true,sameURLGenerationsFor101Requests:1,failedGenerationClearsOldImage:true});
const median=values=>values.sort((a,b)=>a-b)[Math.floor(values.length/2)];
const report={label,legacy,trials:reports.length,repeatedRenders:100,
 ...Object.fromEntries(['firstCPUSeconds','repeatCPUSeconds','firstWallSeconds','repeatWallSeconds','footprintDeltaBytes','footprintBytes','peakResidentBytes'].map(key=>[key,median(reports.map(row=>row[key]))])),
 verification:reports[0].verificationAfterMeasurement,binarySHA256:createHash('sha256').update(await readFile(binary)).digest('hex'),reports,
 scope:'Standalone actual production QR cache versus v108 rendering;3fresh processes. Memory saved before independent decoding/reference rendering. Not total app or actual settings-window savings.'};
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
const {reports:raw,...summary}=report;console.log(JSON.stringify(summary,null,2));
