import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,cp,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/cloudflare-https/release'),app=path.resolve(process.argv[2]||'dist/cf-https-release-188/AutoApprove.app');
const root=await mkdtemp('/private/tmp/aa-worker-package-'),relocated=root+'/Relocated.app',mac=relocated+'/Contents/MacOS',resources=relocated+'/Contents/Resources';
try {
 const relative='AutoApprove_AutoApproveCore.bundle/CloudflareRelay/relay.mjs';
 assert.deepEqual(await readFile(app+'/Contents/Resources/'+relative),await readFile('Sources/AutoApproveCore/Resources/CloudflareRelay/relay.mjs'));
 await mkdir(mac,{recursive:true});await mkdir(resources);
 await cp(app+'/Contents/Resources/AutoApprove_AutoApproveCore.bundle',resources+'/AutoApprove_AutoApproveCore.bundle',{recursive:true});
 await writeFile(relocated+'/Contents/Info.plist','<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.autoapprove.worker-package-check</string><key>CFBundleExecutable</key><string>WorkerPackageCheck</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
 const cache=path.resolve('.build/cache/WorkerPackage');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/AutoApproveCoreTests/CloudflareFixture.swift','Tests/AutoApproveCoreTests/WorkersFixture.swift','Tests/fixtures/cloudflare-worker-package-check.swift','-o',mac+'/WorkerPackageCheck'],{stdio:'inherit',timeout:300000});
 const result=execFileSync(mac+'/WorkerPackageCheck',[],{encoding:'utf8',timeout:20000});assert.match(result,/PASS:/);console.log(result.trim());
} finally {await rm(root,{recursive:true,force:true});}
