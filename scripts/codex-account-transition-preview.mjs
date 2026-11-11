import {execFileSync} from 'node:child_process';
import {mkdir,copyFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const build=path.resolve('.build',process.argv.includes('--release')?'release':'debug');
const output=path.resolve('dist/qa/codex-account-transition');
await mkdir(output,{recursive:true});
const binary=output+'/AccountTransitionPreview';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AccountPreview'),
 '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),
 'Sources/AutoApproveApp/CodexAccountTransitionSettings.swift','Sources/AutoApproveApp/CodexAutomationHoldView.swift','Tests/fixtures/codex-account-transition-preview.swift','-o',binary],{stdio:'inherit',timeout:120000});
if(!process.argv.includes('--build-only'))execFileSync(binary,[output],{stdio:'inherit',timeout:30000});
const app=output+'/AccountTransitionPreview.app';
await mkdir(app+'/Contents/MacOS',{recursive:true});
await copyFile(binary,app+'/Contents/MacOS/AccountTransitionPreview');
await writeFile(app+'/Contents/Info.plist','<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.autoapprove.qa.accounttransition</string><key>CFBundleName</key><string>AccountTransitionPreview</string><key>CFBundleExecutable</key><string>AccountTransitionPreview</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
console.log(binary);
