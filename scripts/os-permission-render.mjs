import {execFileSync} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const opt=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(opt('build')||'.build/network-stability/release'),out=path.resolve(opt('output')||'.runtime/os-permission-render');
await mkdir(out,{recursive:true});const cache=path.resolve('.build/cache/OSPermissionRender');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Sources/AutoApproveApp/OSPermissionPolicyView.swift','Tests/fixtures/os-permission-render.swift','-o',out+'/PermissionRender'],{stdio:'inherit',timeout:180000});
console.log(execFileSync(out+'/PermissionRender',[out],{encoding:'utf8',timeout:30000}));
