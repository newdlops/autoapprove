import {coreLinkArguments} from './swift-core-link.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir,readdir,readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
import assert from 'node:assert/strict';
const label=process.argv.find(a=>a.startsWith('--label='))?.slice(8)||'current';assert.match(label,/^[a-z0-9-]+$/);
const directory=path.resolve('.runtime/project-label-bench',label),build=path.resolve('.build/release'),binary=path.join(directory,'check');
await mkdir(directory,{recursive:true,mode:0o700});
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ProjectLabelBench'),
 '-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),
 ...(await readdir(path.join(build,'AutoApproveCore.build'))).filter(n=>n.endsWith('.swift.o')).map(n=>path.join(build,'AutoApproveCore.build',n)),
 'Tests/fixtures/project-label-bench.swift','-o',binary],{stdio:'inherit',timeout:300000});
const reports=[];
for(let trial=0;trial<3;trial++){
 const home=await mkdtemp('/private/tmp/aa-project-label-');
 try{reports.push(JSON.parse(execFileSync(binary,[home],{encoding:'utf8',timeout:60000})));}
 finally{await rm(home,{recursive:true,force:true});}
}
assert.ok(reports.every(r=>r.pathsChecked>=350&&r.workloads.length===5));
const report={label,sourceSHA256:createHash('sha256').update(await readFile('Sources/AutoApproveCore/Models.swift')).digest('hex'),
 fixtureSHA256:createHash('sha256').update(await readFile('Tests/fixtures/project-label-bench.swift')).digest('hex'),reports};
await writeFile(path.join(directory,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
console.log(JSON.stringify(report));
