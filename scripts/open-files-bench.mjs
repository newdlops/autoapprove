import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const option=name=>process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3);
const out=path.resolve(option('output')||'dist/qa/open-files'),build=path.resolve(option('core-build')||'.build/release');
await mkdir(out,{recursive:true});const cache=path.resolve('.build/cache/OpenFilesBench');await mkdir(cache,{recursive:true});
const binary=path.join(out,'OpenFilesBench');
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...(await readdir(build+'/AutoApproveCore.build')).filter(name=>name.endsWith('.swift.o')).map(name=>build+'/AutoApproveCore.build/'+name),...(process.argv.includes('--prototype')?['Sources/AutoApproveCore/ProcessOpenFiles.swift']:[]),'Tests/fixtures/open-files-bench.swift','-o',binary],{stdio:'inherit',timeout:300000});
for(const live of [false,...(process.argv.includes('--live')?[true]:[])]){
 const result=JSON.parse(execFileSync(binary,live?['--live']:[],{encoding:'utf8',timeout:60000}));
 await writeFile(path.join(out,live?'live-metadata.json':'samples.json'),JSON.stringify(result,null,2)+'\n');
 if(live){console.log(JSON.stringify(result));continue;}
 const median=a=>[...a].sort((a,b)=>a-b)[Math.floor(a.length/2)];
 const metrics=Object.fromEntries(['legacy','native'].map(mode=>{const rows=result.samples.filter(row=>row.mode===mode);return [mode,{wallMS:median(rows.map(row=>row.wallMS)),selfCPUSeconds:median(rows.map(row=>row.selfCPUSeconds)),childCPUSeconds:median(rows.map(row=>row.childCPUSeconds)),totalCPUSeconds:median(rows.map(row=>row.selfCPUSeconds+row.childCPUSeconds)),commandLaunches:rows.reduce((sum,row)=>sum+row.commandLaunches,0)}];}));
 await writeFile(path.join(out,'summary.json'),JSON.stringify({files:result.files,metrics,scope:result.scope},null,2)+'\n');console.log(JSON.stringify({files:result.files,metrics,scope:result.scope}));
}
