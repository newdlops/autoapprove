// Real HTTPS browser origin -> isolated proxy -> production auth gateway/Core.
// TLS proxy permits only these synthetic hosts. No user CLI, account or token.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,readdir,rm,stat,copyFile,chmod} from 'node:fs/promises';
import {createServer as httpsServer} from 'node:https';
import {createServer as httpServer,request as httpRequest} from 'node:http';
import {connect} from 'node:net';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/tunnel/release'),engine=process.argv.includes('--webkit')?'webkit':'chromium';
const out=path.resolve(option('output')||'.runtime/tunnel-check/'+engine);await mkdir(out,{recursive:true,mode:0o700});
const root=await mkdtemp('/private/tmp/aa-tunnel-'),wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,timeout=15000){const end=performance.now()+timeout;while(!await test()){assert.ok(performance.now()<end,label);await wait(20);}}
const checks=[],errors=[],shutdownDiagnostics=[],traffic=[],sockets=new Set();let browser,fixture,tls,proxy,info,page,stage='startup',drop=null;
let controlGeneration=0;
function preservePort(port){if(process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS!==undefined){const previous=process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS||'';if(!previous.split(',').includes(String(port)))process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS=previous?previous+','+port:String(port);}}
// Preserve the fixed rendezvous before spawning Swift as well as Node. A later
// parent environment edit cannot affect a running child under PortManager.
const namedPort=Number(option('port')||(engine==='webkit'?28967:28966));preservePort(namedPort);
async function control(action,values={}){
 const generation=++controlGeneration;await writeFile(root+'/control.json',JSON.stringify({...values,action,generation}));
 let result;await until(async()=>{try{result=JSON.parse(await readFile(root+'/control-result.json','utf8'));return result.generation===generation;}catch{return false;}},'Control '+action,200000);
 assert.equal(result.ok,true,result.error);return result;
}
async function rawAt(port,route,body,headers){
 return new Promise((resolve,reject)=>{
  const socket=connect(port,'127.0.0.1'),parts=[];let total=0;
  const timer=setTimeout(()=>socket.destroy(Error('Raw HTTP timeout')),5000);
  socket.on('connect',()=>{const data=body?JSON.stringify(body):'';const fields={...headers,Connection:'close',...(body?{'Content-Type':'application/json','Content-Length':Buffer.byteLength(data)}:{})};socket.write((body?'POST':'GET')+' '+route+' HTTP/1.1\r\n'+Object.entries(fields).map(([key,value])=>key+': '+value+'\r\n').join('')+'\r\n'+data);});
  socket.on('data',data=>{total+=data.length;if(total>3000000)socket.destroy(Error('Raw response bound'));else parts.push(data);});
  socket.on('error',reject);socket.on('end',()=>{try{const data=Buffer.concat(parts),boundary=data.indexOf('\r\n\r\n');assert.ok(boundary>=0,'Complete raw headers');const lines=data.subarray(0,boundary).toString().split('\r\n'),parsed=new Headers();for(const line of lines.slice(1)){const at=line.indexOf(':');parsed.append(line.slice(0,at),line.slice(at+1).trim());}const text=data.subarray(boundary+4).toString();resolve({status:Number(lines[0].split(' ')[1]),headers:parsed,text,value:text.startsWith('{')?JSON.parse(text):null});}catch(error){reject(error);}});socket.on('close',()=>clearTimeout(timer));
 });
}
async function raw(mode,route,body,headers={}){
 return rawAt(info[mode].port,route,body,{host:mode+'.tunnel-qa.invalid',...(body?{Origin:'https://'+mode+'.tunnel-qa.invalid'}:{}),...headers});
}
try{
 await writeFile(root+'/.zshrc',"PROMPT='QA> '\n");
 const cache=path.resolve('.build/cache/TunnelPreview');await mkdir(cache,{recursive:true});
 const objects=(await readdir(build+'/AutoApproveCore.build')).filter(v=>v.endsWith('.swift.o')).map(v=>build+'/AutoApproveCore.build/'+v);
 const binary=root+'/TunnelPreview';execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/tunnel-preview.swift','-o',binary],{stdio:'inherit',timeout:300000});
 fixture=spawn(binary,[root],{stdio:['ignore','pipe','pipe']});let stderr='';fixture.stderr.on('data',data=>stderr+=data);
 info=await new Promise((resolve,reject)=>{let text='';const timer=setTimeout(()=>reject(Error('Fixture startup '+stderr)),20000);fixture.stdout.on('data',data=>{text+=data;for(const line of text.split('\n'))try{const value=JSON.parse(line);if(value.owner){clearTimeout(timer);resolve(value);}}catch{}});fixture.once('exit',code=>{clearTimeout(timer);reject(Error('Fixture exited '+code+' '+stderr));});});
 for(const mode of ['stream','poll','expiry'])preservePort(info[mode].port);preservePort(Number(new URL(info.owner).port));
 stage='named connector lifecycle';
 const fake=root+'/inert-cloudflared';execFileSync('/usr/bin/cc',['Tests/fixtures/tunnel-client.c','-o',fake]);
 let previousKey,previousCookie;
 for(let run=0;run<2;run++){
  stage='named connector lifecycle '+run;
  const secret=randomUUID()+randomUUID(),result=await control('named',{executable:fake,token:secret,port:namedPort});
  let active;await until(async()=>{const entries=await readdir(root+'/tunnel-runs');for(const entry of entries){try{const directory=root+'/tunnel-runs/'+entry;await stat(directory+'/pid');active=directory;return true;}catch{}}return false;},'Inert named connector');
  const args=(await readFile(active+'/arguments.bin')).toString().split('\0').filter(Boolean),tokenFile=args[args.indexOf('--token-file')+1];
  assert.ok(args.includes('--token-file'));assert.ok(!args.some(value=>value.includes(secret)));assert.equal(await readFile(tokenFile,'utf8'),secret);
  assert.equal((await stat(tokenFile)).mode&0o777,0o600);assert.equal((await stat(active)).mode&0o777,0o700);
  await wait(100);assert.ok(!(await readFile(root+'/controller-status.json','utf8')).includes(secret),'Child diagnostic must never be published');
  const pid=Number(await readFile(active+'/pid','utf8'));
  if(run===0){
   let route;
   try {await until(async()=>{route=JSON.parse(await readFile(root+'/controller-status.json','utf8'));return route.phase==='routeRequired';},'Named connector remains available while its public route is missing',45000);}
   catch {throw Error('Named public route did not enter setup state: '+JSON.stringify(route));}
   process.kill(pid,0);await control('verify-address');
   assert.ok(['checking','routeRequired'].includes(JSON.parse(await readFile(root+'/controller-status.json','utf8')).phase));
   process.kill(pid,0);
  }
  if(previousKey){assert.notEqual(result.accessKey,previousKey);assert.equal((await rawAt(namedPort,'/api/state',null,{Host:'named.tunnel-qa.invalid',Cookie:previousCookie})).status,401);assert.equal((await rawAt(namedPort,'/auth/login',{key:previousKey},{Host:'named.tunnel-qa.invalid',Origin:'https://named.tunnel-qa.invalid'})).status,401);}
  const logged=await rawAt(namedPort,'/auth/login',{key:result.accessKey},{Host:'named.tunnel-qa.invalid',Origin:'https://named.tunnel-qa.invalid'});assert.equal(logged.status,200);previousCookie=logged.headers.get('set-cookie').split(';')[0];previousKey=result.accessKey;
  await control('stop-controller');await until(()=>{try{process.kill(pid,0);return false;}catch{return true;}},'Owned connector shutdown');await wait(250);
  assert.equal(JSON.parse(await readFile(root+'/controller-status.json','utf8')).phase,'off');assert.equal(await stat(tokenFile).then(()=>true,()=>false),false);
 }
 checks.push('named token file permissions, no token in argv/status despite child diagnostics, public-route setup retains connector and supports explicit verification, owned connector termination, fresh access key and invalidated old cookie/key on restart');
 stage='raw authentication';
 assert.equal((await raw('stream','/api/state')).status,401);
 assert.equal((await raw('stream','/api/input',{sessionID:'fake'})).status,401);
 assert.equal((await raw('stream','/auth/login',{key:info.stream.key},{Origin:'https://attacker.invalid'})).status,403);
 assert.equal((await raw('stream','/api/state',null,{host:'attacker.invalid'})).status,403);
 const login=await raw('stream','/auth/login',{key:info.stream.key});assert.equal(login.status,200);
 const cookie=login.headers.get('set-cookie');assert.match(cookie,/; Secure; HttpOnly; SameSite=Strict$/);assert.ok(!cookie.includes('Domain='));
 const sid=cookie.split(';')[0];assert.equal((await raw('stream','/api/state',null,{Cookie:sid})).status,200);
 assert.equal((await raw('stream','/api/state',null,{Cookie:sid+'; '+sid})).status,401);
 assert.equal((await raw('stream','/api/state',null,{Cookie:sid,Origin:'https://attacker.invalid'})).status,403);
 assert.equal((await rawAt(Number(new URL(info.owner).port),'/api/state',null,{host:'stream.tunnel-qa.invalid'})).status,403,'LAN host validation must stay strict');
 await raw('stream','/auth/logout',{}, {Cookie:sid});assert.equal((await raw('stream','/api/state',null,{Cookie:sid})).status,401);
 for(let i=0;i<31;i++){const result=await raw('stream','/auth/login',{key:'bad'});assert.equal(result.status,i===30?429:401);}
 assert.equal((await raw('stream','/auth/login',{key:info.stream.key})).status,200,'Correct 256-bit keys remain usable after invalid probes');
 checks.push('mandatory API authentication; host/origin isolation; duplicate cookie rejection; Secure HttpOnly SameSite cookies; rate bounds; unchanged LAN rules');
 const expiring=await raw('expiry','/auth/login',{key:info.expiry.key}),expired=expiring.headers.get('set-cookie').split(';')[0];await wait(2300);
 assert.equal((await raw('expiry','/api/state',null,{Cookie:expired})).status,401);checks.push('absolute server-side session expiry');
 await writeFile(root+'/openssl.cnf','[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=*.tunnel-qa.invalid\n[v3]\nsubjectAltName=DNS:*.tunnel-qa.invalid\n');
 execFileSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',root+'/openssl.cnf','-keyout',root+'/key.pem','-out',root+'/cert.pem'],{stdio:'ignore'});
 tls=httpsServer({key:await readFile(root+'/key.pem'),cert:await readFile(root+'/cert.pem')},(req,res)=>{
  const mode=(req.headers.host||'').split('.')[0];if(!['stream','poll','expiry'].includes(mode)){res.writeHead(403);res.end();return;}
  const pathname=new URL(req.url,'https://fixture').pathname;traffic.push({mode,path:pathname,url:req.url,method:req.method});
  const upstream=httpRequest({host:'127.0.0.1',port:info[mode].port,path:req.url,method:req.method,headers:req.headers},response=>{
   if(drop&&pathname==='/api/pty/input'){
    const held=drop;drop=null;response.resume();response.on('end',()=>{held.accepted=true;held.release=()=>res.destroy();});return;
   }
   res.writeHead(response.statusCode,response.headers);response.pipe(res);
  });upstream.on('error',()=>res.destroy());res.on('close',()=>upstream.destroy());req.pipe(upstream);
 });await new Promise(resolve=>tls.listen(0,'127.0.0.1',resolve));
 proxy=httpServer();proxy.on('connect',(req,client,head)=>{
  if(!/^(stream|poll|expiry)\.tunnel-qa\.invalid:443$/.test(req.url)){client.destroy();return;}
  const remote=connect(tls.address().port,'127.0.0.1',()=>{client.write('HTTP/1.1 200 Connection Established\r\n\r\n');if(head.length)remote.write(head);client.pipe(remote);remote.pipe(client);});
  sockets.add(client);sockets.add(remote);client.on('error',()=>remote.destroy());remote.on('error',()=>client.destroy());client.on('close',()=>{sockets.delete(client);remote.destroy();});remote.on('close',()=>{sockets.delete(remote);client.destroy();});
 });await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
 browser=await playwright[engine].launch({headless:true,...(engine==='chromium'?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined}:{})});
 for(const mode of ['stream','poll']){
  await control('reset-original');
  stage=mode+' login';const context=await browser.newContext({proxy:{server:'http://127.0.0.1:'+proxy.address().port},ignoreHTTPSErrors:true,viewport:{width:390,height:844},isMobile:true,hasTouch:true});
  page=await context.newPage();page.setDefaultTimeout(15000);const url='https://'+mode+'.tunnel-qa.invalid';let loggingOut=false;
  page.on('pageerror',error=>{
   const cancelled=[url+'/api/network due to access control checks.','/'+mode+'.tunnel-qa.invalid/api/network due to access control checks.'];
   // WebKit can report the revoked document's held fetch after logout. Keep
   // this exact shutdown diagnostic separate; all other page errors still fail.
   if(engine==='webkit'&&loggingOut&&cancelled.includes(error.message))shutdownDiagnostics.push({mode,phase:'logout',message:error.message});
   else errors.push(error.message);
  });
  await page.goto(url);await page.locator('#tunnel-key').waitFor();assert.equal(await page.locator('.session-row').count(),0);
  await page.locator('#tunnel-key').fill('wrong');await page.locator('#tunnel-login-submit').click();await page.locator('#tunnel-login-error').waitFor({state:'visible'});
  assert.equal(await page.locator('#tunnel-key').getAttribute('aria-invalid'),'true');
  for(const[name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/'+mode+'-login-'+name+'.png'});}
  await page.setViewportSize({width:390,height:844});
  await page.goto(url+'/#access='+info[mode].key);await page.waitForFunction(()=>typeof connected!=='undefined'&&connected);
  assert.ok(!page.url().includes('access='));const cookies=await context.cookies();assert.ok(cookies.some(c=>c.name==='__Host-autoapprove_tunnel'&&c.httpOnly&&c.secure));
  assert.equal(await page.evaluate(key=>Object.values(localStorage).some(v=>v.includes(key)),info[mode].key),false);
  stage=mode+' original';await page.locator('.session-row').filter({hasText:'Codex'}).first().click();await page.waitForFunction(()=>latestFrame?.streamID&&!$('terminal-keyboard').disabled);
  const identity=await page.evaluate(()=>[selectedItem.session.pid,selectedItem.session.started,selectedItem.session.tty,latestFrame.streamID]);
  await page.locator('#terminal-screen').click();const text='TUNNEL-'+mode+'-한글😀';await page.keyboard.insertText(text);
  await page.waitForFunction(value=>$('terminal-screen').textContent.includes(value)&&!directSending&&!directQueue.length,text);
  assert.deepEqual(await page.evaluate(()=>[selectedItem.session.pid,selectedItem.session.started,selectedItem.session.tty,latestFrame.streamID]),identity);
  const written=await readFile(root+'/original-input.bin','utf8');assert.equal(written.split(text).length-1,1);
  stage=mode+' PTY';await page.locator('#terminal-back').click();await page.locator('#new-pty').click();await page.locator('#pty-directory').fill(root);await page.locator('#pty-program').selectOption('shell');await page.locator('#pty-automatic').uncheck();await page.locator('#start-pty').click();
  await page.waitForFunction(()=>ptyClient?.ready);await page.locator('#terminal-keyboard-toggle').click();
  await page.keyboard.insertText("printf 'TUNNEL-PTY=한글😀\\n'");await page.keyboard.press('Enter');
  const terminalText=()=>page.evaluate(()=>{const buffer=ptyClient.term.buffer.active;return Array.from({length:buffer.length},(_,i)=>buffer.getLine(i)?.translateToString(true)||'').join('\n');});
  await until(async()=>/\nTUNNEL-PTY=한글😀[ \t]*(\n|$)/.test(await terminalText()),'Native PTY echo');
  await page.keyboard.insertText("printf 'AB\\n'");for(let i=0;i<4;i++)await page.keyboard.press('ArrowLeft');await page.keyboard.insertText('X');await page.keyboard.press('Enter');
  await until(async()=>/\nAXB[ \t]*(\n|$)/.test(await terminalText()),'Native cursor editing');
  for(const[name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.waitForTimeout(150);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/'+mode+'-pty-'+name+'.png'});}
  assert.equal(await page.evaluate(()=>ptyClient.polling),mode==='poll');
  if(mode==='poll')assert.equal(traffic.filter(v=>v.mode===mode&&v.path.endsWith('/stream')).length,0,'Quick mode must never open unsupported SSE');
  else assert.ok(traffic.some(v=>v.mode===mode&&v.path==='/api/pty/stream'));
  stage=mode+' uncertain input';const descriptor=await page.evaluate(()=>ptyClient.descriptor),marker=root+'/once-'+mode;
  const held={accepted:false,release:null};drop=held;const before=traffic.filter(v=>v.mode===mode&&v.path==='/api/pty/input').length;
  await page.evaluate(command=>ptyClient.enqueue(command),"printf 'ONCE\\n' > '"+marker+"'\r");
  await until(()=>held.accepted,'Native accepted input');assert.equal(await readFile(marker,'utf8'),'ONCE\n');
  await page.locator('#terminal-keyboard-toggle').click();await page.keyboard.insertText('PRESERVE');await page.waitForFunction(()=>ptyClient.queue.reduce((sum,item)=>sum+item.length,0)===8);
  held.release();await page.waitForFunction(()=>ptyClient.blocked);await page.waitForTimeout(300);
  assert.equal(await page.evaluate(()=>ptyClient.unsent),'PRESERVE');assert.equal(traffic.filter(v=>v.mode===mode&&v.path==='/api/pty/input').length-before,1);
  await fetch(info.owner+'/api/pty/close',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({requestID:randomUUID(),ptyID:descriptor.ptyID,streamID:descriptor.streamID})});
  stage=mode+' logout';loggingOut=true;if(await page.locator('#terminal-back').isVisible())await page.locator('#terminal-back').click();await page.locator('#tunnel-logout').click();await page.locator('#tunnel-key').waitFor();
  const state=await page.request.get(url+'/api/state');assert.equal(state.status(),401);
  assert.equal(traffic.some(item=>item.url.includes(info[mode].key)),false,'Shared keys must never appear in request URLs');
  checks.push(mode+': responsive login/error/fragment authentication, HttpOnly cookie, original identity and exact Unicode input, actual PTY/cursor, no uncertain replay, unsent preservation, logout');
  await context.close();
 }
 if(process.argv.includes('--public')){
  stage='official tool install and public Quick Tunnel';await control('install');
  await copyFile(root+'/tunnel-tools/cloudflared',out+'/verified-cloudflared');await chmod(out+'/verified-cloudflared',0o700);
  await control('quick',{port:namedPort});let status;
  await until(async()=>{try{status=JSON.parse(await readFile(root+'/controller-status.json','utf8'));return ['ready','failed'].includes(status.phase);}catch{return false;}},'Official Quick Tunnel',100000);
  assert.equal(status.phase,'ready',status.detail);
  const share=new URL(await readFile(root+'/public-share-url','utf8')),origin=share.origin;
  const landing=await fetch(origin,{signal:AbortSignal.timeout(15000)});assert.equal(landing.status,200);assert.match(await landing.text(),/tunnel-login-form/);
  assert.equal((await fetch(origin+'/api/state',{signal:AbortSignal.timeout(15000)})).status,401);
  const login=await fetch(origin+'/auth/login',{method:'POST',headers:{Origin:origin,'Content-Type':'application/json'},body:JSON.stringify({key:new URLSearchParams(share.hash.slice(1)).get('access')}),signal:AbortSignal.timeout(15000)});assert.equal(login.status,200);
  const state=await fetch(origin+'/api/state',{headers:{Cookie:login.headers.get('set-cookie').split(';')[0]},signal:AbortSignal.timeout(15000)});assert.equal(state.status,200);assert.equal((await state.json()).name,'Tunnel QA');
  await control('stop-controller');checks.push('official checksum-pinned cloudflared install and actual public Quick Tunnel: HTTPS login, unauthorized 401, authenticated synthetic inventory, explicit stop');
 }
 assert.deepEqual(errors,[]);await control('stop');
 await rm(out+'/failure.json',{force:true});await rm(out+'/failure.png',{force:true});
 const report={result:'PASS',engine,checks,errors,shutdownDiagnostics,requests:traffic.length,scope:'Synthetic HTTPS hosts on a local CONNECT proxy, production Swift gateway and real private PTYs; optional official public tunnel exposes only this synthetic fixture. No user token/CLI.'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}catch(error){await page?.screenshot({path:out+'/failure.png'}).catch(()=>{});await writeFile(out+'/failure.json',JSON.stringify({stage,controlGeneration,namedPort,error:error.message},null,2));throw error;}
finally{
 await browser?.close();for(const socket of sockets)socket.destroy();await new Promise(resolve=>proxy?proxy.close(resolve):resolve());await new Promise(resolve=>tls?tls.close(resolve):resolve());
 if(fixture&&fixture.exitCode===null&&fixture.signalCode===null){await control('stop').catch(()=>{});fixture.kill();await new Promise(resolve=>fixture.once('exit',resolve));}
 await rm(root,{recursive:true,force:true});
}
