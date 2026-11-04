import {execFileSync} from 'node:child_process';
import {mkdir} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(option('build')||'.build/release'),out=path.resolve(option('output')||'.runtime/notification-navigation-check');
await mkdir(out,{recursive:true});const binary=out+'/NotificationNavigationCheck';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/TunnelSettingsPreview'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Sources/AutoApproveApp/TerminalHighlighter.swift','Sources/AutoApproveApp/TerminalNavigator.swift','Sources/AutoApproveApp/NotificationSessionOpener.swift','Tests/fixtures/notification-navigation-check.swift','-o',binary],{stdio:'inherit',timeout:180000});
execFileSync(binary,[],{stdio:'inherit',timeout:30000});
