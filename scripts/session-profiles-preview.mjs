// Own GUI fixture: production views/controller; synthetic files, IDs and launcher.
import {execFileSync} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/session-profiles-preview');
const app=out+'/AutoApprove Profiles QA.app',mac=app+'/Contents/MacOS',cache=path.resolve('.build/cache/TunnelSettingsPreview');
await mkdir(mac,{recursive:true});await mkdir(cache,{recursive:true});await mkdir(out+'/data',{recursive:true,mode:0o700});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Sources/AutoApproveApp/SessionProfilesController.swift','Sources/AutoApproveApp/SessionProfilesWindow.swift','Tests/fixtures/session-profiles-preview.swift','-o',mac+'/ProfilesQA'],{stdio:'inherit',timeout:120000});
const xml=v=>v.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
await writeFile(app+'/Contents/Info.plist',`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>AutoApprove Profiles QA</string><key>CFBundleIdentifier</key><string>local.autoapprove.profiles-qa</string><key>CFBundleExecutable</key><string>ProfilesQA</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>ProfileQADataDirectory</key><string>${xml(out+'/data')}</string></dict></plist>`);
execFileSync('/usr/bin/codesign',['--force','--sign','-',app],{stdio:'inherit'});
console.log(JSON.stringify({app,syntheticFiles:true,productionViews:true,realTerminalLauncher:false}));
