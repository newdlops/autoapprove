// Prepare a separate pinned source tree; never build, install or launch Codex.
import assert from 'node:assert/strict';
import {readFile, lstat, mkdir, cp, realpath, writeFile, readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {normalizeNativeBuildLock} from './codex-native-build-lock.mjs';

const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('source')&&option('output'),'Provide --source=/exact/upstream/codex-rs --output=/new/private/tree');
const source=await realpath(option('source')),output=path.resolve(option('output'));
const relative=path.relative(source,output);
assert.ok(relative==='..'||relative.startsWith('..'+path.sep)||path.isAbsolute(relative),'Output must be outside the source tree');
const assets=fileURLToPath(new URL('../patches/codex/',import.meta.url));
const manifest=JSON.parse(await readFile(assets+'0.166.0-native-inventory.manifest.json','utf8'));
const patch=assets+'0.166.0-native-inventory.patch';
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const serverManifest=process.argv.includes('--with-server-inventory')
 ? JSON.parse(await readFile(assets+'0.166.0-native-server-inventory.manifest.json','utf8')):null;
const serverPatch=assets+'0.166.0-native-server-inventory.patch';
if(serverManifest){
 assert.equal(serverManifest.format,1);assert.equal(serverManifest.migrationAdmission,false);
 assert.equal(serverManifest.upstreamCommit,manifest.upstreamCommit);
 assert.equal(serverManifest.requiresInventoryPatchSHA256,manifest.patchSHA256);
 assert.equal(hash(await readFile(serverPatch)),serverManifest.patchSHA256);
}
assert.equal(manifest.format,1);assert.equal(manifest.migrationAdmission,false);
assert.equal(hash(await readFile(patch)),manifest.patchSHA256,'Patch differs from reviewed manifest');
const baseFiles=new Map(manifest.files.map(file=>[file.path,file]));
assert.equal(baseFiles.size,manifest.files.length);
const serverFiles=serverManifest?.files||[];
assert.equal(new Set(serverFiles.map(file=>file.path)).size,serverFiles.length);
for(const file of serverFiles){
 if(baseFiles.has(file.path))assert.equal(file.before,baseFiles.get(file.path).after,'Server phase must match the exact TUI postimage');
}
const files=[...new Map([...manifest.files,...serverFiles].map(file=>[file.path,file])).values()];
const paths=files.map(v=>v.path);
for(const file of [...Object.keys(manifest.pins),...paths])assert.ok(/^[a-zA-Z0-9_./-]+$/.test(file)&&!file.startsWith('/')&&!file.split('/').includes('..'));
async function verify(root,file,expected){
 const selected=path.join(root,file);
 if(expected===null){await assert.rejects(lstat(selected),{code:'ENOENT'});return;}
 assert.ok((await lstat(selected)).isFile(),'Expected a regular pinned source file: '+file);
 assert.equal(hash(await readFile(selected)),expected,'Source identity mismatch: '+file);
}
for(const [file,digest]of Object.entries(manifest.pins))await verify(source,file,digest);
for(const item of manifest.files)await verify(source,item.path,item.before);
for(const item of serverFiles)if(!baseFiles.has(item.path))await verify(source,item.path,item.before);
// An existing output is never reused, reset or removed, including on failure.
await mkdir(output,{mode:0o700});
for(const name of await readdir(source)) {
 if(['target','.git'].includes(name))continue;
 await cp(path.join(source,name),path.join(output,name),{recursive:true,errorOnExist:true,force:false,verbatimSymlinks:true,
  filter:entry=>!['target','.git'].includes(path.basename(entry))});
}
execFileSync('/usr/bin/git',['apply','--check',patch],{cwd:output,stdio:'pipe'});
execFileSync('/usr/bin/git',['apply',patch],{cwd:output,stdio:'pipe'});
for(const item of manifest.files)await verify(output,item.path,item.after);
if(serverManifest){
 for(const item of serverFiles)await verify(output,item.path,item.before);
 execFileSync('/usr/bin/git',['apply','--check',serverPatch],{cwd:output,stdio:'pipe'});
 execFileSync('/usr/bin/git',['apply',serverPatch],{cwd:output,stdio:'pipe'});
}
for(const item of files)await verify(output,item.path,item.after);
const buildLock=normalizeNativeBuildLock(await readFile(path.join(output,'Cargo.lock'),'utf8'),manifest);
await writeFile(path.join(output,'Cargo.lock'),buildLock);
await writeFile(path.join(output,'autoapprove-native-prototype.json'),JSON.stringify({
 upstreamCommit:manifest.upstreamCommit,patchSHA256:manifest.patchSHA256,
 serverPatchSHA256:serverManifest?.patchSHA256||null,
 buildLockSHA256:manifest.buildLock.after,
 sourceOnly:true,built:false,installed:false,migrationAdmission:false
},null,2)+'\n',{mode:0o600});
console.log(JSON.stringify({prepared:true,output,changedFiles:paths.length,normalizedLocalVersions:manifest.buildLock.entries,externalDependenciesUnchanged:true,built:false,installed:false}));
