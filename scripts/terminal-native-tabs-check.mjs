// Packages an isolated AppKit fixture; launch with native computer-use tooling.
// It never connects to Terminal, runs a shell in Terminal or requests AX access.
import {execFileSync} from 'node:child_process';
import {mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/terminal-native-tabs-check');
const app=out+'/Native Tabs Check.app',mac=app+'/Contents/MacOS',cache=path.resolve('.build/cache/NativeTabsQA');
await mkdir(mac,{recursive:true});await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-swift-version','5','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/terminal-native-tabs-check.swift','-o',mac+'/NativeTabsCheck'],{stdio:'inherit',timeout:120000});
const xml=value=>value.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
await writeFile(app+'/Contents/Info.plist',`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleName</key><string>Native Tabs Check</string><key>CFBundleIdentifier</key><string>local.autoapprove.native-tabs-check</string><key>CFBundleExecutable</key><string>NativeTabsCheck</string><key>CFBundlePackageType</key><string>APPL</string><key>NativeTabsQAOutput</key><string>${xml(out)}</string></dict></plist>`);
execFileSync('/usr/bin/codesign',['--force','--sign','-',app],{stdio:'inherit'});
console.log(JSON.stringify({app,result:out+'/result.json',realTerminalAccess:false}));
