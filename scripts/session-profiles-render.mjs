import {execFileSync} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/session-profiles-render');
await mkdir(out,{recursive:true});const cache=path.resolve('.build/cache/TunnelSettingsPreview'),binary=out+'/SessionProfilesRender';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Sources/AutoApproveApp/SessionProfilesController.swift','Sources/AutoApproveApp/SessionProfilesWindow.swift','Tests/fixtures/session-profiles-render.swift','-o',binary],{stdio:'inherit',timeout:120000});
console.log(execFileSync(binary,[out],{encoding:'utf8',timeout:30000}).trim());
