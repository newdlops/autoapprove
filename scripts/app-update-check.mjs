// One signed web-disabled automatic update, plus the native current/error views.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,readFile,writeFile,cp,copyFile,readdir} from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
import {signApp} from './sign-app.mjs';
const root=path.resolve(process.argv[2]||'.runtime/app-update-check'),build=path.resolve('.build/debug');
await mkdir(root,{recursive:true,mode:0o700});
const version=JSON.parse(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/web-version.json'));
const previous={...version,version:'0.2.298',build:325};
const children=[],directories=[];
const readJSON=async file=>JSON.parse(await readFile(file,'utf8'));
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,ms=120000){const deadline=Date.now()+ms;let last;while(Date.now()<deadline){try{const result=await test();if(result)return result;}catch(e){last=e;}await wait(200);}throw Error(label+': '+(last?.message||'timed out'));}
try {
 const manager=root+'/manager',cache=path.resolve('.build/cache/AppUpdateManager');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Sources/AutoApproveApp/AppInformation.swift','Sources/AutoApproveApp/AppUpdatesView.swift','Tests/fixtures/app-update-manager.swift','-o',manager],{stdio:'inherit',timeout:180000});
 async function app(name,release,settings={}) {
  const dir=root+'/'+name,app=dir+'/AutoApprove.app';await mkdir(dir,{recursive:true});directories.push(dir);
  await cp('/Applications/AutoApprove.app',app,{recursive:true,filter:src=>!src.includes('/CodexRuntime')});
  await copyFile(manager,app+'/Contents/MacOS/AutoApproveApp');await copyFile(build+'/autoapprove',app+'/Contents/MacOS/autoapprove');
  execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleShortVersionString '+release.version,app+'/Contents/Info.plist']);
  execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleVersion '+release.build,app+'/Contents/Info.plist']);
  await writeFile(app+'/Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json',JSON.stringify(release));
  await signApp(app,{allowProvisioning:false});
  await writeFile(dir+'/fixture-config.json',JSON.stringify({home:dir+'/profile',...settings}));
  return {dir,app};
 }
 const source=await app('source',version),archive=root+'/update.zip';
 execFileSync('/usr/bin/ditto',['-c','-k','--norsrc','--keepParent',source.app,archive]);
 const bytes=await readFile(archive),name=`AutoApprove-${version.version}-build${version.build}-macOS-${process.arch}.zip`,metadata=root+'/release.json';
 await writeFile(metadata,JSON.stringify({tag_name:'v'+version.version,draft:false,prerelease:false,assets:[{name,size:bytes.length,digest:'sha256:'+createHash('sha256').update(bytes).digest('hex'),browser_download_url:`https://github.com/newdlops/autoapprove/releases/download/v${version.version}/${name}`}]}));
 function start(app){const child=spawn(app.app+'/Contents/MacOS/AutoApproveApp',[],{stdio:['ignore','ignore','inherit']});children.push(child);return child;}
 const target=await app('recipient',previous,{archive,metadata});
 await mkdir(target.dir+'/profile',{recursive:true});await writeFile(target.dir+'/profile/preserved.txt','keep settings');
 const old=start(target);
 const state=await until(async()=>{const s=await readJSON(target.dir+'/fixture-state.json');assert.equal(s.web,false);if(s.phase==='failed')throw Error(s.detail);return s.release.version===version.version?s:null;},'Automatic replacement without web listener');
 assert.notEqual(state.pid,old.pid);
 await until(()=>old.exitCode===0,'Cooperative old-manager exit');
 await until(async()=>!(await readdir(target.dir)).some(name=>name.startsWith('.AutoApprove-backup-')),'Private-socket health confirmation');
 assert.equal(await readFile(target.dir+'/profile/preserved.txt','utf8'),'keep settings');
 for(const [name,failure]of [['current',false],['error',true]]) {
  const preview=await app(name,version,{metadata,render:true,failure});const child=start(preview);
  await until(()=>child.exitCode===0,'Native '+name+' render');assert.ok((await readFile(preview.dir+'/update.png')).length>1000);
 }
 console.log(JSON.stringify({passed:true,release:version,checks:['automatic signed download, replace and restart with web disabled','private-socket health and backup cleanup','profile files preserved','native current/error views rendered'],userTerminalInputs:0}));
}finally{
 for(const dir of directories)await writeFile(dir+'/qa-stop','stop');
 await wait(500);for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');
}
