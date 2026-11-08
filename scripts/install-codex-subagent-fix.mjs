// Explicit, hash-pinned installation into an existing native Codex 0.167.0.
// Never stops a TUI/server, touches a Codex home, or changes approval settings.
import assert from 'node:assert/strict';
import {readFile,copyFile,chmod,lstat,realpath,rename,unlink} from 'node:fs/promises';
import {constants} from 'node:fs';
import {createHash,randomBytes} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('target'),'Provide --target=/absolute/existing/native/codex');
assert.ok(path.isAbsolute(option('target')),'Target must be absolute');
const bundle=option('bundle')?path.resolve(option('bundle')):path.dirname(fileURLToPath(import.meta.url));
const manifest=JSON.parse(await readFile(path.join(bundle,'manifest.json'),'utf8'));
assert.equal(manifest.upstreamVersion,'0.167.0');assert.equal(manifest.architecture,'arm64');assert.equal(process.platform,'darwin');assert.equal(process.arch,'arm64');
const hash=b=>createHash('sha256').update(b).digest('hex'),target=await realpath(option('target'));
const info=await lstat(target);assert.ok(info.isFile()&&info.uid===process.getuid(),'Target must be a regular file owned by the current user');
const original=manifest.originalBinarySHA256,patched=manifest.binarySHA256;
assert.match(original,/^[a-f0-9]{64}$/);assert.match(patched,/^[a-f0-9]{64}$/);
const restore=process.argv.includes('--restore'),desired=restore?original:patched,expected=restore?patched:original;
const current=hash(await readFile(target)),backup=target+'.autoapprove-backup-'+original.slice(0,16);
if(current===desired){console.log(JSON.stringify({installed:!restore,restored:restore,alreadyCurrent:true,target}));process.exit(0);}
assert.equal(current,expected,'This executable is not the exact supported source version; nothing changed');
const source=restore?backup:path.join(bundle,'bin/codex');assert.equal(hash(await readFile(source)),desired,'Installation bytes do not match the manifest');
// The original npm bytes have a pre-existing invalid signature. Restore only
// that exact pinned original; verify the new locally signed build strictly.
if(!restore)execFileSync('/usr/bin/codesign',['--verify','--strict',source]);
if(!restore){
 try{await copyFile(target,backup,constants.COPYFILE_EXCL);}catch(error){if(error.code!=='EEXIST')throw error;}
 assert.equal(hash(await readFile(backup)),original,'Backup differs from the original');
}
const stage=target+'.autoapprove-stage-'+randomBytes(8).toString('hex');
try{
 await copyFile(source,stage,constants.COPYFILE_EXCL);await chmod(stage,info.mode&0o777);
 if(!restore)execFileSync('/usr/bin/codesign',['--verify','--strict',stage]);
 const version=execFileSync(stage,['--version'],{encoding:'utf8',timeout:15000}).trim();
 assert.equal(version,'codex-cli 0.167.0','Package version changed');
 assert.equal(hash(await readFile(target)),expected,'Target changed during preparation');
 await rename(stage,target);
 assert.equal(hash(await readFile(target)),desired);
 console.log(JSON.stringify({installed:!restore,restored:restore,target,backup,runningClientsNeedRestart:true}));
}finally{await unlink(stage).catch(error=>{if(error.code!=='ENOENT')throw error;});}
