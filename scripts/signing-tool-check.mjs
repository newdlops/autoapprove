// Exercise the actual packaging tool boundary with disposable files and fake tools.
// Never reads the publisher keychain, invokes security, or changes OS permissions.
import assert from 'node:assert/strict';
import childProcess from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
import {mkdtemp,rm,readFile,writeFile,symlink,mkdir} from 'node:fs/promises';
import {writeFileSync,realpathSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
const original=childProcess.execFileSync,previous=process.cwd();
const directory=await mkdtemp(path.join(tmpdir(),'autoapprove-signing-tools-'));
const identity='A'.repeat(40),calls=[];
const signedPaths=[];
const signingVariables=['AUTOAPPROVE_SIGNING_IDENTITY','AUTOAPPROVE_SIGNING_KEYCHAIN'];
const savedVariables=signingVariables.map(name=>process.env[name]);
let denyUnlock=false;
let failSigning=false,concurrentAddition=false;
let canonicalSearch=false;
const canonicalKeychain=value=>{try{return realpathSync(value);}catch{return value;}};
const originalSearch=['/private/tmp/disposable-login.keychain-db'];
let searchList=[...originalSearch];
childProcess.execFileSync=(binary,args,options)=>{
  if(args.some(value=>/[a-f0-9]{64}/i.test(value)))throw Error('Private credential appeared in process arguments');
  if(binary==='/usr/bin/security') {
    assert.deepEqual(args,['-i','-q'],'Keychain commands must use only piped stdin');
    assert.deepEqual(options.stdio,['pipe','pipe','pipe']);
    assert.equal(typeof options.input,'string');
    const command=options.input.match(/^"([a-z-]+)"/)[1];
    calls.push(command);
    if(command==='list-keychains') {
      const argumentsFromStdin=[...options.input.matchAll(/"(?:\\.|[^"\\])*"/g)].map(match=>JSON.parse(match[0]));
      const set=argumentsFromStdin.indexOf('-s');
      if(set>=0)searchList=argumentsFromStdin.slice(set+1).map(value=>canonicalSearch?canonicalKeychain(value):value);
      return Buffer.from(searchList.map(value=>'    "'+value+'"').join('\n')+'\n');
    }
    if(command==='create-keychain') {
      const argumentsFromStdin=[...options.input.matchAll(/"(?:\\.|[^"\\])*"/g)].map(match=>JSON.parse(match[0]));
      writeFileSync(argumentsFromStdin.at(-1),'disposable keychain');
    }
    if(denyUnlock && command==='unlock-keychain') {
      const error=Error('Private diagnostic '+options.input);error.status=1;throw error;
    }
    return Buffer.alloc(0);
  }
  if(binary==='/usr/bin/openssl') {
    if(args[0]==='req') {
      writeFileSync(args[args.indexOf('-keyout')+1],'disposable private key');
      writeFileSync(args[args.indexOf('-out')+1],'disposable public certificate');
    }
    if(args[0]==='x509')return Buffer.from('SHA1 Fingerprint='+identity+'\n');
    if(args[0]==='pkcs12') {
      assert.equal(args[args.indexOf('-passout')+1],'stdin');
      assert.match(options.input,/^[a-f0-9]{64}\n$/);
      writeFileSync(args[args.indexOf('-out')+1],'disposable encrypted archive');
    }
    return Buffer.alloc(0);
  }
  assert.equal(binary,'/usr/bin/codesign');
  if(args.includes('--sign'))signedPaths.push(args.at(-1));
  if(args.includes('--sign')&&args.includes('--keychain')&&!searchList.includes(canonicalSearch?canonicalKeychain(args[args.indexOf('--keychain')+1]):args[args.indexOf('--keychain')+1]))
    throw Error('No identity found: publisher is absent from the keychain search list');
  if(args.includes('--sign')&&failSigning) {
    if(concurrentAddition)searchList.push('/private/tmp/disposable-concurrent.keychain-db');
    throw Error('Disposable signing failure');
  }
  return Buffer.from(args.includes('-r-')?'designated => identifier "local.autoapprove.mac" and anchor = H"'+identity+'"\n':'');
};
syncBuiltinESMExports();
try {
  signingVariables.forEach(name=>delete process.env[name]);process.chdir(directory);
  const {signApp}=await import('./sign-app.mjs');
  await signApp(path.join(directory,'First.app'));
  assert.deepEqual(calls.slice(0,6),['create-keychain','set-keychain-settings','unlock-keychain','import','set-key-partition-list','unlock-keychain']);
  assert.deepEqual(searchList,originalSearch,'Signing must restore the original search list');
  const metadata=path.join(directory,'.runtime/code-signing/identity.json');
  const saved=JSON.parse(await readFile(metadata,'utf8'));
  await signApp(path.join(directory,'Update.app'));
  assert.deepEqual(searchList,originalSearch,'Updating must restore the original search list');
  const withService=path.join(directory,'WithService.app');
  await mkdir(path.join(withService,'Contents/MacOS'),{recursive:true});
  await writeFile(path.join(withService,'Contents/MacOS/AutoApproveTTYService'),'disposable helper');
  const beforeService=signedPaths.length;
  await signApp(withService);
  assert.deepEqual(signedPaths.slice(beforeService),[path.join(withService,'Contents/MacOS/autoapprove'),path.join(withService,'Contents/MacOS/AutoApproveTTYService'),withService],
    'The signed TTY service must be sealed before its containing app');
  assert.deepEqual(searchList,originalSearch,'Nested service signing must restore the original search list');
  failSigning=true;
  await assert.rejects(()=>signApp(path.join(directory,'SigningFailure.app')),/Disposable signing failure/);
  assert.deepEqual(searchList,originalSearch,'Signing failure must restore the original search list');
  concurrentAddition=true;
  await assert.rejects(()=>signApp(path.join(directory,'ConcurrentChange.app')),/Disposable signing failure/);
  assert.deepEqual(searchList,[...originalSearch,'/private/tmp/disposable-concurrent.keychain-db'],'Cleanup must preserve concurrent user entries');
  failSigning=false;concurrentAddition=false;searchList=[...originalSearch];
  const publisher=path.join(directory,'.runtime/code-signing/publisher.keychain-db');
  const alias=path.join(directory,'publisher-alias.keychain-db');
  await symlink(publisher,alias);
  process.env.AUTOAPPROVE_SIGNING_IDENTITY=identity;process.env.AUTOAPPROVE_SIGNING_KEYCHAIN=alias;
  canonicalSearch=true;failSigning=true;
  await assert.rejects(()=>signApp(path.join(directory,'AliasFailure.app')),/Disposable signing failure/);
  assert.deepEqual(searchList,originalSearch,'Canonical keychain aliases must be removed after signing failure');
  failSigning=false;
  await signApp(path.join(directory,'AliasUpdate.app'));
  assert.deepEqual(searchList,originalSearch,'Canonical keychain aliases must be removed after signing success');
  process.env.AUTOAPPROVE_SIGNING_KEYCHAIN='publisher.keychain-db';
  const beforeRelative=calls.length;
  await assert.rejects(()=>signApp(path.join(directory,'RelativeAlias.app')),/absolute path/);
  assert.equal(calls.length,beforeRelative,'Ambiguous relative keychains must be rejected before OS calls');
  canonicalSearch=false;signingVariables.forEach(name=>delete process.env[name]);
  denyUnlock=true;
  await assert.rejects(()=>signApp(path.join(directory,'Failure.app')),error=>
    error.message.includes('private arguments omitted')&&!error.message.includes(saved.password));
  saved.password='disposable invalid private credential';
  await writeFile(metadata,JSON.stringify(saved));
  await assert.rejects(()=>signApp(path.join(directory,'Invalid.app')),error=>
    error.message.includes('Invalid private signing metadata')&&!error.message.includes(saved.password));
  await writeFile(metadata,'private credential: '+saved.password);
  await assert.rejects(()=>signApp(path.join(directory,'Malformed.app')),error=>
    error.message.includes('restore the signing backup')&&!error.message.includes(saved.password));
  await rm(metadata);denyUnlock=false;
  const beforeReuseOnly=calls.length;
  await assert.rejects(()=>signApp(path.join(directory,'NoPublisher.app'),{allowProvisioning:false}),/matching publisher identity/);
  assert.equal(calls.length,beforeReuseOnly,'Compatibility QA must not provision a publisher keychain');
  console.log('PASS: signing setup/update secrets absent from argv; stdin only; errors redact credentials; search list restored after success/failure, concurrent entries preserved; reuse-only never provisions; OS untouched');
} finally {
  process.chdir(previous);childProcess.execFileSync=original;syncBuiltinESMExports();
  signingVariables.forEach((name,index)=>savedVariables[index]===undefined?delete process.env[name]:process.env[name]=savedVariables[index]);
  await rm(directory,{recursive:true,force:true});
}
