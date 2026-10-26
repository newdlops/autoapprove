// Actual workerd/DO + production Swift WS agent/gateway, entirely local.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {createRequire} from 'node:module';
import {createServer} from 'node:http';
import {createServer as createTLS} from 'node:https';
import {connect} from 'node:net';
import {Readable} from 'node:stream';
import {createHash} from 'node:crypto';
import {randomUUID} from 'node:crypto';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/cloudflare-https/release'),out=path.resolve(option('output')||'.runtime/cf-workers-188/transport');
const dependencies=path.resolve(option('dependencies')||'.runtime/cf-workers-188/dependencies');
const require=createRequire(dependencies+'/package.json'),{Miniflare,Log,LogLevel,convertV4MiniflareOptions}=require('miniflare'),{WebSocketServer}=require('ws');
const root=await mkdtemp('/private/tmp/aa-relay-');await mkdir(out,{recursive:true,mode:0o700});
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,time=30000){const deadline=Date.now()+time;while(!await test()){if(Date.now()>deadline)throw Error(label);await wait(30);}}
const origin='https://relay.tunnel-qa.invalid',host=new URL(origin).hostname,key=Buffer.alloc(32,91).toString('base64url');
const hash=createHash('sha256').update(key).digest('hex');let mf,server,fixture,tls,proxy,browser,page,drop,connections=0;const sockets=new Set(),requests=[],proxySockets=new Set(),errors=[];let stage='startup';
try{
 mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'relay',modules:true,scriptPath:path.resolve('Sources/AutoApproveCore/Resources/CloudflareRelay/relay.mjs'),compatibilityDate:'2026-10-01',
  durableObjects:{TUNNEL:{className:'TunnelRoom',useSQLite:true}},bindings:{PUBLIC_HOST:host,CONNECTOR_HASH:hash}}],log:new Log(LogLevel.ERROR)}));
 await mf.ready;
 const handle=async(req,res)=>{
  const abort=new AbortController();res.on('close',()=>abort.abort());
  try{
   let body;for await(const chunk of req)body=body?Buffer.concat([body,chunk]):Buffer.from(chunk);
   const actualHost=req.headers.host?.startsWith('127.0.0.1:')?host:req.headers.host;
   let requestID;try{requestID=JSON.parse(body||'{}').requestID;}catch{}
   requests.push({method:req.method,path:req.url,...(requestID?{requestID}:{})});
   const response=await mf.dispatchFetch('https://'+actualHost+req.url,{method:req.method,headers:{...req.headers,host:actualHost},...(body?.length?{body}:{}),signal:abort.signal});
   if(drop&&req.url.startsWith('/api/pty/input')) {
    const held=drop;drop=null;await response.arrayBuffer();held.accepted=true;held.release=()=>res.destroy();return;
   }
   res.writeHead(response.status,Object.fromEntries(response.headers));if(response.body)Readable.fromWeb(response.body).on('error',()=>res.destroy()).pipe(res);else res.end();
  }catch{if(!res.headersSent)res.writeHead(502);res.end();}
 };server=createServer(handle);
 const wsServer=new WebSocketServer({noServer:true});
 server.on('upgrade',async(req,socket,head)=>{
  try{
   const response=await mf.dispatchFetch(origin+req.url,{headers:{...req.headers,host}});
   if(response.status!==101||!response.webSocket){socket.end('HTTP/1.1 '+response.status+' Rejected\r\nContent-Length: 0\r\n\r\n');return;}
   const upstream=response.webSocket;
   wsServer.handleUpgrade(req,socket,head,client=>{
    connections++;
    sockets.add(client);client.on('message',(data,binary)=>upstream.send(binary?data:new TextDecoder().decode(data)));
    upstream.addEventListener('message',event=>{if(client.readyState===1)client.send(event.data);});
    client.on('error',()=>{});client.on('close',()=>{sockets.delete(client);try{upstream.close(1001,'closed');}catch{}});
    upstream.addEventListener('close',()=>{try{client.close(1001);}catch{}});
    upstream.accept();
   });
  }catch{socket.destroy();}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 const port=server.address().port,url='http://127.0.0.1:'+port;
 if(process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS!==undefined)process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS+=(process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS?',':'')+port;
 const cache=path.resolve('.build/cache/WorkerPreview');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/cloudflare-relay-preview.swift','-o',root+'/RelayPreview'],{stdio:'inherit',timeout:300000});
 fixture=spawn(root+'/RelayPreview',[root,url,key],{stdio:['ignore','pipe','pipe']});let stderr='';fixture.stderr.on('data',data=>stderr+=data);
 const info=await new Promise((resolve,reject)=>{let output='';const timer=setTimeout(()=>reject(Error('native startup '+stderr)),15000);fixture.stdout.on('data',data=>{output+=data;try{const value=JSON.parse(output.trim());clearTimeout(timer);resolve(value);}catch{}});fixture.on('exit',code=>{clearTimeout(timer);reject(Error('native exit '+code+' '+stderr));});});
 let status;
 stage='public nonce';await until(async()=>{try{status=JSON.parse(await readFile(root+'/status.json','utf8'));return status.phase==='ready';}catch{return false;}},'Native public nonce proof: '+JSON.stringify(status),45000);
 const get=(route,headers={})=>fetch(url+route,{headers:{Host:host,...headers}});
 assert.equal((await get('/api/state')).status,401);
 assert.equal((await mf.dispatchFetch('https://foreign.invalid/api/state')).status,403);
 assert.equal((await fetch(url+'/auth/login',{method:'POST',headers:{Host:host,Origin:'https://foreign.invalid','Content-Type':'application/json'},body:JSON.stringify({key:info.key})})).status,403);
 for(const value of ['wrong',info.key]) {
  const denied=await mf.dispatchFetch(origin+'/_autoapprove/connector',{headers:{Upgrade:'websocket',Authorization:'Bearer '+value}});assert.equal(denied.status,403,'Browser key must not authorize native connector');
 }
 const login=await fetch(url+'/auth/login',{method:'POST',headers:{Host:host,Origin:origin,'Content-Type':'application/json'},body:JSON.stringify({key:info.key})});
 assert.equal(login.status,200);const cookie=login.headers.get('set-cookie');assert.match(cookie,/Secure; HttpOnly; SameSite=Strict/);
 const auth={Cookie:cookie.split(';')[0]};assert.equal((await get('/api/state',auth)).status,200);
 stage='binary unicode and flow control';const body='한글😀\n'+String.fromCharCode(27)+'[D';
 const echo=await fetch(url+'/api/echo',{method:'POST',headers:{Host:host,Origin:origin,...auth,'Content-Type':'text/plain'},body});
 assert.equal(echo.status,200);assert.equal((await echo.json()).echo,body);assert.equal(await readFile(root+'/writes','utf8'),'1');
 const large=await get('/api/large',auth);assert.equal(large.status,200);const data=new Uint8Array(await large.arrayBuffer());assert.equal(data.length,1048576);assert.ok(data.every(v=>v===97));
 stage='reconnect without input replay';for(const socket of sockets)socket.terminate();
 await until(async()=>{try{status=JSON.parse(await readFile(root+'/status.json','utf8'));return status.phase==='reconnecting';}catch{return false;}},'reconnecting');
 await until(async()=>JSON.parse(await readFile(root+'/status.json','utf8')).phase==='ready','reconnected');
 assert.equal((await get('/api/state',auth)).status,200);assert.equal(await readFile(root+'/writes','utf8'),'1');
 if(process.argv.includes('--soak')) {
  stage='silent transport recovery';const before=connections;
  for(const socket of sockets)socket._socket.pause();
  await until(()=>connections>before,'Pong deadline must reconnect a silent socket',45000);
  await until(async()=>JSON.parse(await readFile(root+'/status.json','utf8')).phase==='ready','Public proof after silent recovery');
  assert.equal((await get('/api/state',auth)).status,200);assert.equal(await readFile(root+'/writes','utf8'),'1');
 }
 const browserChecks=[];
 if(process.argv.includes('--browser')||process.argv.includes('--webkit')) {
  const engine=process.argv.includes('--webkit')?'webkit':'chromium';stage=engine+' setup';
  await writeFile(root+'/.zshrc',"PROMPT='QA> '\n");
  await writeFile(root+'/openssl.cnf','[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=relay.tunnel-qa.invalid\n[v3]\nsubjectAltName=DNS:relay.tunnel-qa.invalid\n');
  execFileSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',root+'/openssl.cnf','-keyout',root+'/key.pem','-out',root+'/cert.pem'],{stdio:'ignore'});
  tls=createTLS({key:await readFile(root+'/key.pem'),cert:await readFile(root+'/cert.pem')},handle);await new Promise(resolve=>tls.listen(0,'127.0.0.1',resolve));
  proxy=createServer();proxy.on('connect',(req,client,head)=>{
   if(req.url!==host+':443'){client.destroy();return;}
   const remote=connect(tls.address().port,'127.0.0.1',()=>{client.write('HTTP/1.1 200 Connection Established\r\n\r\n');if(head.length)remote.write(head);client.pipe(remote);remote.pipe(client);});
   for(const socket of [client,remote]) {proxySockets.add(socket);socket.on('error',()=>{});socket.on('close',()=>{proxySockets.delete(socket);client.destroy();remote.destroy();});}
  });await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
  const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
  browser=await playwright[engine].launch({headless:true,...(engine==='chromium'?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined}:{})});
  const context=await browser.newContext({proxy:{server:'http://127.0.0.1:'+proxy.address().port},ignoreHTTPSErrors:true,viewport:{width:390,height:844},isMobile:true,hasTouch:true});
  page=await context.newPage();page.on('pageerror',error=>errors.push(error.message));page.setDefaultTimeout(20000);
  await page.goto(origin);await page.locator('#tunnel-key').waitFor();
  await page.locator('#tunnel-key').fill('wrong');await page.locator('#tunnel-login-submit').click();await page.locator('#tunnel-login-error').waitFor({state:'visible'});
  for(const[name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]) {await page.setViewportSize({width,height});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/'+engine+'-login-'+name+'.png'});}
  await page.setViewportSize({width:390,height:844});await page.goto(origin+'/#access='+info.key);await page.waitForFunction(()=>typeof connected!=='undefined'&&connected);
  assert.ok(!page.url().includes('access='));assert.ok((await context.cookies()).some(v=>v.httpOnly&&v.secure&&v.name==='__Host-autoapprove_tunnel'));
  assert.equal(await page.evaluate(key=>Object.values(localStorage).some(v=>v.includes(key)),info.key),false);
  stage=engine+' original';await page.locator('.session-row').filter({hasText:'Codex'}).first().click();await page.waitForFunction(()=>latestFrame?.streamID&&!$('terminal-keyboard').disabled);
  const identity=await page.evaluate(()=>[selectedItem.session.pid,selectedItem.session.started,selectedItem.session.tty,latestFrame.streamID]);
  await page.locator('#terminal-screen').click();const text='WORKER-'+engine+'-한글😀';await page.keyboard.insertText(text);
  await page.waitForFunction(value=>$('terminal-screen').textContent.includes(value)&&!directSending&&!directQueue.length,text);
  assert.deepEqual(await page.evaluate(()=>[selectedItem.session.pid,selectedItem.session.started,selectedItem.session.tty,latestFrame.streamID]),identity);
  assert.equal((await readFile(root+'/original-input.bin','utf8')).split(text).length-1,1);
  stage=engine+' PTY';await page.locator('#terminal-back').click();await page.locator('#new-pty').click();await page.locator('#pty-directory').fill(root);await page.locator('#pty-program').selectOption('shell');await page.locator('#pty-automatic').uncheck();await page.locator('#start-pty').click();
  await page.waitForFunction(()=>ptyClient?.ready);await page.locator('#terminal-keyboard-toggle').click();
  await page.keyboard.insertText("printf 'WORKER-PTY=한글😀\\n'");await page.keyboard.press('Enter');
  const terminalText=()=>page.evaluate(()=>{const buffer=ptyClient.term.buffer.active;return Array.from({length:buffer.length},(_,i)=>buffer.getLine(i)?.translateToString(true)||'').join('\n');});
  await until(async()=>/\nWORKER-PTY=한글😀[ \t]*(\n|$)/.test(await terminalText()),'Worker native PTY echo');
  await page.keyboard.insertText("printf 'AB\\n'");for(let i=0;i<4;i++)await page.keyboard.press('ArrowLeft');await page.keyboard.insertText('X');await page.keyboard.press('Enter');
  await until(async()=>/\nAXB[ \t]*(\n|$)/.test(await terminalText()),'Worker cursor editing');assert.equal(await page.evaluate(()=>ptyClient.polling),false);
  assert.ok(requests.some(v=>v.path.startsWith('/api/pty/stream')),'Real SSE must cross Worker and native WSS');
  for(const[name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]) {await page.setViewportSize({width,height});await wait(150);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/'+engine+'-pty-'+name+'.png'});}
  stage=engine+' uncertain input';const descriptor=await page.evaluate(()=>ptyClient.descriptor),marker=root+'/once';
  await page.waitForFunction(()=>!ptyClient.sending&&!ptyClient.queue.length);
  const nativeBefore=(await readFile(root+'/native-inputs','utf8')).trim().split('\n').length;
  const held={accepted:false,release:null};drop=held;const before=requests.filter(v=>v.path.startsWith('/api/pty/input')).length;
  await page.evaluate(command=>ptyClient.enqueue(command),"printf 'ONCE\\n' >> '"+marker+"'\r");await until(()=>held.accepted,'Worker accepted input');assert.equal(await readFile(marker,'utf8'),'ONCE\n');
  await page.locator('#terminal-keyboard-toggle').click();await page.keyboard.insertText('PRESERVE');await page.waitForFunction(()=>ptyClient.queue.reduce((sum,item)=>sum+item.length,0)===8);
  for(const socket of sockets)socket.terminate();held.release();await page.waitForFunction(()=>ptyClient.blocked);await wait(300);
  assert.equal(await page.evaluate(()=>ptyClient.unsent),'PRESERVE');
  const attempts=requests.filter(v=>v.path.startsWith('/api/pty/input')).slice(before);
  // Chromium can retry a POST at the HTTP transport boundary when the TLS
  // proxy loses its response. It must retain the same request identity, and
  // neither the connector nor the native terminal may replay the write.
  assert.equal(new Set(attempts.map(v=>v.requestID)).size,1);assert.ok(attempts.length>=1&&attempts.length<=2);
  assert.equal((await readFile(root+'/native-inputs','utf8')).trim().split('\n').length-nativeBefore,1);
  await until(async()=>JSON.parse(await readFile(root+'/status.json','utf8')).phase==='ready','Worker restore after uncertain input');
  assert.equal(await readFile(marker,'utf8'),'ONCE\n');
  await fetch(info.owner+'/api/pty/close',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({requestID:randomUUID(),ptyID:descriptor.ptyID,streamID:descriptor.streamID})});
  stage=engine+' logout';if(await page.locator('#terminal-back').isVisible())await page.locator('#terminal-back').click();await page.locator('#tunnel-logout').click();await page.locator('#tunnel-key').waitFor();assert.equal((await page.request.get(origin+'/api/state')).status(),401);
  assert.equal(requests.some(v=>v.path.includes(info.key)),false);assert.deepEqual(errors,[]);
  browserChecks.push(engine+': responsive auth, original identity/Unicode, real PTY cursor + SSE, connection loss after accepted input, preserved unsent text, no replay, logout');await context.close();
 }
 stage='logout';assert.equal((await fetch(url+'/auth/logout',{method:'POST',headers:{Host:host,Origin:origin,...auth,'Content-Type':'application/json'},body:'{}'})).status,200);
 assert.equal((await get('/api/state',auth)).status,401);
 await writeFile(root+'/stop','stop');await new Promise(resolve=>fixture.once('exit',resolve));assert.equal(fixture.exitCode,0);
 const report={passed:true,silentRecovery:process.argv.includes('--soak'),connections,scope:'Local actual workerd Durable Object, production native WSS agent/gateway and private PTYs; no Cloudflare account, DNS or user terminals',checks:['public nonce','mandatory browser auth and secure cookie','connector secret distinct from browser key','binary unicode/escape input','1MiB response with credit flow control','reconnect retains cookie and never replays POST',...browserChecks,'logout and native stop'],errors,requests:requests.length};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}catch(error){await page?.screenshot({path:out+'/failure.png'}).catch(()=>{});await writeFile(out+'/failure.json',JSON.stringify({stage,error:error.message,diagnostics:await readFile(root+'/diagnostics','utf8').catch(()=>''),requests},null,2));throw error;}
finally{
 await browser?.close();for(const socket of proxySockets)socket.destroy();proxy?.closeAllConnections();tls?.closeAllConnections();await new Promise(resolve=>proxy?proxy.close(resolve):resolve());await new Promise(resolve=>tls?tls.close(resolve):resolve());
 if(fixture&&fixture.exitCode===null){await writeFile(root+'/stop','stop').catch(()=>{});await wait(150);fixture.kill();}
 for(const socket of sockets)socket.terminate();server?.closeAllConnections();await new Promise(resolve=>server?server.close(resolve):resolve());await mf?.dispose();await rm(root,{recursive:true,force:true});
}
