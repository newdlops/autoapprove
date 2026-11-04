// Owned synthetic auth metadata only; no user credentials or real authentication.
import assert from 'node:assert/strict';
import {spawn,execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,rm,realpath,stat} from 'node:fs/promises';
import {createInterface} from 'node:readline';
import {createServer} from 'node:http';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
assert.ok(process.env.AUTOAPPROVE_CODEX_BIN&&path.isAbsolute(process.env.AUTOAPPROVE_CODEX_BIN),'Set AUTOAPPROVE_CODEX_BIN to an absolute native CLI path');
const cli=await realpath(process.env.AUTOAPPROVE_CODEX_BIN);
assert.equal(execFileSync(cli,['--version'],{encoding:'utf8'}).trim(),'codex-cli 0.166.0');
const build=path.resolve('.build/debug'),root=await mkdtemp('/private/tmp/aa-auth-isolation-'),children=[];
let loopbackRequests=0;
const provider=createServer((_req,res)=>{loopbackRequests++;res.writeHead(503);res.end('{}');});
provider.on('connect',(_req,socket)=>{loopbackRequests++;socket.end('HTTP/1.1 503 Fixture only\r\n\r\n');});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function stop(child){
 if(!child||child.exitCode!==null||child.signalCode!==null)return;
 try{process.kill(-child.pid,'SIGTERM');}catch{}
 const deadline=Date.now()+3000;
 while(child.exitCode===null&&child.signalCode===null&&Date.now()<deadline)await delay(25);
 if(child.exitCode===null&&child.signalCode===null){
  const ended=new Promise(resolve=>child.once('exit',resolve));
  try{process.kill(-child.pid,'SIGKILL');}catch{}await ended;
 }
}
function fakeAuth(user){
 const encode=value=>Buffer.from(JSON.stringify(value)).toString('base64url');
 const claims={sub:user,email:user+'@example.invalid',exp:4102444800,
  'https://api.openai.com/auth':{chatgpt_user_id:user,chatgpt_account_id:'owned-workspace-'+user,chatgpt_plan_type:'pro'}};
 const token=encode({alg:'none',typ:'JWT'})+'.'+encode(claims)+'.synthetic-invalid-signature';
 return JSON.stringify({auth_mode:'chatgpt',tokens:{id_token:token,access_token:token,
  refresh_token:'owned-invalid-refresh',account_id:'owned-workspace-'+user,login_owner_id:'owned-login-'+user},last_refresh:new Date().toISOString()});
}
try{
 await new Promise((resolve,reject)=>{provider.once('error',reject);provider.listen(0,'127.0.0.1',resolve);});
 const url='http://127.0.0.1:'+provider.address().port;
 const homes=[root+'/a',root+'/b'];
 for(const home of homes){
  await mkdir(home,{mode:0o700});
  await writeFile(home+'/config.toml',`cli_auth_credentials_store="file"\nchatgpt_base_url="${url}"\ncheck_for_update_on_startup=false\n[features]\napps=false\nplugins=false\n`,{mode:0o600});
 }
 await writeFile(homes[0]+'/auth.json',fakeAuth('owned-a'),{mode:0o600});
 await writeFile(homes[1]+'/auth.json',fakeAuth('owned-b'),{mode:0o600});
 const env=home=>({HOME:root,CODEX_HOME:home,PATH:'/usr/bin:/bin',NO_COLOR:'1',HTTP_PROXY:url,HTTPS_PROXY:url,NO_PROXY:'127.0.0.1,localhost'});
 const helper=root+'/check';
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/CredentialFile'),
  '-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),
  'Tests/fixtures/codex-credential-file-check.swift','-o',helper],{stdio:'inherit',timeout:120000});
 const capture=()=>JSON.parse(execFileSync(helper,['capture',...homes],{encoding:'utf8',timeout:5000}));
 const verify=value=>execFileSync(helper,['verify'],{input:JSON.stringify(value),encoding:'utf8',stdio:['pipe','pipe','pipe'],timeout:5000});
 async function start(home){
  // A controlled launch pins file storage at startup; arbitrary existing servers
  // cannot be assigned this runtime backend merely from config/read.
  const child=spawn(cli,['app-server','-c','cli_auth_credentials_store="file"'],{cwd:home,env:env(home),detached:true,stdio:['pipe','pipe','pipe']});children.push(child);
  child.stderr.resume();let sequence=0;const pending=new Map();
  const rejectPending=()=>{for(const entry of pending.values()){clearTimeout(entry.timer);entry.reject(Error('Owned auth server closed'));}pending.clear();};
  child.once('error',rejectPending);child.once('exit',rejectPending);
  const lines=createInterface({input:child.stdout});
  lines.on('line',line=>{let message;try{message=JSON.parse(line);}catch{return;}
   const entry=pending.get(message.id);if(!entry)return;pending.delete(message.id);clearTimeout(entry.timer);
   message.error?entry.reject(Error('Owned RPC rejected '+entry.method+' ('+message.error.code+')')):entry.resolve(message.result);
  });
  const request=(method,params={})=>new Promise((resolve,reject)=>{
   const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(Error('Owned RPC timed out '+method));},15000);
   pending.set(id,{resolve,reject,timer,method});child.stdin.write(JSON.stringify({id,method,params})+'\n');
  });
  await request('initialize',{clientInfo:{name:'owned_auth_isolation',version:'1'},capabilities:{experimentalApi:true}});
  child.stdin.write(JSON.stringify({method:'initialized'})+'\n');
  return {child,request};
 }
 const a=await start(homes[0]),b=await start(homes[1]);
 const users=async server=>(await server.request('accountSession/list',{refreshWorkspaceMetadata:false})).sessions.map(value=>value.userId).sort();
 assert.deepEqual(await users(a),['owned-a']);assert.deepEqual(await users(b),['owned-b']);
 const snapshots=capture(),bBytes=await readFile(homes[1]+'/auth.json'),bIdentity=await stat(homes[1]+'/auth.json');
 verify(snapshots[0]);verify(snapshots[1]);
 await a.request('account/logout');
 assert.equal(await stat(homes[0]+'/auth.json').then(()=>true,error=>{if(error.code==='ENOENT')return false;throw error;}),false);
 assert.throws(()=>verify(snapshots[0]),error=>error.status===1&&error.signal===null&&error.stderr.includes('Owned credential witness rejected'),
  'Removed source credential must invalidate its witness without crashing the helper');
 verify(snapshots[1]);assert.deepEqual(await readFile(homes[1]+'/auth.json'),bBytes);
 assert.deepEqual(await users(b),['owned-b']);
 assert.deepEqual(await users(a),[]);
 await stop(a.child);
 await writeFile(homes[0]+'/auth.json',fakeAuth('owned-a-next'),{mode:0o600});
 const next=await start(homes[0]);assert.deepEqual(await users(next),['owned-a-next']);
 assert.deepEqual(await users(b),['owned-b']);verify(snapshots[1]);capture();
 const bAfter=await stat(homes[1]+'/auth.json');assert.equal(bAfter.dev,bIdentity.dev);assert.equal(bAfter.ino,bIdentity.ino);
 assert.deepEqual(await readFile(homes[1]+'/auth.json'),bBytes);
 console.log(JSON.stringify({verified:true,cliVersion:'0.166.0',ownedServersStarted:3,
  fileWitnessesIndependent:true,logoutInvalidatesOnlySourceWitness:true,destinationFileAndAccountUnchanged:true,
  changedSourceMetadataObservedAfterRestart:true,syntheticAuthOnly:true,realAuthenticationPerformed:false,
  userHomesTouched:false,loopbackRequests}));
}finally{
 for(const child of children)await stop(child);
 provider.closeAllConnections();await new Promise(resolve=>provider.close(resolve));
 await rm(root,{recursive:true,force:true});
}
