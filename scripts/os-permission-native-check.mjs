// Launches our own fake permission app and the production policy view/AX provider.
// Default mode only acts on the injected test owner; production checks reject it.
// --real-tcc requires explicit consent and uses production Apple owner validation.
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,cp,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
import {signApp} from './sign-app.mjs';
const opt=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(opt('build')||'.build/network-stability/release'),out=path.resolve(opt('output')||'.runtime/os-permission-native');
const realTCC=process.argv.includes('--real-tcc'),prepareReal=process.argv.includes('--prepare-real-tcc');
if(realTCC&&opt('consent')!=='qa-automation')throw Error('Actual TCC verification requires explicit consent for the isolated QA automation pair');
await mkdir(out,{recursive:true,mode:0o700});const cache=path.resolve('.build/cache/OSPermissionNative');await mkdir(cache,{recursive:true});
const target=out+'/AutoApprove OS Dialog QA.app';await mkdir(target+'/Contents/MacOS',{recursive:true});
await writeFile(target+'/Contents/Info.plist','<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.autoapprove.permission-qa-target</string><key>CFBundleName</key><string>AutoApprove OS Dialog QA</string><key>CFBundleExecutable</key><string>PermissionTarget</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>');
execFileSync('/usr/libexec/PlistBuddy',['-c','Add :NSAppleEventsUsageDescription string 동의한 격리 QA 앱의 이름 확인에 필요한 OS 자동화 권한만 검사합니다.',target+'/Contents/Info.plist']);
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'Tests/fixtures/os-permission-native-target.swift','-o',target+'/Contents/MacOS/PermissionTarget'],{stdio:'inherit',timeout:120000});
execFileSync('/usr/bin/codesign',['--force','--sign','-',target],{stdio:'inherit'});
if(realTCC||prepareReal){const receiver=out+'/AutoApprove OS Event Target QA.app';await cp(target,receiver,{recursive:true});execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleIdentifier local.autoapprove.permission-qa-event-target',receiver+'/Contents/Info.plist']);execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleName AutoApprove OS Event Target QA',receiver+'/Contents/Info.plist']);execFileSync('/usr/bin/codesign',['--force','--sign','-',receiver],{stdio:'inherit'});}
const app=out+'/AutoApprove Permission QA.app';await cp(path.resolve(opt('app')||'/Applications/AutoApprove.app'),app,{recursive:true,errorOnExist:true,force:false});
execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleName AutoApprove Permission QA',app+'/Contents/Info.plist']);
try{execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleDisplayName AutoApprove Permission QA',app+'/Contents/Info.plist']);}catch{execFileSync('/usr/libexec/PlistBuddy',['-c','Add :CFBundleDisplayName string AutoApprove Permission QA',app+'/Contents/Info.plist']);}
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Sources/AutoApproveApp/OSPermissionPolicyView.swift','Tests/fixtures/os-permission-native-qa.swift','-o',app+'/Contents/MacOS/AutoApproveApp'],{stdio:'inherit',timeout:180000});
await signApp(app,{allowProvisioning:false});
if(prepareReal){console.log('Prepared opt-in TCC QA. No apps launched and no OS permissions requested.');process.exit(0);}
const child=spawn(app+'/Contents/MacOS/AutoApproveApp',[out,target,...(realTCC?['--real-tcc']:[])],{stdio:'inherit'});
const stop=()=>{if(child.exitCode===null)child.kill();};process.on('SIGTERM',stop);process.on('SIGINT',stop);
console.log('Native permission QA runs until normal native Quit; fixture/report directory: '+out);
await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>code===0||signal?resolve():reject(Error('Native permission QA exit '+code)));});
