import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,mkdtemp,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/transport-stability-194/input-cost');
await mkdir(out,{recursive:true,mode:0o700});const root=await mkdtemp('/private/tmp/aa-input-cost-'),cache=path.resolve('.build/cache/ScreenInputCost');await mkdir(cache,{recursive:true});
try{
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/ScreenControlFixture.swift','Tests/fixtures/screen-input-cost.swift','-o',root+'/Cost'],{stdio:'inherit',timeout:180000});
 const result=JSON.parse(execFileSync(root+'/Cost',[root],{encoding:'utf8',timeout:15000}));
 assert.equal(result.inputs,2400);assert.equal(result.constructedEvents,result.inputs);assert.equal(result.userDesktopPosts,0);
 if(option('expect-target-reads'))assert.equal(result.targetReadsPerInput,Number(option('expect-target-reads')));
 const report={passed:true,...result,scope:'Production control path with a synthetic target and nonposting Quartz sink; counts fresh target validations, not real window-query CPU or public input latency'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{await rm(root,{recursive:true,force:true});}
