import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,symlink,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/cloudflare-https/release'),dependencies=path.resolve(option('dependencies')||'.runtime/cf-workers-188/dependencies');
const root=await mkdtemp('/private/tmp/aa-worker-oauth-');
try {
 const tools=root+'/worker-tools',prefix=tools+'/wrangler-4.152.0';await mkdir(prefix,{recursive:true,mode:0o700});
 await symlink(dependencies+'/node_modules',prefix+'/node_modules');
 await writeFile(tools+'/ready.json',JSON.stringify({node:process.execPath,cli:prefix+'/node_modules/wrangler/wrangler-dist/cli.js',version:'4.152.0',integrity:'sha512-lmXTF1sCDEqBaEMpreGczvg/x3AIh1d/qxc4BN7utQ4jEDwdA4YG0L6kr3ev0TtVLHRb6QLySNAOAunwn+dHeA=='}),{mode:0o600});
 const cache=path.resolve('.build/cache/WorkerAuth');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/cloudflare-worker-auth-check.swift','-o',root+'/AuthCheck'],{stdio:'inherit',timeout:300000});
 const result=execFileSync(root+'/AuthCheck',[root],{encoding:'utf8',timeout:30000});assert.match(result,/PASS:/);assert.ok(!result.includes('SyntheticOAuthToken'));console.log(result.trim());
} finally {await rm(root,{recursive:true,force:true});}
