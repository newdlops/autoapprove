// Consumer/bootstrap boundary checks. These do not prove the Rust TUI producer.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:net';
import {mkdtemp,chmod,readFile,writeFile,lstat,rm,mkdir,copyFile} from 'node:fs/promises';
import path from 'node:path';
import {normalizeNativeBuildLock} from './codex-native-build-lock.mjs';
const root=await mkdtemp('/private/tmp/aa-native-ipc-');await chmod(root,0o700);
const script=path.resolve('scripts/codex-native-inventory-read.mjs'),prepare=path.resolve('scripts/prepare-codex-native-inventory.mjs');
const source=path.resolve('.runtime/login-ownership/native-extension-reviewed-source/codex-rs');
const run=(file,args)=>new Promise((resolve,reject)=>{
 const child=spawn(process.execPath,[file,...args],{stdio:['ignore','pipe','pipe']});let out='',err='';
 child.stdout.on('data',b=>out+=b);child.stderr.on('data',b=>err+=b);
 child.once('error',reject);child.once('close',code=>resolve({code,out,err}));
});
let socketIndex=0,checks=0;
async function consumer(transform,success){
 const socket=root+'/i'+(++socketIndex)+'.sock',peers=new Set();
 const server=createServer(stream=>{
  peers.add(stream);stream.once('close',()=>peers.delete(stream));let input='';
  stream.on('data',bytes=>{
   input+=bytes.toString();if(!input.includes('\n'))return;
   const request=JSON.parse(input),reply={nonce:request.nonce,pid:12345,schemaVersion:1,
    producer:'autoapprove-native-tui-prototype',membershipComplete:false,admissionGranted:false,
    stores:{navigation:[]},retainedInputs:{},currentWidget:{hasDraft:false},limitations:['fixture']};
   stream.end(transform(reply));
  });
 });
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(socket,resolve);});await chmod(socket,0o600);
 try{const result=await run(script,['--socket='+socket,'--expected-pid=12345']);
  assert.equal(result.code===0,success,result.err);if(success){const value=JSON.parse(result.out);assert.equal(value.admissionGranted,false);}
  checks++;
 }finally{for(const peer of peers)peer.destroy();await new Promise(resolve=>server.close(resolve));}
}
try{
 const manifest=JSON.parse(await readFile('patches/codex/0.166.0-native-inventory.manifest.json','utf8'));
 const original=await readFile(source+'/Cargo.lock','utf8');
 const normalized=normalizeNativeBuildLock(original,manifest);
 assert.equal(normalized.replaceAll('version = "0.166.0"','version = "0.0.0"'),original);checks++;
 assert.throws(()=>normalizeNativeBuildLock(original.replace('Inflector','changed-external-pin'),manifest));checks++;
 await consumer(value=>JSON.stringify(value)+'\n',true);
 await consumer(value=>JSON.stringify({...value,nonce:'f'.repeat(32)})+'\n',false);
 await consumer(value=>JSON.stringify({...value,pid:54321})+'\n',false);
 await consumer(value=>JSON.stringify({...value,admissionGranted:true})+'\n',false);
 await consumer(()=>'{broken}\n',false);
 await consumer(()=>Buffer.alloc(1024*1024+1,32),false);
 const file=root+'/plain';await writeFile(file,'sentinel',{mode:0o600});
 assert.notEqual((await run(script,['--socket='+file,'--expected-pid=12345'])).code,0);checks++;
 await chmod(root,0o755);
 assert.notEqual((await run(script,['--socket='+file,'--expected-pid=12345'])).code,0);checks++;
 await chmod(root,0o700);
 // Bootstrap refuses an existing output before it can overwrite any content.
 await writeFile(root+'/sentinel','keep');
 assert.notEqual((await run(prepare,['--source='+source,'--output='+root])).code,0);
 assert.equal(await readFile(root+'/sentinel','utf8'),'keep');checks++;
 const nested=source+'/native-test-must-not-exist';
 assert.notEqual((await run(prepare,['--source='+source,'--output='+nested])).code,0);
 await assert.rejects(lstat(nested),{code:'ENOENT'});checks++;
 const corrupt=root+'/changed-source';await mkdir(corrupt);await mkdir(corrupt+'/tui');
 for(const file of ['Cargo.toml','Cargo.lock','rust-toolchain.toml'])await copyFile(source+'/'+file,corrupt+'/'+file);
 await writeFile(corrupt+'/tui/Cargo.toml','changed source, not the pinned preimage');
 const refused=root+'/must-not-create';
 assert.notEqual((await run(prepare,['--source='+corrupt,'--output='+refused])).code,0);
 await assert.rejects(lstat(refused),{code:'ENOENT'});checks++;
 console.log(JSON.stringify({verified:true,checks,nativeProducerVerified:false,migrationVerified:false}));
}finally{await rm(root,{recursive:true,force:true});}
