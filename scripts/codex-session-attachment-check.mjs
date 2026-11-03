import {mkdtemp,mkdir,symlink,rm} from 'node:fs/promises';
import {execFileSync,spawn} from 'node:child_process';
import path from 'node:path';
import net from 'node:net';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const root=await mkdtemp('/private/tmp/aa-attachment-'),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD??'.build/debug'),server=net.createServer();
const sockets=new Set();server.on('connection',s=>{sockets.add(s);s.on('close',()=>sockets.delete(s))});
try {
 await mkdir(root+'/한글 home/.codex/app-server-control',{recursive:true});await symlink(root+'/daemon.sock',root+'/한글 home/.codex/app-server-control/app-server-control.sock');
 execFileSync('/usr/bin/xcrun',['clang','Tests/fixtures/codex-session-attachment.c','-o',root+'/codex'],{stdio:'inherit'});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AttachmentPTY'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-session-attachment-check.swift','-o',root+'/check'],{stdio:'inherit',timeout:120000});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(root+'/daemon.sock',resolve)});
 const child=spawn(root+'/check',[root],{stdio:['ignore','pipe','inherit']});let output='';child.stdout.on('data',d=>output+=d);
 const status=await new Promise(resolve=>child.on('close',resolve));if(status!==0)throw Error('Owned PTY attachment failed');
 const report=JSON.parse(output.trim());if(report.verified!==true)throw Error('Missing verification');console.log(JSON.stringify(report));
}finally{for(const s of sockets)s.destroy();await new Promise(resolve=>server.close(resolve));await rm(root,{recursive:true,force:true,maxRetries:5,retryDelay:100})}
