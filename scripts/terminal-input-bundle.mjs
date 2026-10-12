// Build native ServiceManagement installation metadata with the actual public
// publisher certificate. Called during packaging, before the helper is signed.
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {chmodSync,copyFileSync,mkdirSync,mkdtempSync,readFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';

export function prepareTerminalInputBundle(app, configuration, version) {
  const service='local.autoapprove.tty-input';
  const directory=mkdtempSync(path.join(tmpdir(),'autoapprove-tty-bundle-'));
  const run=(binary,args,input)=>execFileSync(binary,args,{input,stdio:['pipe','pipe','pipe'],timeout:30000});
  const plist=file=>JSON.parse(run('/usr/bin/plutil',['-convert','json','-o','-',file]));
  const writePlist=(file,value)=>run('/usr/bin/plutil',['-convert','xml1','-o',file,'-'],JSON.stringify(value));
  try {
    const prefix=path.join(directory,'publisher');
    run('/usr/bin/codesign',['-d','--extract-certificates='+prefix,path.join(app,'Contents/MacOS/autoapprove')]);
    const publisher=createHash('sha1').update(readFileSync(prefix+'0')).digest('hex');
    const requirement=id=>'identifier "'+id+'" and certificate leaf = H"'+publisher+'"';
    const appPlist=path.join(app,'Contents/Info.plist'),info=plist(appPlist);
    if(info.CFBundleIdentifier!=='local.autoapprove.mac'||info.CFBundleVersion!==String(version.build))throw Error('Mismatched input service package');
    info.SMPrivilegedExecutables={[service]:requirement(service)};
    writePlist(appPlist,info);
    const helperInfo=path.join(directory,'info.plist'),launchPlist=path.join(directory,'launchd.plist');
    writePlist(helperInfo,{CFBundleIdentifier:service,CFBundleName:'AutoApprove TTY Input',
      CFBundleVersion:String(version.build),CFBundleShortVersionString:version.version,
      SMAuthorizedClients:[requirement('local.autoapprove.mac')]});
    const launch=plist(path.join(app,'Contents/Library/LaunchDaemons/'+service+'.plist'));
    if(launch.Label!==service||launch.BundleProgram!=='Contents/MacOS/AutoApproveTTYService')throw Error('Unexpected input service executable');
    delete launch.BundleProgram;
    writePlist(launchPlist,launch);
    const build=path.resolve('.build',configuration);
    const architecture=run('/usr/bin/lipo',['-archs',path.join(build,'AutoApproveTTYService')]).toString().trim();
    if(!['arm64','x86_64'].includes(architecture))throw Error('Package each helper architecture before creating a universal bundle');
    const objects=readFileSync(path.join(build,'AutoApproveTTYService.product/Objects.LinkFileList'),'utf8').trim().split('\n');
    const helper=path.join(app,'Contents/MacOS/AutoApproveTTYService');
    const args=['swiftc','-target',architecture+'-apple-macosx14.0','-o',helper,...objects,
      '-Xlinker','-alias','-Xlinker','_AutoApproveTTYService_main','-Xlinker','_main'];
    for(const [section,file] of [['__info_plist',helperInfo],['__launchd_plist',launchPlist]]) {
      args.push('-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker',section,'-Xlinker',file);
    }
    run('/usr/bin/xcrun',args);
    chmodSync(helper,0o755);
    const launchServices=path.join(app,'Contents/Library/LaunchServices');
    mkdirSync(launchServices,{recursive:true});
    copyFileSync(helper,path.join(launchServices,service));
    chmodSync(path.join(launchServices,service),0o755);
  } finally { rmSync(directory,{recursive:true,force:true}); }
}
