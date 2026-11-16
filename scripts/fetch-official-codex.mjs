import assert from 'node:assert/strict';
import {createReadStream} from 'node:fs';
import {createHash} from 'node:crypto';
import {lstat,mkdir,mkdtemp,readFile,rename,rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {verifyOfficialCodexRuntime} from './codex-runtime-resource.mjs';

const catalog=fileURLToPath(new URL('../Sources/AutoApproveCore/Resources/CodexOfficialRelease.json',import.meta.url));
async function digest(file){
  const hash=createHash('sha256');
  for await(const bytes of createReadStream(file))hash.update(bytes);
  return hash.digest('hex');
}

export async function ensureOfficialCodexRuntime({cacheRoot=path.resolve('.runtime')}={}){
  const release=JSON.parse(await readFile(catalog,'utf8'));
  assert.equal(release.architecture,process.arch,'No pinned official Codex package for this build architecture');
  const directory=path.resolve(cacheRoot,'official-codex-'+release.version),destination=path.join(directory,'extracted');
  try {
    const info=await lstat(destination);
    assert.ok(info.isDirectory()&&!info.isSymbolicLink(),'Unsafe official Codex cache');
    await verifyOfficialCodexRuntime(destination);
    return destination;
  }catch(error){if(error.code!=='ENOENT')throw error;}
  await mkdir(directory,{recursive:true,mode:0o700});
  const archive=path.join(directory,'codex-package-'+release.target+'.tar.gz');
  let cached=false;
  try {cached=(await lstat(archive)).isFile()&&(await digest(archive))===release.archiveSHA256;}
  catch(error){if(error.code!=='ENOENT')throw error;}
  if(!cached){
    const download=path.join(await mkdtemp(path.join(directory,'download-')),'package.tar.gz');
    try {
      execFileSync('/usr/bin/curl',['--fail','--location','--proto','=https','--tlsv1.2','--output',download,release.archiveURL],{stdio:'inherit'});
      assert.equal(await digest(download),release.archiveSHA256,'Official Codex archive checksum mismatch');
      await rename(download,archive);
    }finally{await rm(path.dirname(download),{recursive:true,force:true});}
  }
  const staging=await mkdtemp(path.join(directory,'unpack-'));
  try {
    // Extract only the source-pinned regular files. No archive links, devices,
    // unknown paths, file replacement or executable postinstall scripts.
    const extractor=String.raw`import hashlib,json,os,pathlib,sys,tarfile
archive,destination,catalog=sys.argv[1:]
expected=json.load(open(catalog))['files']
directories=set()
for name in expected:
    directories.update(str(parent) for parent in pathlib.PurePosixPath(name).parents if str(parent)!='.')
seen=set()
with tarfile.open(archive,'r:gz') as source:
    for index,member in enumerate(source):
        assert index<16384 and chr(92) not in member.name and chr(0) not in member.name
        parts=pathlib.PurePosixPath(member.name).parts
        assert not member.name.startswith('/') and '..' not in parts
        name=str(pathlib.PurePosixPath(member.name))
        if member.isdir():
            assert name=='.' or name in directories
            continue
        assert member.isfile() and name in expected and name not in seen and 0<=member.size<=1073741824
        seen.add(name)
        target=pathlib.Path(destination,name)
        target.parent.mkdir(mode=0o755,parents=True,exist_ok=True)
        checksum=hashlib.sha256()
        with source.extractfile(member) as data,open(target,'xb') as output:
            while True:
                chunk=data.read(1048576)
                if not chunk:break
                checksum.update(chunk)
                output.write(chunk)
        assert checksum.hexdigest()==expected[name]
        target.chmod(0o755 if member.mode&0o111 else 0o644)
assert seen==set(expected)
`;
    execFileSync('/usr/bin/python3',['-c',extractor,archive,staging,catalog],{stdio:'inherit'});
    await verifyOfficialCodexRuntime(staging);
    try {await rename(staging,destination);}
    catch(error){if(!['EEXIST','ENOTEMPTY'].includes(error.code))throw error;await verifyOfficialCodexRuntime(destination);}
    await verifyOfficialCodexRuntime(destination);
    return destination;
  }finally{await rm(staging,{recursive:true,force:true});}
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))console.log(await ensureOfficialCodexRuntime());
