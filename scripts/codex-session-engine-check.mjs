import {mkdtemp,mkdir,symlink,rm,realpath} from 'node:fs/promises';
import {execFileSync,spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import path from 'node:path';
import net from 'node:net';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const root=await mkdtemp('/private/tmp/aa-engine-attach-'),cwd=await realpath(root),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD??'.build/debug'),sockets=new Set(),requests=[];
const server=net.createServer(socket=>{
 sockets.add(socket);socket.on('close',()=>sockets.delete(socket));let buffer=Buffer.alloc(0),upgraded=false;
 const reply=value=>{const data=Buffer.from(JSON.stringify(value)),head=data.length<126?Buffer.from([0x81,data.length]):Buffer.from([0x81,126,data.length>>8,data.length&255]);socket.write(Buffer.concat([head,data]));};
 socket.on('data',chunk=>{
  buffer=Buffer.concat([buffer,chunk]);
  if(!upgraded){const end=buffer.indexOf('\r\n\r\n');if(end<0)return;const text=buffer.subarray(0,end).toString(),key=text.match(/Sec-WebSocket-Key:\s*([^\r]+)/i)?.[1];if(!key){socket.destroy();return;}socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+createHash('sha1').update(key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64')+'\r\n\r\n');buffer=buffer.subarray(end+4);upgraded=true;}
  while(buffer.length>=2){let length=buffer[1]&127,offset=2;if(length===127){socket.destroy();return;}if(length===126){if(buffer.length<4)return;length=buffer.readUInt16BE(2);offset=4;}const masked=Boolean(buffer[1]&128),maskSize=masked?4:0;if(buffer.length<offset+maskSize+length)return;const opcode=buffer[0]&15,mask=buffer.subarray(offset,offset+maskSize),data=Buffer.from(buffer.subarray(offset+maskSize,offset+maskSize+length));if(masked)for(let i=0;i<data.length;i++)data[i]^=mask[i%4];buffer=buffer.subarray(offset+maskSize+length);if(opcode===8){socket.end();return;}if(opcode!==1)continue;const message=JSON.parse(data.toString());requests.push(message.method);if(message.id==null)continue;let result;
   switch(message.method){case 'initialize':result={};break;case 'thread/read':if(message.params.threadId!=='00000000-0000-4000-8000-000000000061'){reply({id:message.id,error:{code:-32000,message:'Unknown fixture thread'}});continue;}result={thread:{id:message.params.threadId,cwd,status:{type:'idle'},source:'cli',threadSource:'user',ephemeral:false,parentThreadId:null}};break;case 'thread/list':result={data:[],nextCursor:null};break;case 'thread/goal/get':result={goal:null};break;case 'thread/queue/list':result={items:[],nextCursor:null};break;default:reply({id:message.id,error:{code:-32601,message:'Owned fixture method unavailable'}});continue;}
   reply({id:message.id,result});
  }
 });
});
try {
 await mkdir(root+'/home/.codex/app-server-control',{recursive:true});await symlink(root+'/daemon.sock',root+'/home/.codex/app-server-control/app-server-control.sock');
 execFileSync('/usr/bin/xcrun',['clang','Tests/fixtures/codex-session-engine.c','-o',root+'/codex'],{stdio:'inherit'});
 if(process.argv.includes('--tool-hosts')){await mkdir(root+'/ChatGPT.app/Contents/Resources/cua_node/bin',{recursive:true});await symlink(root+'/codex',root+'/ChatGPT.app/Contents/Resources/cua_node/bin/node');}
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AttachmentEngine'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/codex-session-engine-check.swift','-o',root+'/check'],{stdio:'inherit',timeout:120000});
 await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(root+'/daemon.sock',resolve)});
 const args=[root,...process.argv.slice(2).filter(v=>['--expect-unresolved','--wrong-thread','--goal-wait','--login-shell','--manual-reconnect','--screen-disconnected','--no-shell','--wrong-window','--busy-replacement','--prepare-fails','--profile-command','--definite-retry','--tool-hosts','--auto-tool-wait','--cancel-before-exit','--cancel-and-retry','--linger-tool-host'].includes(v))],child=spawn(root+'/check',args,{stdio:['ignore','pipe','inherit']});let output='';child.stdout.on('data',d=>output+=d);
 const status=await new Promise(resolve=>child.on('close',resolve));if(status!==0)throw Error('Production engine fixture failed');
 const report=JSON.parse(output.trim());if(!report.verified)throw Error('Missing engine proof');console.log(JSON.stringify({...report,controlRequests:requests}));
 }finally{
 // The PTY manager can kill its foreground group before the CLI reaps its
 // separate-group helper. Clean only this invocation's exact fixture paths.
 const ownedRoots=new Set([root,cwd,root.replace(/^\/private\/tmp\//,'/tmp/')]);
 const owned=()=>execFileSync('/bin/ps',['-axo','pid=,comm='],{encoding:'utf8'}).split('\n').map(v=>v.trim().match(/^(\d+)\s+(.+)$/)).filter(Boolean).filter(v=>[...ownedRoots].some(r=>v[2]===r+'/ChatGPT.app/Contents/Resources/cua_node/bin/node')).map(v=>Number(v[1]));
 for(const pid of owned()){try{process.kill(pid,'SIGTERM')}catch(error){if(error.code!=='ESRCH')throw error}}
 const deadline=Date.now()+4000;while(owned().length&&Date.now()<deadline)await new Promise(r=>setTimeout(r,50));
 if(owned().length)throw Error('Owned fixture helpers did not stop');
 for(const socket of sockets)socket.destroy();if(server.listening)await new Promise(resolve=>server.close(resolve));await rm(root,{recursive:true,force:true,maxRetries:8,retryDelay:100})}
