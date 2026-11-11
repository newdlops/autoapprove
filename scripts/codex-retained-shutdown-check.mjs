// Exercise the exact retained-shutdown implementation, including cancellation
// and reconnect. This does not attest complete migration or native ownership.
import assert from 'node:assert/strict';
import {readFile,mkdir,mkdtemp,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import path from 'node:path';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('source'),'Provide --source=/prepared/codex-rs');
const source=path.resolve(option('source'));
const modulePath='app-server/src/request_processors/retained_shutdown.rs';
const bytes=await readFile(source+'/'+modulePath);
const sha=bytes=>createHash('sha256').update(bytes).digest('hex');
const manifest=JSON.parse(await readFile('patches/codex/0.167.1-selected-input-observation.manifest.json','utf8'));
assert.equal(sha(bytes),manifest.files.find(row=>row.path===modulePath)?.after,'Retained shutdown source changed');
const lock=await readFile(source+'/Cargo.lock','utf8');
const block=lock.split('[[package]]').find(block=>block.includes('\nname = "tokio"\n'));
const version=block.match(/version = "([^"]+)"/)[1];
const parent=path.resolve(option('output')||'.runtime/retained-shutdown-source');
await mkdir(parent,{recursive:true,mode:0o700});
const root=await mkdtemp(parent+'/check-');
await mkdir(root+'/src');
await writeFile(root+'/Cargo.toml',`[package]\nname="retained-shutdown-source-check"\nversion="0.0.0"\nedition="2024"\n[dependencies]\ntokio={version="=${version}",features=["macros","rt","sync","time"]}\n[workspace]\n`);
await writeFile(root+'/src/retained_shutdown.rs',bytes);
await writeFile(root+'/src/lib.rs','#![allow(dead_code)]\nmod retained_shutdown;\n');
const child=spawn('/opt/homebrew/bin/cargo',['test','--offline','--jobs','2','--target-dir',parent+'/target'],{cwd:root,stdio:'inherit'});
assert.equal(await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);}),0);
console.log(JSON.stringify({verified:true,moduleSHA256:sha(bytes),workspaceLockSHA256:sha(Buffer.from(lock)),root,
  scope:'actual retained shutdown cancellation, timeout, reconnect, failure and replacement tests',fullCoreHooksVerified:false,migrationVerified:false}));
