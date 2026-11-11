import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,copyFile,chmod,readdir,lstat,realpath} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('binary')&&option('source')&&option('runtime-archive'),'Provide --binary=/release/codex --source=/patched/codex-rs --runtime-archive=/official/package.tar.gz');
const source=path.resolve(option('source')),pins=JSON.parse(await readFile('patches/codex/0.167.1-child-goal-control.manifest.json','utf8'));
const approvalPins=JSON.parse(await readFile('patches/codex/0.167.0-subagent-approval.manifest.json','utf8'));
const nativeRuntime=process.argv.includes('--native-runtime');
const nativePins=nativeRuntime?JSON.parse(await readFile('patches/codex/0.167.1-selected-input-observation.manifest.json','utf8')):null;
const buildLabel=nativeRuntime?'autoapprove-managed-1671-2':'autoapprove-managed-1671-1';
const runtimeArchiveSHA256='5bcbc5866cbca19f9299f7884e9b39b9ccb5469969c170b1f2d2cd6fc4b1ee72';
const hash=b=>createHash('sha256').update(b).digest('hex');
const finalFiles=new Map([...pins.files,...approvalPins.files,...(nativePins?.files??[])].map(file=>[file.path,file]));
for(const file of finalFiles.values())assert.equal(hash(await readFile(path.join(source,file.path))),file.after,'Build source changed: '+file.path);
if(nativePins)assert.equal(hash(await readFile('patches/codex/0.167.1-selected-input-observation.patch')),nativePins.patchSHA256,'Native source patch changed');
const inputBinary=await readFile(option('binary'));
assert.ok(inputBinary.includes(Buffer.from(buildLabel)),'Maintained-build diagnostic stamp is missing');
if(nativeRuntime)for(const marker of ['autoapprove-native-runtime-registration','autoapprove-native-tui-input-hold'])assert.ok(inputBinary.includes(Buffer.from(marker)),'Native runtime capability marker is missing: '+marker);
assert.ok(inputBinary.includes(Buffer.from(pins.upstreamCommit)),'Runtime compatibility stamp is missing');
const name=`Codex-0.167.1-AutoApprove-managed${nativeRuntime?'2':'1'}-macOS-arm64`,bundle=path.resolve('dist',name);
await mkdir(path.dirname(bundle),{recursive:true});
// Refuse to reuse an old staging folder so unrelated files cannot enter a release.
assert.equal(hash(await readFile(option('runtime-archive'))),runtimeArchiveSHA256,'Wrong official runtime archive');
await mkdir(bundle);
execFileSync('/usr/bin/tar',['-xzf',path.resolve(option('runtime-archive')),'-C',bundle]);
const originalBinarySHA256=hash(await readFile(path.join(bundle,'bin/codex')));
const originalFiles={};
async function recordFiles(directory){for(const name of await readdir(directory)){
 const at=path.join(directory,name),info=await lstat(at);assert.ok(!info.isSymbolicLink(),'Unexpected runtime link');
 if(info.isDirectory())await recordFiles(at);else{assert.ok(info.isFile());originalFiles[path.relative(bundle,at)]=hash(await readFile(at));}
}}
await recordFiles(bundle);
const packageMetadata=JSON.parse(await readFile(path.join(bundle,'codex-package.json'),'utf8'));
assert.equal(packageMetadata.version,'0.167.1');assert.equal(packageMetadata.target,'aarch64-apple-darwin');assert.equal(packageMetadata.entrypoint,'bin/codex');
assert.equal(execFileSync(path.join(bundle,'codex-resources/voice/bin/codex-voice-host'),['--build-commit'],{encoding:'utf8',timeout:10000}).trim(),pins.upstreamCommit,'Voice helper compatibility stamp differs');
const frame=value=>{const payload=Buffer.from(JSON.stringify(value)),length=Buffer.alloc(4);length.writeUInt32BE(payload.length);return Buffer.concat([length,payload]);};
const voiceReply=execFileSync(path.join(bundle,'codex-resources/voice/bin/codex-voice-host'),[],{input:Buffer.concat([frame({type:'hello',protocol:1,buildCommit:pins.upstreamCommit}),frame({type:'close'})]),timeout:10000});
const voiceMessages=[];
for(let offset=0;offset<voiceReply.length;){const length=voiceReply.readUInt32BE(offset);assert.ok(length<=128*1024&&offset+4+length<=voiceReply.length);voiceMessages.push(JSON.parse(voiceReply.subarray(offset+4,offset+4+length)));offset+=4+length;}
assert.deepEqual(voiceMessages,[{type:'ready'},{type:'closed'}],'Voice helper handshake failed');
const binary=path.join(bundle,'bin/codex');await copyFile(option('binary'),binary);await chmod(binary,0o755);
assert.equal(execFileSync('/usr/bin/lipo',['-archs',binary],{encoding:'utf8'}).trim(),'arm64');
execFileSync('/usr/bin/strip',['-x',binary]);
// Existing publisher identity only. Never provision or print signing secrets here.
const signing=JSON.parse(await readFile('.runtime/code-signing/identity.json','utf8'));
assert.match(signing.identity,/^[A-Fa-f0-9]{40}$/);
if(typeof signing.password!=='string'||!/^[A-Fa-f0-9]{64}$/.test(signing.password))throw new Error('Invalid private signing metadata');
const keychain=await realpath('.runtime/code-signing/publisher.keychain-db');
// Match sign-app.mjs: feed the existing password through security's quiet stdin,
// never through process arguments, logs, or an error containing private input.
function security(args){
 const input=args.map(value=>{assert.ok(!/[\0\r\n]/.test(value));return '"'+value.replaceAll('\\','\\\\').replaceAll('"','\\"')+'"';}).join(' ')+'\n';
 try{return execFileSync('/usr/bin/security',['-i','-q'],{input,stdio:['pipe','pipe','pipe']}).toString();}
 catch{throw new Error('Existing publisher keychain operation failed; private input omitted');}
}
function searchList(){return security(['list-keychains','-d','user']).split('\n').filter(line=>line.trim()).map(line=>{const match=line.match(/^\s*"(.*)"\s*$/);if(!match?.[1])throw new Error('Invalid keychain search list');return match[1];});}
security(['unlock-keychain','-p',signing.password,keychain]);
const before=searchList(),added=!before.includes(keychain),during=added?[...before,keychain]:before;
if(added)security(['list-keychains','-d','user','-s',...during]);
try{execFileSync('/usr/bin/codesign',['--force','--sign',signing.identity,'--keychain',keychain,'--identifier','local.autoapprove.codex-managed',binary],{stdio:'inherit'});}
finally{if(added){const current=searchList();security(['list-keychains','-d','user','-s',...(JSON.stringify(current)===JSON.stringify(during)?before:current.filter(p=>p!==keychain))]);}}
execFileSync('/usr/bin/codesign',['--verify','--strict',binary],{stdio:'inherit'});
assert.equal(execFileSync(binary,['--version'],{encoding:'utf8'}).trim(),'codex-cli 0.167.1');
const voiceManifestPath='codex-resources/voice/manifest.json';
const voiceManifest=JSON.parse(await readFile(path.join(bundle,voiceManifestPath),'utf8'));
assert.equal(voiceManifest.buildCommit,pins.upstreamCommit);
assert.equal(voiceManifest.sha256['bin/codex'],originalBinarySHA256);
voiceManifest.sha256['bin/codex']=hash(await readFile(binary));
await writeFile(path.join(bundle,voiceManifestPath),JSON.stringify(voiceManifest,null,2)+'\n');
for(const [from,to]of [
 ['patches/codex/0.167.0-subagent-approval.patch','source.patch'],
 ['patches/codex/0.167.0-subagent-approval.manifest.json','source-manifest.json'],
 ['patches/codex/0.167.1-child-goal-control.patch','goal-control.patch'],
 ['patches/codex/0.167.1-child-goal-control.manifest.json','goal-control-manifest.json'],
 [nativeRuntime?'patches/codex/0.167.1-native-runtime.md':'patches/codex/0.167.1-managed-package.md','README.md']
])await copyFile(from,path.join(bundle,to));
if(nativeRuntime)for(const suffix of ['patch','manifest.json'])await copyFile('patches/codex/0.167.1-selected-input-observation.'+suffix,path.join(bundle,'native-runtime.'+suffix));
await copyFile(path.resolve(source,'../LICENSE'),path.join(bundle,'LICENSE'));
await copyFile(path.resolve(source,'../NOTICE'),path.join(bundle,'NOTICE'));
// Include dependency notices from the exact locked graph; no runtime data.
const metadata=JSON.parse(execFileSync('cargo',['metadata','--format-version','1','--locked','--offline'],{cwd:source,maxBuffer:32*1024*1024,encoding:'utf8'}));
const licenses=path.join(bundle,'third-party-licenses');await mkdir(licenses,{recursive:true});let notices=0;
for(const pkg of metadata.packages){
 const directory=path.dirname(pkg.manifest_path),folder=path.join(licenses,pkg.name+'-'+pkg.version);
 const names=(await readdir(directory)).filter(n=>/^(LICENSE|LICENCE|COPYING|NOTICE)([._-].*)?$/i.test(n));
 if(pkg.license_file&&path.basename(pkg.license_file)===pkg.license_file&&!names.includes(pkg.license_file))names.push(pkg.license_file);
 const files=[];
 for(const file of names){const at=path.join(directory,file),st=await lstat(at);if(!st.isFile()||st.size>262144)continue;await mkdir(folder,{recursive:true});await copyFile(at,path.join(folder,file));files.push(file);notices++;}
 if(files.length)await writeFile(path.join(folder,'package.json'),JSON.stringify({name:pkg.name,version:pkg.version,license:pkg.license,repository:pkg.repository,files},null,2)+'\n');
}
// Preserve helper/resource bytes and update only the primary CLI checksum.
for(const [file,digest]of Object.entries(originalFiles))if(!['bin/codex',voiceManifestPath].includes(file))assert.equal(hash(await readFile(path.join(bundle,file))),digest,'Runtime helper changed: '+file);
for(const [file,digest]of Object.entries(voiceManifest.sha256))assert.equal(hash(await readFile(path.join(bundle,file))),digest,'Voice runtime checksum mismatch: '+file);
const manifest={format:1,name,upstreamVersion:'0.167.1',upstreamCommit:pins.upstreamCommit,buildLabel,runtimeCompatibilityStamp:pins.upstreamCommit,architecture:'arm64',patchSHA256:pins.patchSHA256,approvalPatchSHA256:approvalPins.patchSHA256,sourceArchiveSHA256:pins.sourceArchiveSHA256,runtimeArchiveSHA256,originalBinarySHA256,binarySHA256:hash(await readFile(binary)),voiceManifestSHA256:hash(await readFile(path.join(bundle,voiceManifestPath))),officialRuntimeFiles:originalFiles,features:['codex-app-server/autoapprove-goal-control',...(nativeRuntime?['codex-app-server/autoapprove-native-inventory','codex-app-server/autoapprove-selected-transition','codex-tui/autoapprove-native-inventory']:[])],publisher:'AutoApprove Local Code Signing',officialOpenAIRelease:false,
 ...(nativeRuntime?{nativeRuntimeSchemaVersion:1,nativePatchSHA256:nativePins.patchSHA256,releaseReady:nativePins.releaseReady===true,migrationAuthorized:false}:{})};
await writeFile(path.join(bundle,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
const archive=path.resolve('dist',name+'.zip');execFileSync('/usr/bin/ditto',['-c','-k','--norsrc','--keepParent',bundle,archive]);
const bytes=await readFile(archive),sha256=hash(bytes);await writeFile(archive+'.sha256',sha256+'  '+path.basename(archive)+'\n');
console.log(JSON.stringify({archive,bytes:bytes.length,sha256,binarySHA256:manifest.binarySHA256,dependencyNotices:notices}));
