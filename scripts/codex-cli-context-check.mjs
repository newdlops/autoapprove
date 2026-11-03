import assert from'node:assert/strict';import{mkdtemp,mkdir,readFile,writeFile,chmod,symlink,rm}from'node:fs/promises';import{execFileSync,spawn}from'node:child_process';import{once}from'node:events';import net from'node:net';import path from'node:path';import{coreLinkArguments,coreSwiftObjects}from'./swift-core-link.mjs';
const root=await mkdtemp('/private/tmp/aa-cli-context-'),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD??'.build/debug'),server=net.createServer(s=>s.destroy()),results=[];
try{
 const nativeDir=root+"/native '$(literal)";await mkdir(nativeDir);const native=nativeDir+'/codex',check=root+'/check';
 execFileSync('/usr/bin/xcrun',['clang','Tests/fixtures/codex-native-cli.c','-o',native],{stdio:'inherit',timeout:30000});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/CLIContext'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-cli-context-check.swift','-o',check],{stdio:'inherit',timeout:120000});
 await new Promise((r,j)=>{server.once('error',j);server.listen(root+'/daemon.sock',r);});
 for(const kind of['native','wrapper','native-login','witness-login']){
  const user=root+'/'+kind+" user '$(literal)",home=root+'/'+kind+" home '$(literal)",bin=user+'/bin',shellLog=user+'/shell-starts',log=user+'/cli-calls';await mkdir(bin,{recursive:true});await mkdir(home+'/app-server-control',{recursive:true});await symlink(root+'/daemon.sock',home+'/app-server-control/app-server-control.sock');await symlink(process.execPath,bin+'/node');
  const quote=s=>"'"+s.replaceAll("'","'\\''")+"'";
  await writeFile(user+'/.zshrc',"print shell-start >> "+quote(shellLog)+"\nexport PATH="+quote(bin)+":/usr/bin:/bin\n/bin/sleep 0.1\nprint 'synthetic startup banner'\n");
  const wrapper=bin+'/codex';
  await writeFile(wrapper,"#!/usr/bin/env node\nconst cp=require('node:child_process');const r=cp.spawnSync("+JSON.stringify(native)+",process.argv.slice(2),{env:process.env,encoding:'utf8'});process.stdout.write(r.stdout||'');process.stderr.write(r.stderr||'');process.exit(r.status??69);\n");await chmod(wrapper,0o700);
  const executable=kind==='wrapper'?wrapper:native;
  const expectedPath=bin+':/usr/bin:/bin:/aa-owned-witness-only';let hold;
  try{
   if(kind==='witness-login'){hold=spawn(native,['--hold'],{env:{...process.env,CODEX_HOME:home,PATH:expectedPath,AA_CLI_FIXTURE_LOG:log},stdio:'ignore'});await new Promise(r=>setTimeout(r,100));assert.ok(hold.pid);}
   const output=execFileSync(check,[user,executable,home,...kind==='native-login'?['login']:hold?[String(hold.pid)]:[]],{encoding:'utf8',env:{...process.env,PATH:'/usr/bin:/bin',ZDOTDIR:user,AA_CLI_FIXTURE_LOG:log,...hold?{AA_EXPECT_PATH:expectedPath}:{}},timeout:15000});assert.equal(JSON.parse(output).verified,true);
  }finally{if(hold&&hold.exitCode===null&&hold.signalCode===null){const closed=once(hold,'close');hold.kill('SIGTERM');await closed;}}
  const calls=(await readFile(log,'utf8')).trim().split('\n');assert.deepEqual(calls,kind.endsWith('login')?['login status']:['--version','app-server daemon version','features list']);
  const shells=(await readFile(shellLog,'utf8').catch(()=>'' )).trim().split('\n').filter(Boolean).length;results.push({kind,shells,commands:calls.length,maximum:kind==='wrapper'?1:0});
 }
 console.log(JSON.stringify({measurements:results}));for(const x of results)assert.ok(x.shells<=x.maximum,x.kind+' inspection starts '+x.shells+' login shells; expected at most '+x.maximum);
 console.log(JSON.stringify({verified:true,nativeShells:0,wrapperShellsAtMost:1,literalHomeAndExecutable:true,originalWitnessPATH:true,realServiceCommands:8,realAccountChanges:0}));
}finally{if(server.listening)await new Promise(r=>server.close(r));await rm(root,{recursive:true,force:true});}

