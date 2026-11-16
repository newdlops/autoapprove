import assert from 'node:assert/strict';
import {readFile,lstat,readdir,cp,rm} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import path from 'node:path';

const releaseURL=new URL('../Sources/AutoApproveCore/Resources/CodexOfficialRelease.json',import.meta.url);
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');

// Trust the release pinned in source, never a manifest supplied with a runtime.
// The CLI, helper binaries, voice resources and upstream signatures stay intact.
export async function verifyOfficialCodexRuntime(source) {
  source=path.resolve(source);
  const release=JSON.parse(await readFile(releaseURL,'utf8'));
  assert.equal(release.format,1);
  assert.match(release.archiveURL,/^https:\/\/github\.com\/openai\/codex\/releases\/download\/rust-v[0-9.]+\/codex-package-[a-z0-9-]+\.tar\.gz$/);
  const actual=[];
  async function walk(directory) {
    const info=await lstat(directory);
    assert.ok(info.isDirectory()&&!info.isSymbolicLink()&&(info.mode&0o022)===0,'Unsafe Codex runtime directory');
    for(const name of await readdir(directory)) {
      const file=path.join(directory,name),entry=await lstat(file);
      assert.ok(!entry.isSymbolicLink(),'Codex runtime contains a link');
      if(entry.isDirectory())await walk(file);
      else {
        assert.ok(entry.isFile()&&(entry.mode&0o022)===0&&entry.size<=1_073_741_824,'Unsafe Codex runtime file');
        actual.push(path.relative(source,file));
        assert.ok(actual.length<=16384,'Too many Codex runtime files');
      }
    }
  }
  await walk(source);
  assert.deepEqual(actual.sort(),Object.keys(release.files).sort(),'Use the complete unmodified official Codex package');
  for(const [relative,digest] of Object.entries(release.files)) {
    assert.ok(!path.isAbsolute(relative)&&path.normalize(relative)===relative&&!relative.split('/').includes('..'),'Invalid pinned resource path');
    assert.match(digest,/^[a-f0-9]{64}$/);
    assert.equal(hash(await readFile(path.join(source,relative))),digest,'Official Codex file was modified: '+relative);
  }
  const metadata=JSON.parse(await readFile(path.join(source,'codex-package.json'),'utf8'));
  assert.equal(metadata.version,release.version);
  assert.equal(metadata.target,release.target);
  assert.equal(metadata.entrypoint,'bin/codex');
  execFileSync('/usr/bin/codesign',['--verify','--strict',path.join(source,'bin/codex')],{stdio:'inherit'});
  return release;
}

export async function copyCodexRuntime(source,destination) {
  source=path.resolve(source);destination=path.resolve(destination);
  assert.ok(source!==destination&&!destination.startsWith(source+path.sep)&&!source.startsWith(destination+path.sep),'Runtime source and destination must be independent');
  const release=await verifyOfficialCodexRuntime(source);
  await rm(destination,{recursive:true,force:true});
  await cp(source,destination,{recursive:true,errorOnExist:true,force:false});
  await verifyOfficialCodexRuntime(destination);
  return release;
}
