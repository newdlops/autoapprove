import assert from 'node:assert/strict';
import {mkdtemp,mkdir,symlink,rm} from 'node:fs/promises';
import {execFileSync,spawn} from 'node:child_process';
import net from 'node:net';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const root=await mkdtemp('/private/tmp/aa-discovery-'),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD??'.build/debug');
const cli=root+'/codex',check=root+'/check';let child;
const sockets=new Set(),server=net.createServer(s=>{sockets.add(s);s.on('close',()=>sockets.delete(s));});
try {
 execFileSync('/usr/bin/xcrun',['clang','Tests/fixtures/codex-server-discovery.c','-o',cli],{stdio:'inherit',timeout:30000});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ServerDiscovery'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-server-discovery-check.swift','-o',check],{stdio:'inherit',timeout:120000});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(root+'/daemon.sock',resolve);});
 let checks=0;
 for(const [index,alias] of ['codex',cli].entries()) {
  const home=root+(index===0?'/한글 공백 홈/.codex':'/alternate/home/.codex');await mkdir(home+'/app-server-control',{recursive:true});await symlink(root+'/daemon.sock',home+'/app-server-control/app-server-control.sock');
  const ready=new Promise(resolve=>server.once('connection',s=>s.once('data',resolve)));
  child=spawn(cli,[root+'/daemon.sock',cli,alias],{env:{HOME:root,CODEX_HOME:home,PATH:'/usr/bin:/bin'},stdio:['pipe','pipe','pipe']});
  let output='',errors='';child.stderr.on('data',d=>errors+=d);
  const pid=await new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>reject(Error('Owned child readiness timeout')),5000);
   child.stdout.on('data',d=>{output+=d;if(output.includes('\n')){clearTimeout(timer);resolve(output.trim());}});child.once('error',reject);
  });
  await ready;
  try {const result=execFileSync(check,[pid,home,cli,alias],{encoding:'utf8',timeout:20000});assert.equal(JSON.parse(result).verified,true);checks++;}
  finally {const exited=new Promise(resolve=>child.once('exit',resolve));child.stdin.end();await exited;child=undefined;}
 }
 console.log(JSON.stringify({verified:true,actualProcessDiscoveryProfiles:checks,userTerminalActions:0,controlRPC:0}));
} finally {
 if(child&&child.exitCode===null){child.stdin.end();await new Promise(resolve=>child.once('exit',resolve));}
 for(const s of sockets)s.destroy();await new Promise(resolve=>server.close(resolve));await rm(root,{recursive:true,force:true});
}
