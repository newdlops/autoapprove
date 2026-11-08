import assert from 'node:assert/strict';
import {readFile,writeFile,mkdir,copyFile,chmod,readdir,lstat,realpath} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('binary')&&option('source'),'Provide --binary=/release/codex --source=/patched/codex-rs');
const source=path.resolve(option('source')),pins=JSON.parse(await readFile('patches/codex/0.167.0-subagent-approval.manifest.json','utf8'));
const hash=b=>createHash('sha256').update(b).digest('hex');
for(const file of pins.files)assert.equal(hash(await readFile(path.join(source,file.path))),file.after,'Build source changed: '+file.path);
const name='Codex-0.167.0-AutoApprove-fix1-macOS-arm64',bundle=path.resolve('dist',name);
await mkdir(path.dirname(bundle),{recursive:true});
// Refuse to reuse an old staging folder so unrelated files cannot enter a release.
await mkdir(bundle);await mkdir(path.join(bundle,'bin'));
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
try{execFileSync('/usr/bin/codesign',['--force','--sign',signing.identity,'--keychain',keychain,'--identifier','local.autoapprove.codex-approval-fix',binary],{stdio:'inherit'});}
finally{if(added){const current=searchList();security(['list-keychains','-d','user','-s',...(JSON.stringify(current)===JSON.stringify(during)?before:current.filter(p=>p!==keychain))]);}}
execFileSync('/usr/bin/codesign',['--verify','--strict',binary],{stdio:'inherit'});
await writeFile(path.join(bundle,'codex-package.json'),JSON.stringify({version:'0.167.0'})+'\n');
assert.equal(execFileSync(binary,['--version'],{encoding:'utf8'}).trim(),'codex-cli 0.167.0');
for(const [from,to]of [
 ['patches/codex/0.167.0-subagent-approval.patch','source.patch'],
 ['patches/codex/0.167.0-subagent-approval.manifest.json','source-manifest.json'],
 ['patches/codex/0.167.0-subagent-approval.md','README.md'],
 ['scripts/install-codex-subagent-fix.mjs','install.mjs']
])await copyFile(from,path.join(bundle,to));
await copyFile(path.resolve(source,'../LICENSE'),path.join(bundle,'LICENSE'));
await copyFile(path.resolve(source,'../NOTICE'),path.join(bundle,'NOTICE'));
// Include dependency notices from the exact locked graph; no runtime data.
const metadata=JSON.parse(execFileSync('cargo',['metadata','--format-version','1','--locked'],{cwd:source,maxBuffer:32*1024*1024,encoding:'utf8'}));
const licenses=path.join(bundle,'third-party-licenses');await mkdir(licenses,{recursive:true});let notices=0;
for(const pkg of metadata.packages){
 const directory=path.dirname(pkg.manifest_path),folder=path.join(licenses,pkg.name+'-'+pkg.version);
 const names=(await readdir(directory)).filter(n=>/^(LICENSE|LICENCE|COPYING|NOTICE)([._-].*)?$/i.test(n));
 if(pkg.license_file&&path.basename(pkg.license_file)===pkg.license_file&&!names.includes(pkg.license_file))names.push(pkg.license_file);
 const files=[];
 for(const file of names){const at=path.join(directory,file),st=await lstat(at);if(!st.isFile()||st.size>262144)continue;await mkdir(folder,{recursive:true});await copyFile(at,path.join(folder,file));files.push(file);notices++;}
 if(files.length)await writeFile(path.join(folder,'package.json'),JSON.stringify({name:pkg.name,version:pkg.version,license:pkg.license,repository:pkg.repository,files},null,2)+'\n');
}
const manifest={format:1,name,upstreamVersion:'0.167.0',upstreamCommit:pins.upstreamCommit,architecture:'arm64',patchSHA256:pins.patchSHA256,sourceArchiveSHA256:pins.sourceArchiveSHA256,originalBinarySHA256:pins.originalBinarySHA256,binarySHA256:hash(await readFile(binary)),publisher:'AutoApprove Local Code Signing',officialOpenAIRelease:false};
await writeFile(path.join(bundle,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
const archive=path.resolve('dist',name+'.zip');execFileSync('/usr/bin/ditto',['-c','-k','--norsrc','--keepParent',bundle,archive]);
const bytes=await readFile(archive),sha256=hash(bytes);await writeFile(archive+'.sha256',sha256+'  '+path.basename(archive)+'\n');
console.log(JSON.stringify({archive,bytes:bytes.length,sha256,binarySHA256:manifest.binarySHA256,dependencyNotices:notices}));
