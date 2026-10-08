// Signed isolated applications exercise production discovery, download, staging,
// cooperative restart and health confirmation. No user terminal receives input.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,readFile,writeFile,cp,readdir,rm} from 'node:fs/promises';
import path from 'node:path';
import http from 'node:http';
import net from 'node:net';
import {createHash} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
import {signApp} from './sign-app.mjs';

const artifact=path.resolve(process.argv[2]||'dist/AutoApprove.app');
const root=path.resolve('.runtime/qa/lan-update'),build=path.resolve('.build/release');
await mkdir(root,{recursive:true});
const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(n=>n.endsWith('.swift.o')).map(n=>path.join(build,'AutoApproveCore.build',n));
const fixture=path.join(root,'manager'),cache=path.resolve('.build/cache/LANUpdate');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/lan-update-manager.swift','-o',fixture],{stdio:'inherit'});
const children=[],pids=new Set(),servers=[];
const ports=[];
while(ports.length<8){
  const reservation=net.createServer();await new Promise(resolve=>reservation.listen(0,'127.0.0.1',resolve));
  const port=reservation.address().port;await new Promise(resolve=>reservation.close(resolve));
  if(!ports.includes(port))ports.push(port);
}
const release=JSON.parse(await readFile(path.join(artifact,'Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json')));
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function state(port){return (await fetch('http://127.0.0.1:'+port+'/api/state',{signal:AbortSignal.timeout(2500)})).json();}
async function appState(app){
  const web=JSON.parse(await readFile(path.join(app.directory,'fixture-web.json'),'utf8'));
  if(web.ready&&web.port)app.port=web.port;
  return state(app.port);
}
async function waitFor(check,seconds=90){const deadline=Date.now()+seconds*1000;let last;while(Date.now()<deadline){try{const result=await check();if(result)return result;}catch(e){last=e;}await delay(250);}throw new Error('LAN update check timed out'+(last?': '+last.message:''));}
async function application(name,{port,peer='',low=false,enabled=true,lidClosed=false,foreign=false}){
  const directory=path.join(root,name),app=path.join(directory,'AutoApprove.app'),home=path.join(directory,'runtime');
  await rm(directory,{recursive:true,force:true});await mkdir(directory,{recursive:true});await cp(artifact,app,{recursive:true});
  await cp(fixture,path.join(app,'Contents/MacOS/AutoApproveApp'));
  if(low){
    const plist=path.join(app,'Contents/Info.plist');
    execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleShortVersionString 0.2.52',plist]);
    execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleVersion 63',plist]);
    await writeFile(path.join(app,'Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json'),JSON.stringify({version:'0.2.52',build:63,api:1}));
  }
  await signApp(app,{allowProvisioning:false});
  if(foreign)execFileSync('/usr/bin/codesign',['--force','--deep','--sign','-',app],{stdio:['ignore','pipe','pipe']});
  await writeFile(path.join(directory,'fixture-config.json'),JSON.stringify({port,peer,home,enabled,lidClosed}));
  return {directory,app,port};
}
async function start(app){
  const log=await import('node:fs');const out=log.openSync(path.join(app.directory,'stdout.txt'),'w'),err=log.openSync(path.join(app.directory,'stderr.txt'),'w');
  const child=spawn(path.join(app.app,'Contents/MacOS/AutoApproveApp'),[],{stdio:['ignore',out,err]});children.push(child);pids.add(child.pid);log.closeSync(out);log.closeSync(err);
  try { await waitFor(()=>appState(app),20); }
  catch(error) { console.error('Isolated app status:',await readFile(path.join(app.directory,'fixture-web.json'),'utf8').catch(()=>'(unavailable)'));throw error; }
  return child;
}
async function proxy(port,manifest,archive,options={}){
  const stats={offsets:[],manifests:0,dropped:false};
  const server=http.createServer((request,response)=>{
    let body,type='application/json',status=200;
    const url=new URL(request.url,'http://localhost');
    if(url.pathname==='/api/discovery')body=Buffer.from(JSON.stringify({service:'autoapprove',version:1,id:manifest.nodeID,name:'isolated source',release:manifest.release,port,urls:options.urls||['http://127.0.0.1:'+port]}));
    else if(url.pathname==='/api/update/manifest'){
      stats.manifests++;
      if(options.failManifest){request.socket.destroy();return;}
      body=Buffer.from(JSON.stringify(manifest));
    }
    else if(url.pathname==='/api/update/chunk'){
      const offset=Number(url.searchParams.get('offset'));stats.offsets.push(offset);
      if(offset===options.dropOffset&&!stats.dropped){stats.dropped=true;request.socket.destroy();return;}
      body=archive.subarray(offset,Math.min(offset+256*1024,archive.length));type='application/zip';
    }
    else {status=404;body=Buffer.from('{}');}
    response.writeHead(status,{'Content-Type':type,'Content-Length':body.length});response.end(body);
  });
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(port,'127.0.0.1',resolve);});servers.push(server);
  return stats;
}
const checks=[];
try{
  const high=await application('source',{port:0});await start(high);
  const low=await application('recipient',{port:0,peer:'http://127.0.0.1:'+high.port,low:true,lidClosed:true});const old=await start(low);
  const pending=await waitFor(async()=>{const s=await appState(low);if(s.update?.phase==='failed')throw new Error(s.update.detail);return s.update?.phase==='waiting'?s:null;});
  assert.equal(pending.release.version,'0.2.52');assert.match(pending.update.detail,/덮개/);assert.equal(old.exitCode,null);
  checks.push('closed lid defers a fully verified update without restarting the manager');
  const settings=JSON.parse(await readFile(path.join(low.directory,'fixture-config.json')));settings.lidClosed=false;await writeFile(path.join(low.directory,'fixture-config.json'),JSON.stringify(settings));
  await waitFor(async()=>{const s=await appState(low);return s.release.version===release.version&&s.release.build===release.build;});
  await waitFor(async()=>{const names=await readdir(low.directory);return !names.some(n=>n.startsWith('.AutoApprove-backup-'));});
  assert.equal(old.exitCode,0);const restarted=Number(await readFile(path.join(low.directory,'fixture-pid'),'utf8'));assert.notEqual(restarted,old.pid);pids.add(restarted);
  pids.delete(old.pid);
  checks.push('two signed applications discover the newest LAN version, pull chunks, verify, replace, restart and confirm web health');
  const manifest=await (await fetch('http://127.0.0.1:'+high.port+'/api/update/manifest')).json();
  const archive=await readFile(path.join(high.directory,'runtime/updates/offer/offer.zip'));
  assert.equal(createHash('sha256').update(archive).digest('hex'),manifest.sha256);
  const corrupt=Buffer.from(archive);corrupt[Math.floor(corrupt.length/2)]^=1;await proxy(ports[2],manifest,corrupt);
  const tampered=await application('tampered',{port:0,peer:'http://127.0.0.1:'+ports[2],low:true});const tamperedProcess=await start(tampered);
  const failure=await waitFor(async()=>{const s=await appState(tampered);return s.update?.phase==='failed'?s:null;});
  assert.match(failure.update.detail,/체크섬/);assert.equal(failure.release.version,'0.2.52');assert.equal(tamperedProcess.exitCode,null);
  checks.push('a modified transfer is rejected before application replacement');
  const foreign=await application('foreign',{port:ports[4],foreign:true});
  const foreignZip=path.join(root,'foreign.zip');execFileSync('/usr/bin/ditto',['-c','-k','--norsrc','--keepParent',foreign.app,foreignZip]);
  const foreignBytes=await readFile(foreignZip),foreignManifest={...manifest,size:foreignBytes.length,sha256:createHash('sha256').update(foreignBytes).digest('hex')};
  await proxy(ports[5],foreignManifest,foreignBytes);
  const untrusted=await application('untrusted',{port:0,peer:'http://127.0.0.1:'+ports[5],low:true});const untrustedProcess=await start(untrusted);
  const untrustedState=await waitFor(async()=>{const s=await appState(untrusted);return s.update?.phase==='failed'?s:null;});
  assert.match(untrustedState.update.detail,/게시자 서명/);assert.equal(untrustedProcess.exitCode,null);
  checks.push('a different signature is rejected even when the advertised checksum matches');
  const disabled=await application('disabled',{port:0,peer:'http://127.0.0.1:'+high.port,low:true,enabled:false});const disabledProcess=await start(disabled);
  await delay(3500);const off=await appState(disabled);assert.equal(off.update.phase,'off');assert.equal(off.release.version,'0.2.52');assert.equal(disabledProcess.exitCode,null);
  checks.push('the saved disabled preference prevents automatic installation');
  const interrupted=await proxy(ports[6],manifest,archive,{dropOffset:256*1024});
  const resumed=await application('resumed',{port:0,peer:'http://127.0.0.1:'+ports[6],low:true,lidClosed:true});await start(resumed);
  await waitFor(async()=>{const s=await appState(resumed);return s.update?.phase==='waiting'?s:null;});
  assert.equal(interrupted.dropped,true);assert.equal(interrupted.offsets.filter(offset=>offset===0).length,1);
  assert.equal(interrupted.offsets.filter(offset=>offset===256*1024).length,2);
  checks.push('a disconnected chunk retries within seconds and resumes without downloading the completed prefix again');
  const backup=await proxy(ports[7],manifest,archive);
  const failedRoute=await proxy(ports[1],manifest,archive,{failManifest:true,urls:['http://127.0.0.1:'+ports[1],'http://127.0.0.1:'+ports[7]]});
  const alternate=await application('alternate',{port:0,peer:'http://127.0.0.1:'+ports[1],low:true,lidClosed:true});await start(alternate);
  await waitFor(async()=>{const s=await appState(alternate);return s.update?.phase==='waiting'?s:null;});
  assert.ok(failedRoute.manifests>0);assert.ok(backup.manifests>0);assert.ok(backup.offsets.length>0);
  checks.push('healthy discovery with a failed update route recovers the manifest and chunks over the same verified node on another address');
  const report={result:'PASS',version:release,checks};await writeFile(path.join(root,'verification.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{
  for(const pid of pids){
    try{
      const executable=execFileSync('/bin/ps',['-p',String(pid),'-o','comm='],{encoding:'utf8',stdio:['ignore','pipe','ignore']}).trim();
      if(executable.startsWith(root+path.sep)&&executable.endsWith('/Contents/MacOS/AutoApproveApp'))process.kill(pid,'SIGTERM');
    }catch{}
  }
  for(const child of children){if(child.exitCode===null)child.kill('SIGTERM');}
  await Promise.all(servers.map(server=>new Promise(resolve=>server.close(resolve))));
}
