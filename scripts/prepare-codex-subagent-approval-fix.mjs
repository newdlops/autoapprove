// Verify the upstream archive and every patch pre/postimage before an isolated build.
import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('archive')&&option('output'),'Provide --archive=/upstream.tar.gz --output=/new/source');
const assets=fileURLToPath(new URL('../patches/codex/',import.meta.url));
const manifest=JSON.parse(await readFile(assets+'0.167.0-subagent-approval.manifest.json','utf8'));
const patch=assets+'0.167.0-subagent-approval.patch',hash=b=>createHash('sha256').update(b).digest('hex');
assert.equal(hash(await readFile(option('archive'))),manifest.sourceArchiveSHA256,'Wrong upstream archive');
assert.equal(hash(await readFile(patch)),manifest.patchSHA256,'Changed patch');
const output=path.resolve(option('output'));await mkdir(output,{mode:0o700});
execFileSync('/usr/bin/tar',['-xzf',path.resolve(option('archive')),'--strip-components=1','-C',output]);
const source=path.join(output,'codex-rs');
for(const f of manifest.files)assert.equal(hash(await readFile(path.join(source,f.path))),f.before,'Changed preimage: '+f.path);
execFileSync('/usr/bin/git',['apply','--check',patch],{cwd:source});
execFileSync('/usr/bin/git',['apply',patch],{cwd:source});
for(const f of manifest.files)assert.equal(hash(await readFile(path.join(source,f.path))),f.after,'Changed postimage: '+f.path);
let count=0;
const lock=(await readFile(path.join(source,'Cargo.lock'),'utf8')).split('[[package]]').map(block=>{
 if(!/^source = /m.test(block)&&/^version = "0.0.0"$/m.test(block)){count++;return block.replace(/^version = "0.0.0"$/m,'version = "0.167.0"');}return block;
}).join('[[package]]');
assert.equal(count,manifest.localWorkspaceLockVersions);
await writeFile(path.join(source,'Cargo.lock'),lock);
console.log(JSON.stringify({prepared:source,verifiedSourceFiles:manifest.files.length,localLockVersions:count,installed:false}));
