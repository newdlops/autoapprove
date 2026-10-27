// Render the shipping SwiftUI component with inert permission callbacks.
import {execFileSync} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/screen-control-193/native');
await mkdir(out,{recursive:true,mode:0o700});const cache=path.resolve('.build/cache/ScreenControlSettingsPreview');await mkdir(cache,{recursive:true});
const binary=out+'/ScreenControlSettingsPreview';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),
 'Sources/AutoApproveApp/TerminalSharingSettings.swift','Tests/fixtures/screen-control-settings-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
execFileSync(binary,[out],{stdio:'inherit',timeout:20000});
