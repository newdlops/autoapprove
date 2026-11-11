import assert from 'node:assert/strict';
import {readFile,lstat,readdir,cp,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import path from 'node:path';

// Preserve the already signed CLI and its matching voice resources byte for
// byte. App signing must not rewrite nested binaries after these hashes exist.
export async function copyCodexRuntime(source,destination,{allowExperimental=false}={}) {
  source=path.resolve(source);
  const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
  let files=0;
  async function checkTree(directory) {
    const info=await lstat(directory);
    assert.ok(info.isDirectory()&&!info.isSymbolicLink()&&(info.mode&0o022)===0,'Unsafe Codex runtime directory');
    for(const name of await readdir(directory)) {
      const file=path.join(directory,name),entry=await lstat(file);
      assert.ok(!entry.isSymbolicLink(),'Codex runtime contains a link');
      if(entry.isDirectory())await checkTree(file);
      else assert.ok(entry.isFile()&&(entry.mode&0o022)===0&&entry.size<=1_073_741_824&&++files<=16384,'Unsafe Codex runtime file');
    }
  }
  await checkTree(source);
  const manifest=JSON.parse(await readFile(path.join(source,'manifest.json'),'utf8'));
  assert.ok(allowExperimental||manifest.releaseReady===true,'Development Codex runtime cannot enter a release app');
  const required=['codex-app-server/autoapprove-goal-control','codex-app-server/autoapprove-native-inventory',
    'codex-app-server/autoapprove-selected-transition','codex-tui/autoapprove-native-inventory'];
  assert.ok(manifest.format===1&&manifest.upstreamVersion==='0.167.1'&&manifest.architecture==='arm64'&&
    manifest.upstreamCommit==='0a94398fa60c4fac0e7659e4213a0a36e613dd46'&&
    manifest.buildLabel==='autoapprove-managed-1671-2'&&manifest.nativeRuntimeSchemaVersion===1&&
    required.every(feature=>manifest.features?.includes(feature)),'Unsupported bundled Codex runtime');
  const packageInfo=JSON.parse(await readFile(path.join(source,'codex-package.json'),'utf8'));
  assert.ok(packageInfo.version==='0.167.1'&&packageInfo.target==='aarch64-apple-darwin'&&packageInfo.entrypoint==='bin/codex','Wrong Codex package');
  const binary=await readFile(path.join(source,'bin/codex'));
  assert.equal(hash(binary),manifest.binarySHA256,'Codex binary changed after signing');
  for(const marker of [manifest.buildLabel,'autoapprove-native-runtime-registration','autoapprove-native-tui-input-hold'])assert.ok(binary.includes(Buffer.from(marker)),'Missing native capability marker');
  execFileSync('/usr/bin/codesign',['--verify','--strict',path.join(source,'bin/codex')],{stdio:'inherit'});
  const voiceBytes=await readFile(path.join(source,'codex-resources/voice/manifest.json'));
  assert.equal(hash(voiceBytes),manifest.voiceManifestSHA256,'Voice manifest changed');
  const voice=JSON.parse(voiceBytes);
  assert.equal(voice.buildCommit,manifest.upstreamCommit);
  for(const [relative,digest]of Object.entries(voice.sha256)) {
    assert.ok(!path.isAbsolute(relative)&&path.normalize(relative)===relative&&!relative.split('/').includes('..'),'Invalid voice resource path');
    assert.equal(hash(await readFile(path.join(source,relative))),digest,'Voice runtime mismatch: '+relative);
  }
  await rm(destination,{recursive:true,force:true});
  await cp(source,destination,{recursive:true,errorOnExist:true,force:false});
  assert.equal(hash(await readFile(path.join(destination,'bin/codex'))),manifest.binarySHA256,'Embedded Codex binary changed');
  assert.equal(hash(await readFile(path.join(destination,'codex-resources/voice/manifest.json'))),manifest.voiceManifestSHA256,'Embedded voice manifest changed');
  for(const [relative,digest]of Object.entries(voice.sha256))assert.equal(hash(await readFile(path.join(destination,relative))),digest,'Embedded voice resource changed: '+relative);
  execFileSync('/usr/bin/codesign',['--verify','--strict',path.join(destination,'bin/codex')],{stdio:'inherit'});
  return manifest;
}
