import assert from'node:assert/strict';import{mkdtemp,mkdir,readFile,writeFile,rm,readdir,access}from'node:fs/promises';import{spawn,execFileSync}from'node:child_process';import{createHash}from'node:crypto';import path from'node:path';import{coreLinkArguments,coreSwiftObjects}from'./swift-core-link.mjs';
const cli=process.env.AUTOAPPROVE_CODEX_BIN;assert.ok(cli&&path.isAbsolute(cli),'Set AUTOAPPROVE_CODEX_BIN to the installed native CLI');const version=execFileSync(cli,['--version'],{encoding:'utf8'}).trim();assert.match(version,/^codex-cli 0\.166\./);
const root=await mkdtemp('/private/tmp/aa-inspection-live-'),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD??'.build/debug'),children=[],results=[];
const env={...process.env};for(const key of['OPENAI_API_KEY','CODEX_ACCESS_TOKEN','CHATGPT_ACCESS_TOKEN','CHATGPT_ACCOUNT_ID','CODEX_HOME','NODE_OPTIONS'])delete env[key];
async function authFiles(home){const rows={};async function scan(dir){for(const entry of await readdir(dir,{withFileTypes:true})){const file=path.join(dir,entry.name);if(entry.isDirectory()&&!['logs','sessions','tmp','shell_snapshots'].includes(entry.name))await scan(file);else if(entry.isFile()&&/auth|account/.test(entry.name)&&!/-wal$|-shm$|\.lock$/.test(entry.name)){rows[path.relative(home,file)]=createHash('sha256').update(await readFile(file)).digest('hex');}}}await scan(home);return rows;}
try{
 const check=root+'/check';execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AccountInspectionLive'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-account-inspection-live-check.swift','-o',check],{stdio:'inherit',timeout:120000});
 for(const name of['a','b']){
  const home=root+'/'+name,socket=home+'/app-server-control/app-server-control.sock';await mkdir(home+'/app-server-control',{recursive:true});
  await writeFile(home+'/config.toml','cli_auth_credentials_store = "file"\n[features]\nhooks = false\n');
  const child=spawn(cli,['app-server','--listen','unix://'+socket],{cwd:home,env:{...env,CODEX_HOME:home},detached:true,stdio:'ignore'});children.push(child);
  const end=Date.now()+15000;let ready=false;while(Date.now()<end){try{await access(socket);ready=true;break;}catch{}if(child.exitCode!==null)throw Error('Owned app server exited');await new Promise(r=>setTimeout(r,50));}assert.ok(ready);
  const before=await authFiles(home),t=Date.now();
  const report=JSON.parse(execFileSync(check,[home,cli],{encoding:'utf8',env:{...env,CODEX_HOME:home},timeout:20000}));assert.equal(report.verified,true);
  const after=await authFiles(home);assert.deepEqual(after,before,'Read-only inspection must not mutate authentication storage');
  const goal=home+'/goals_1.sqlite';let goalRows=0;try{await access(goal);goalRows=Number(execFileSync('/usr/bin/sqlite3',['-readonly',goal,'SELECT COUNT(*) FROM thread_goals'],{encoding:'utf8'}).trim());}catch(e){if(e.code!=='ENOENT')throw e;}assert.equal(goalRows,0);
  results.push({home:name,seconds:(Date.now()-t)/1000,comparison:report.comparison,authStorageUnchanged:true,goalRows});
 }
 console.log(JSON.stringify({verified:true,actualInstalledCodex:version,twoOwnedHomes:true,realCredentialsUsed:false,existingSessionsTouched:false,results}));
}finally{for(const child of children){if(child.exitCode===null&&child.signalCode===null){try{process.kill(-child.pid,'SIGTERM')}catch{}await new Promise(r=>{child.once('close',r);setTimeout(r,1000)});if(child.exitCode===null&&child.signalCode===null){try{process.kill(-child.pid,'SIGKILL')}catch{}}}}await rm(root,{recursive:true,force:true});}

