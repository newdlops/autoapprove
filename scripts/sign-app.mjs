// Keep publisher identity stable across local releases. Private keys never enter dist or Git.
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {access,chmod,mkdir,readFile,writeFile,rm,realpath} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {existsSync} from 'node:fs';

function runQuiet(binary,args,input) {
  try { return execFileSync(binary,args,{input,stdio:['pipe','pipe','pipe']}); }
  catch(error) { throw new Error('Signing setup failed for '+path.basename(binary)+' (status '+error.status+'); private arguments omitted'); }
}

function keychainCommand(args) {
  // security's non-TTY -i reader accepts one command from stdin, without a
  // prompt, echo or history. Passwords must never become process arguments.
  assert.ok(args.length<32);
  const line=args.map(value=>{
    assert.equal(typeof value,'string');assert.ok(!/[\0\r\n]/.test(value));
    return '"'+value.replaceAll('\\','\\\\').replaceAll('"','\\"')+'"';
  }).join(' ');
  assert.ok(Buffer.byteLength(line)<4095,'Signing keychain command is too long');
  return runQuiet('/usr/bin/security',['-i','-q'],line+'\n');
}

function keychainSearchList() {
  return keychainCommand(['list-keychains','-d','user']).toString().split('\n').filter(line=>line.trim()).map(line=>{
    const match=line.match(/^\s*"(.*)"\s*$/);
    if(!match||!match[1])throw new Error('Could not read the original keychain search list');
    return match[1];
  });
}

function withSigningKeychain(keychain,sign) {
  if(!keychain)return sign();
  const before=keychainSearchList();
  if(before.includes(keychain))return sign();
  const during=[...before,keychain];
  keychainCommand(['list-keychains','-d','user','-s',...during]);
  try { return sign(); }
  finally {
    const current=keychainSearchList();
    // Keep concurrent user additions/removals; undo only this invocation's entry.
    const unchanged=JSON.stringify(current)===JSON.stringify(during);
    keychainCommand(['list-keychains','-d','user','-s',...(unchanged?before:current.filter(value=>value!==keychain))]);
  }
}

export async function signApp(app,{allowProvisioning=true}={}) {
  let identity=process.env.AUTOAPPROVE_SIGNING_IDENTITY;
  let keychain=process.env.AUTOAPPROVE_SIGNING_KEYCHAIN;
  if(keychain&&!path.isAbsolute(keychain))throw new Error('AUTOAPPROVE_SIGNING_KEYCHAIN must be an absolute path');
  if (!identity) {
    const directory=path.resolve('.runtime/code-signing');
    if(allowProvisioning) { await mkdir(directory,{recursive:true,mode:0o700});await chmod(directory,0o700); }
    keychain=path.join(directory,'publisher.keychain-db');
    const metadata=path.join(directory,'identity.json');
    let saved;
    try { saved=JSON.parse(await readFile(metadata,'utf8')); }
    catch(error) {
      if(error.code!=='ENOENT')throw new Error('Invalid private signing metadata; restore the signing backup');
      if(!allowProvisioning)throw new Error('Compatibility QA requires the matching publisher identity; no signing keychain was provisioned');
      try { await access(keychain);throw new Error('Existing signing keychain has no identity metadata; restore it before publishing'); }
      catch(existing) { if(existing.code!=='ENOENT')throw existing; }
      const password=randomBytes(32).toString('hex');
      const config=path.join(directory,'openssl.cnf'),key=path.join(directory,'private-key.pem'),certificate=path.join(directory,'publisher.pem'),archive=path.join(directory,'publisher.p12');
      await writeFile(config,'[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=code_signing\n[subject]\nCN=AutoApprove Local Code Signing\n[code_signing]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n',{mode:0o600});
      try {
        runQuiet('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','3650','-config',config,'-keyout',key,'-out',certificate]);
        await chmod(key,0o600);
        const fingerprint=runQuiet('/usr/bin/openssl',['x509','-in',certificate,'-noout','-fingerprint','-sha1']).toString().trim().split('=').at(-1).replaceAll(':','');
        assert.match(fingerprint,/^[A-Fa-f0-9]{40}$/);
        runQuiet('/usr/bin/openssl',['pkcs12','-export','-inkey',key,'-in',certificate,'-name','AutoApprove Local Code Signing','-out',archive,'-passout','stdin'],password+'\n');
        await chmod(archive,0o600);
        keychainCommand(['create-keychain','-p',password,keychain]);
        keychainCommand(['set-keychain-settings','-lut','21600',keychain]);
        keychainCommand(['unlock-keychain','-p',password,keychain]);
        keychainCommand(['import',archive,'-k',keychain,'-P',password,'-T','/usr/bin/codesign']);
        keychainCommand(['set-key-partition-list','-S','apple-tool:,apple:','-s','-k',password,keychain]);
        saved={identity:fingerprint,password};
        await writeFile(metadata,JSON.stringify(saved)+'\n',{mode:0o600});
      } finally {
        await Promise.all([key,archive].map(file=>rm(file,{force:true})));
      }
    }
    assert.match(saved.identity,/^[A-Fa-f0-9]{40}$/);
    if(!/^[A-Fa-f0-9]{64}$/.test(saved.password))throw new Error('Invalid private signing metadata; restore the signing backup');
    keychainCommand(['unlock-keychain','-p',saved.password,keychain]);
    identity=saved.identity;
  }
  assert.ok(identity!=='-','Ad-hoc identity invalidates privacy permission on every update');
  // Security canonicalizes search-list entries. Use that same path for adding,
  // comparing and removing a keychain, including externally supplied symlinks.
  if(keychain)keychain=await realpath(keychain);
  const options=['--force','--sign',identity,...(keychain?['--keychain',keychain]:[])];
  withSigningKeychain(keychain,()=>{
    execFileSync('/usr/bin/codesign',[...options,'--identifier','local.autoapprove.helper',path.join(app,'Contents/MacOS/autoapprove')],{stdio:'inherit'});
    const ttyHelper=path.join(app,'Contents/MacOS/AutoApproveTTYService');
    // Older already-published bundles do not contain this optional component.
    // The current packager always includes it and fails on a missing binary.
    if(existsSync(ttyHelper))execFileSync('/usr/bin/codesign',[...options,'--identifier','local.autoapprove.tty-input',ttyHelper],{stdio:'inherit'});
    execFileSync('/usr/bin/codesign',[...options,'--entitlements','scripts/entitlements.plist',app],{stdio:'inherit'});
    execFileSync('/usr/bin/codesign',['--verify','--deep','--strict',app],{stdio:'inherit'});
    const requirement=execFileSync('/usr/bin/codesign',['-d','-r-',app],{encoding:'utf8',stdio:['ignore','pipe','pipe']});
    assert.ok(requirement.includes('identifier "local.autoapprove.mac"')&&/certificate|anchor/.test(requirement)&&!requirement.includes('cdhash'),'Publisher identity must survive binary changes and remain signer-bound');
  });
  console.log('Signed with stable publisher identity; private keychain stays outside release assets.');
}
