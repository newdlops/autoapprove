// Exercise the real profile preparation with the unmodified official package.
// Only this temporary home and its daemon are created; no user auth or TTY.
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {mkdtemp,mkdir,writeFile,readFile,stat,rm,realpath} from 'node:fs/promises';
import path from 'node:path';
import {promisify} from 'node:util';
import {createRequire} from 'node:module';
import http from 'node:http';
import {verifyOfficialCodexRuntime} from './codex-runtime-resource.mjs';

const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
assert.ok(option('runtime'),'Provide --runtime=/complete/official/package');
const runtime=path.resolve(option('runtime'));
const require=createRequire(import.meta.url);
const {WebSocketServer}=require(process.env.AUTOAPPROVE_WEBSOCKET_MODULE || path.resolve('.runtime/official-codex-probe-deps/node_modules/ws'));
const release=await verifyOfficialCodexRuntime(runtime);
const root=await mkdtemp('/private/tmp/aa-managed2-daemon-'),home=root+'/home';
const binary=runtime+'/bin/codex',run=promisify(execFile);
const env={HOME:root,CODEX_HOME:home,PATH:'/usr/bin:/bin',NO_COLOR:'1',
  HTTP_PROXY:'http://127.0.0.1:9',HTTPS_PROXY:'http://127.0.0.1:9',NO_PROXY:'localhost,127.0.0.1'};
let started=false,stopped=false;
let fakeServer,fakeWebSocket;
const fakeClients=new Set(),fakeCalls=[];
const helper=path.resolve(option('helper')??'.build/debug/autoapprove-checks');
async function daemon(command) {
  const {stdout}=await run(binary,['app-server','daemon',command],{env,cwd:root,timeout:30000,maxBuffer:1024*1024});
  return JSON.parse(stdout);
}
try {
  await mkdir(home+'/app-server-daemon',{recursive:true,mode:0o700});
  await writeFile(home+'/config.toml','check_for_update_on_startup=false\n[analytics]\nenabled=false\n',{mode:0o600});
  await writeFile(home+'/app-server-daemon/settings.json',JSON.stringify({shutdownGraceSeconds:0,updater:{autoUpdateEnabled:false}}),{mode:0o600});
  started=true; // A failed response can still leave our owned daemon running.
  const {stdout}=await run(helper,
    ['--bundled-runtime-prepare',runtime,home],{env,cwd:root,timeout:120000,maxBuffer:1024*1024});
  const preparation=JSON.parse(stdout);
  assert.equal(preparation.verified,true);assert.equal(preparation.serverPrepared,true);
  assert.equal(preparation.version,release.version);
  const status=await daemon('version');
  assert.equal(status.status,'running');
  for(const field of ['cliVersion','appServerVersion','managedCodexVersion'])assert.equal(status[field],release.version);
  const managed=await realpath(status.managedCodexPath);
  assert.ok(managed.startsWith(home+'/packages/app-server-daemon/releases/'));
  const {stdout:serverInspection}=await run(helper,['--official-server-inspect',home,binary],
    {env,cwd:root,timeout:30000,maxBuffer:1024*1024});
  assert.equal(JSON.parse(serverInspection).verified,true,'Connected daemon must carry the original OpenAI signature');
  assert.equal(await realpath(JSON.parse(serverInspection).reconnectExecutable),managed,
    'Reconnect must select the official client belonging to this daemon');
  const {stdout:inspection}=await run(helper,
    ['--bundled-runtime-inspect',path.dirname(path.dirname(managed))],{env,cwd:root,timeout:30000,maxBuffer:1024*1024});
  assert.equal(JSON.parse(inspection).verified,true,'Installed daemon must retain official bytes and signature');
  assert.equal((await daemon('stop')).status,'stopped');stopped=true;

  // The selected on-disk CLI remains official, but this second owned socket is
  // answered by Node. Version strings and valid WebSocket RPC are not provenance.
  const fakeHome=root+'/fake';
  await mkdir(fakeHome+'/app-server-control',{recursive:true,mode:0o700});
  fakeServer=http.createServer();fakeWebSocket=new WebSocketServer({noServer:true});
  fakeServer.on('upgrade',(request,socket,head)=>fakeWebSocket.handleUpgrade(request,socket,head,
    connection=>fakeWebSocket.emit('connection',connection)));
  fakeWebSocket.on('connection',socket=>{
    fakeClients.add(socket);socket.on('close',()=>fakeClients.delete(socket));
    socket.on('message',bytes=>{
      const message=JSON.parse(bytes);fakeCalls.push(message.method);
      if(message.method==='initialized')return;
      assert.equal(message.method,'initialize');
      socket.send(JSON.stringify({id:message.id,result:{userAgent:'codex-cli '+release.version}}));
    });
  });
  await new Promise((resolve,reject)=>{fakeServer.once('error',reject);
    fakeServer.listen(fakeHome+'/app-server-control/app-server-control.sock',resolve)});
  await assert.rejects(run(helper,['--official-server-inspect',fakeHome,binary],
    {env,cwd:root,timeout:30000,maxBuffer:1024*1024}),error=>
      error.code===1 && error.stderr.includes('연결된 서버가 OpenAI 공식 Codex인지 확인하지 못했습니다'));
  assert.ok(fakeCalls.includes('initialize'));
  assert.ok(fakeCalls.every(method=>['initialize','initialized'].includes(method)));

  // A stopped home can still select an old/fake managed executable. The
  // official parent CLI must not invoke it for version/start as a side effect.
  const legacyHome=root+'/legacy/home',selected=legacyHome+'/packages/app-server-daemon/current/bin/codex';
  await mkdir(path.dirname(selected),{recursive:true,mode:0o700});
  const legacyConfig='check_for_update_on_startup=false\n[analytics]\nenabled=false\n';
  await writeFile(legacyHome+'/config.toml',legacyConfig,{mode:0o600});
  await writeFile(selected,'#!/bin/sh\nprintf x > "$CODEX_HOME/unverified-selected-executed"\nprintf "codex-cli '+release.version+'\\n"\n',{mode:0o700});
  await assert.rejects(run(helper,['--bundled-runtime-prepare',runtime,legacyHome],
    {env:{...env,CODEX_HOME:legacyHome},cwd:root,timeout:30000,maxBuffer:1024*1024}),error=>
      error.code===1&&error.stderr.includes('기존 수정판 서버·클라이언트의 자동 교체는 지원하지 않습니다'));
  assert.equal(await stat(legacyHome+'/unverified-selected-executed').then(()=>true,error=>{if(error.code==='ENOENT')return false;throw error;}),false);
  assert.equal(await readFile(legacyHome+'/config.toml','utf8'),legacyConfig);
  console.log(JSON.stringify({verified:true,version:release.version,officialDaemonPrepared:true,
    installedPackageUnchanged:true,connectedOfficialProcessVerified:true,counterfeitServerRejected:true,
    officialReconnectClientSelected:true,
    unverifiedManagedSelectionRejected:true,modifiedSelectedPackageExecuted:false,
    ownedDaemonStopped:true,userSessionActions:0}));
} finally {
  for(const socket of fakeClients)socket.terminate();
  fakeWebSocket?.close();
  if(fakeServer?.listening)await new Promise(resolve=>fakeServer.close(resolve));
  if(started&&!stopped) {
    // Address only our private home. Never find or signal a user daemon by name.
    const result=await daemon('stop');
    assert.ok(['stopped','notRunning'].includes(result.status),'Owned fixture daemon cleanup failed');
  }
  await rm(root,{recursive:true,force:true});
}
