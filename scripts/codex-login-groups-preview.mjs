import {execFileSync} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const build=path.resolve('.build/debug'),output=path.resolve('dist/qa/codex-login-groups');
const app=output+'/CodexAccountsPreview.app',binary=app+'/Contents/MacOS/CodexAccountsPreview';
await mkdir(path.dirname(binary),{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/LoginGroupPreview'),
 '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),
 'Sources/AutoApproveApp/CodexAccountsWindow.swift','Sources/AutoApproveApp/CodexLoginSettings.swift',
 'Sources/AutoApproveApp/CodexAccountTransitionSettings.swift','Sources/AutoApproveApp/WindowViewUpdates.swift',
 'Tests/fixtures/AgentAccountFixture.swift','Tests/fixtures/codex-login-groups-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
await writeFile(app+'/Contents/Info.plist','<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.autoapprove.qa.codexaccounts</string><key>CFBundleName</key><string>CodexAccountsPreview</string><key>CFBundleExecutable</key><string>CodexAccountsPreview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>');
execFileSync('/usr/bin/codesign',['--force','--sign','-',app],{stdio:'inherit'});
console.log(app);
