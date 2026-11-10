import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtemp,mkdir,cp,symlink,writeFile,readFile,realpath,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const cli=await realpath(process.env.AUTOAPPROVE_CODEX_BIN);
const pack=path.dirname(path.dirname(cli));
const metadata=JSON.parse(await readFile(pack+'/codex-package.json','utf8'));
assert.match(metadata.version,/^0\.16[67]\./);assert.equal(metadata.entrypoint,'bin/codex');
const root=await mkdtemp('/private/tmp/aa-signed-out-'),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD||'.build/debug');
// No TUI/TTY is created. The production controller has no discoverable session
// in this unregistered random home. Authentication is synthetic and invalid.
const env={HOME:root,CODEX_HOME:root,PATH:'/usr/bin:/bin',NO_COLOR:'1',HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',ALL_PROXY:'http://127.0.0.1:9',NO_PROXY:'localhost,127.0.0.1'};
let started=false;
function run(args){return execFileSync(cli,args,{cwd:root,env,encoding:'utf8',timeout:180000});}
try {
 const releases=root+'/packages/app-server-daemon/releases';await mkdir(releases,{recursive:true});
 await cp(pack,releases+'/'+path.basename(pack),{recursive:true});await symlink('releases/'+path.basename(pack),root+'/packages/app-server-daemon/current');
 await writeFile(root+'/config.toml','cli_auth_credentials_store = "file"\ncheck_for_update_on_startup = false\n[features]\napps = false\nplugins = false\n');
 const checker=root+'/check';execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/SignedOutRecovery'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-signed-out-recovery.swift','-o',checker],{stdio:'inherit',timeout:120000});
 run(['app-server','daemon','start']);started=true;
 const enc=v=>Buffer.from(JSON.stringify(v)).toString('base64url');
 const token=enc({alg:'none',typ:'JWT'})+'.'+enc({sub:'signed-out-fixture',exp:4102444800,'https://api.openai.com/auth':{chatgpt_user_id:'signed-out-fixture',chatgpt_account_id:'fixture-workspace',chatgpt_plan_type:'pro'}})+'.synthetic-invalid-signature';
 await writeFile(root+'/auth.json',JSON.stringify({auth_mode:'chatgpt',tokens:{id_token:token,access_token:token,refresh_token:'synthetic-invalid-refresh',account_id:'fixture-workspace',login_owner_id:'fixture-login'},last_refresh:new Date().toISOString()}),{mode:0o600});
 const report=JSON.parse(execFileSync(checker,[root,cli],{cwd:root,env,encoding:'utf8',timeout:240000}));assert.equal(report.verified,true);console.log(JSON.stringify({...report,officialCLI:metadata.version}));
} finally {
 if(started)try{run(['app-server','daemon','stop']);}catch(error){console.error('Owned daemon cleanup failed');throw error;}
 await rm(root,{recursive:true,force:true});
}
