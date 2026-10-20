import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
const build=path.resolve('.build/release'),root=path.resolve('.runtime/native-neighbor-check');
await mkdir(root,{recursive:true,mode:0o700});
const description=JSON.parse(await readFile(build+'/description.json','utf8'));
const core=Object.values(description.swiftCommands).find(command=>command.moduleName==='AutoApproveCore');
function argument(flag) {
 const index=core?.otherArguments.indexOf(flag);
 if(index==null||index<0||!core.otherArguments[index+1])throw Error('Missing Core compiler argument '+flag);
 return core.otherArguments[index+1];
}
// Match the linked Core target and reuse SwiftPM's SDK modules. A separate
// cache rebuilds the same framework interfaces before checking the fixture.
const compilerArguments=['-target',argument('-target'),'-swift-version',argument('-swift-version'),'-module-cache-path',argument('-module-cache-path')];
const source='Sources/AutoApproveCore/NativeNeighborCache.swift',fixture='Tests/fixtures/native-neighbor-check.swift';
const objects=(await readdir(build+'/AutoApproveCore.build')).filter(n=>n.endsWith('.swift.o')).sort();
const binary=root+'/check';
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-DCORE_NEIGHBOR_CHECK',...compilerArguments,
 '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects.map(n=>build+'/AutoApproveCore.build/'+n),source,fixture,'-o',binary],{stdio:'inherit',timeout:240000});
const live=process.argv.includes('--live');
const result=JSON.parse(execFileSync(binary,live?['--live']:[],{encoding:'utf8',timeout:30000}));
const sha=v=>createHash('sha256').update(v).digest('hex');
const report={...result,sourceSHA256:sha(await readFile(source)),fixtureSHA256:sha(await readFile(fixture)),
 binarySHA256:sha(await readFile(binary)),coreModuleSHA256:sha(await readFile(build+'/Modules/AutoApproveCore.swiftmodule')),compilerArguments,
 coreObjects:Object.fromEntries(await Promise.all(objects.map(async n=>[n,sha(await readFile(build+'/AutoApproveCore.build/'+n))]))),
 scope:'Production native neighbor parser/query with synthetic boundary cases. --live additionally compares three bracketed passive snapshots and actual optimized Core against arp -an. No original input, probes or network/security changes.'};
await writeFile(root+'/'+(live?'live-report.json':'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({...report,coreObjects:undefined}));
