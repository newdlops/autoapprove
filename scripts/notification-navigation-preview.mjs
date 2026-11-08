import {execFileSync} from 'node:child_process';
import {mkdir,writeFile,copyFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(option('build')||'.build/release'),root=path.resolve(option('output')||'.runtime/notification-navigation-preview'),binary=root+'/NavigationPreview';
await mkdir(root+'/data',{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/TunnelSettingsPreview'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Sources/AutoApproveApp/TerminalHighlighter.swift','Sources/AutoApproveApp/TerminalNavigator.swift','Sources/AutoApproveApp/NotificationSessionOpener.swift','Sources/AutoApproveApp/QuestionNotifications.swift','Tests/fixtures/notification-navigation-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
for(const [role,name,id] of [['sender','AutoApprove Notification QA','local.autoapprove.highlight-preview'],['receiver','Notification Target QA','local.autoapprove.notification-navigation-host']]) {
 const app=root+'/'+name+'.app';await mkdir(app+'/Contents/MacOS',{recursive:true});await copyFile(binary,app+'/Contents/MacOS/NavigationPreview');
 await writeFile(app+'/Contents/Info.plist',`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>${id}</string><key>CFBundleExecutable</key><string>NavigationPreview</string><key>CFBundleName</key><string>${name}</string><key>CFBundlePackageType</key><string>APPL</string><key>NSHighResolutionCapable</key><true/><key>NavigationQARole</key><string>${role}</string><key>NavigationQAData</key><string>${root}/data</string></dict></plist>`);
 execFileSync('/usr/bin/codesign',['--force','--sign','-',app],{stdio:'inherit'});
 console.log(app);
}
