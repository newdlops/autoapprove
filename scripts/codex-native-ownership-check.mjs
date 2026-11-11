// Compile the actual persistent-policy reader and its filesystem tests. This
// does not claim native retirement, writer quiescence or migration execution.
import assert from 'node:assert/strict';
import {readFile,mkdir,mkdtemp,writeFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import path from 'node:path';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('source'),'Provide --source=/prepared/codex-rs');
const source=path.resolve(option('source')),module=source+'/core/src/native_ownership.rs';
const manifest=JSON.parse(await readFile('patches/codex/0.167.1-selected-input-observation.manifest.json','utf8'));
const hash=bytes=>createHash('sha256').update(bytes).digest('hex');
const moduleSHA256=hash(await readFile(module));
assert.equal(moduleSHA256,manifest.files.find(file=>file.path==='core/src/native_ownership.rs')?.after,'Native ownership source changed');
const lock=await readFile(source+'/Cargo.lock','utf8');
function version(name){const entry=lock.split('[[package]]').find(block=>block.includes('\nname = "'+name+'"\n'));assert.ok(entry);return entry.match(/version = "([^"]+)"/)[1];}
const parent=path.resolve(option('output')||'.runtime/native-ownership-source');
await mkdir(parent,{recursive:true,mode:0o700});
const root=await mkdtemp(parent+'/check-');await mkdir(root+'/src');
const dependencies=['libc','serde_json','tempfile'].map(name=>`${name}="=${version(name)}"`);
dependencies.push(`serde={version="=${version('serde')}",features=["derive"]}`);
dependencies.push(`uuid={version="=${version('uuid')}",features=["v4"]}`);
await writeFile(root+'/Cargo.toml',`[package]\nname="native-ownership-source-check"\nversion="0.0.0"\nedition="2024"\n[dependencies]\n${dependencies.join('\n')}\n[workspace]\n`);
await writeFile(root+'/src/lib.rs',`#![allow(dead_code)]\n#[path=${JSON.stringify(module)}] mod native_ownership;\n`);
const child=spawn(option('cargo')||'/opt/homebrew/bin/cargo',['test','--offline','--jobs','2','--target-dir',parent+'/target'],{cwd:root,stdio:'inherit'});
const code=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('close',resolve);});
assert.equal(code,0,'Actual native ownership reader tests failed');
console.log(JSON.stringify({verified:true,moduleSHA256,workspaceLockSHA256:hash(Buffer.from(lock)),root,
  scope:'actual persistent ownership reader filesystem tests',fullCoreHooksVerified:false,migrationVerified:false}));
