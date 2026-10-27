// Signed isolated apps, actual PIN gateway and cooperative installer.
// The official feed/ranges are injected; real user sessions/accounts are excluded.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,cp,rm,readdir,copyFile} from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import path from 'node:path';
import {createHash,randomUUID} from 'node:crypto';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
import {signApp} from './sign-app.mjs';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),artifact=path.resolve(process.argv[2]||'dist/cloudflare-version-release-192/AutoApprove.app');
const out=path.resolve(option('output')||'.runtime/cloudflare-version-192/signed-update');await mkdir(out,{recursive:true,mode:0o700});
const root=await mkdtemp('/private/tmp/aa-published-update-'),children=[],configs=[],servers=[],sockets=new Set(),checks=[];
let browser;
const proxyFailures=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,ms=90000){const end=Date.now()+ms;let last;while(Date.now()<end){try{const v=await test();if(v)return v;}catch(e){last=e;}await wait(100);}throw Error(label+': '+(last?.message||'timed out'));}
const readJSON=async p=>JSON.parse(await readFile(p,'utf8'));
async function port(){const s=net.createServer();await new Promise(resolve=>s.listen(0,'127.0.0.1',resolve));const p=s.address().port;await new Promise(resolve=>s.close(resolve));return p;}
const version=await readJSON(artifact+'/Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json');
const arch=process.arch==='arm64'?'arm64':'x86_64',assetName=`AutoApprove-${version.version}-build${version.build}-macOS-${arch}.zip`;
try {
 const cache=path.resolve('.build/cache/PublishedManager');await mkdir(cache,{recursive:true});const manager=root+'/manager';
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/published-update-manager.swift','-o',manager],{stdio:'inherit',timeout:180000});
 async function app(name,{low=false,foreign=false,archive,metadata,lidClosed=false,enabled=true,dropChunk=false}={}) {
  const dir=root+'/'+name,app=dir+'/AutoApprove.app';await mkdir(dir);await cp(artifact,app,{recursive:true});await copyFile(manager,app+'/Contents/MacOS/AutoApproveApp');
  if(low){execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleShortVersionString 0.2.191',app+'/Contents/Info.plist']);execFileSync('/usr/libexec/PlistBuddy',['-c','Set :CFBundleVersion 218',app+'/Contents/Info.plist']);await writeFile(app+'/Contents/Resources/AutoApprove_AutoApproveCore.bundle/RemoteWeb/web-version.json',JSON.stringify({version:'0.2.191',build:218,api:1}));}
  await signApp(app,{allowProvisioning:false});if(foreign)execFileSync('/usr/bin/codesign',['--force','--deep','--sign','-',app],{stdio:'pipe'});
  const config={home:dir+'/runtime',archive,metadata,lidClosed,enabled,dropChunk,tunnelPort:await port()};
  await writeFile(dir+'/fixture-config.json',JSON.stringify(config));configs.push(dir);return {dir,app,config};
 }
 async function archive(app,name){const file=root+'/'+name;execFileSync('/usr/bin/ditto',['-c','-k','--norsrc','--keepParent',app.app,file]);return file;}
 async function metadata(file,name){const bytes=await readFile(file),value={tag_name:'v'+version.version,draft:false,prerelease:false,assets:[{name:assetName,size:bytes.length,digest:'sha256:'+createHash('sha256').update(bytes).digest('hex'),browser_download_url:`https://github.com/newdlops/autoapprove/releases/download/v${version.version}/${assetName}`}]},target=root+'/'+name;await writeFile(target,JSON.stringify(value));return target;}
 const source=await app('source'),goodZip=await archive(source,'good.zip'),goodMeta=await metadata(goodZip,'good-release.json');
 const target=await app('recipient',{low:true,archive:goodZip,metadata:goodMeta,lidClosed:true,dropChunk:true});
 async function start(target){const child=spawn(target.app+'/Contents/MacOS/AutoApproveApp',[],{stdio:['ignore','ignore','pipe']});children.push(child);let stderr='';child.stderr.on('data',d=>stderr+=d);const state=await until(async()=>{assert.equal(child.exitCode,null,stderr);const s=await readJSON(target.dir+'/fixture-state.json');return s.gateway&&s.pin?s:null;},'Isolated gateway startup',25000);return {child,state};}
 const initial=await start(target);
 await writeFile(root+'/tls.cnf','[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=version-sync.tunnel-qa.invalid\n[v3]\nsubjectAltName=IP:127.0.0.1\n');
 execFileSync('/usr/bin/openssl',['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',root+'/tls.cnf','-keyout',root+'/key.pem','-out',root+'/cert.pem'],{stdio:'ignore'});
 let proxyOrigin;
 const proxy=https.createServer({key:await readFile(root+'/key.pem'),cert:await readFile(root+'/cert.pem')},async(req,res)=>{
  try{
   const current=await readJSON(target.dir+'/fixture-state.json'),headers={...req.headers,host:'version-sync.tunnel-qa.invalid'};
   if(headers.origin===proxyOrigin)headers.origin='https://version-sync.tunnel-qa.invalid';
   const upstream=http.request(new URL(req.url,current.gateway),{method:req.method,headers},response=>{res.writeHead(response.statusCode,response.headers);response.pipe(res);});upstream.on('error',error=>{proxyFailures.push({phase:'upstream',code:error.code,message:error.message});if(!res.headersSent)res.writeHead(502);res.end();});req.pipe(upstream);
  }catch(error){proxyFailures.push({phase:'proxy',message:error.message});res.writeHead(502);res.end();}
 });proxy.on('connection',s=>{sockets.add(s);s.once('close',()=>sockets.delete(s));});await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));servers.push(proxy);proxyOrigin='https://127.0.0.1:'+proxy.address().port;
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await playwright.chromium.launch({headless:true,...(process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const context=await browser.newContext({ignoreHTTPSErrors:true,viewport:{width:390,height:844}}),page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await until(async()=>(await context.request.get(proxyOrigin+'/api/version')).status()===401,'Unauthenticated gateway becomes ready',5000);
 await page.route('**/*',async route=>{
  const u=new URL(route.request().url());if(u.pathname==='/'&&route.request().isNavigationRequest()){
   const response=await route.fetch();let body=await response.text();body=body.replace('content="0.2.191:218:1"',`content="${version.version}:${version.build}:1"`);await route.fulfill({response,body});
  }else await route.continue();
 });
 await page.goto(proxyOrigin);await page.locator('#tunnel-key').fill('001234');await page.locator('#tunnel-login-submit').click();
 await page.locator('#sync-version').waitFor({state:'visible',timeout:20000});
 assert.equal((await context.request.get(proxyOrigin+'/api/update/manifest')).status(),403);
 assert.equal((await context.request.post(proxyOrigin+'/api/version/check',{headers:{Origin:'https://foreign.invalid'},data:{}})).status(),403);
 checks.push('Real PIN gateway authenticates version controls and retains origin/install-file boundaries');
 await page.locator('#sync-version').click();
 await until(async()=>{const state=await readJSON(target.dir+'/fixture-state.json');return state.update==='waiting'?state:null;},'Signed update staging behind a closed lid');
 await page.getByRole('button',{name:'상태 새로고침'}).click();await page.waitForFunction(()=>document.getElementById('version-sync-message').textContent.includes('덮개'));
 assert.equal(initial.child.exitCode,null);assert.equal((await readJSON(target.dir+'/fixture-state.json')).release.version,'0.2.191');
 const ranges=(await readFile(target.dir+'/qa-ranges.log','utf8')).trim().split('\n');assert.equal(ranges.filter(v=>v.startsWith('bytes=0-')).length,1);assert.equal(ranges.filter(v=>v.startsWith('bytes=262144-')).length,2);
 checks.push('Browser newer than host pulls the signed release, resumes a dropped range and waits behind the lid guard while its external gateway remains active');
 const future=await context.request.post(proxyOrigin+'/api/version/sync',{headers:{Origin:proxyOrigin},data:{client:{version:'0.2.999',build:1000,api:1}}});assert.equal(future.status(),409);
 checks.push('A browser ahead of the published release cannot trigger an older installation');
 target.config.lidClosed=false;await writeFile(target.dir+'/fixture-config.json',JSON.stringify(target.config));
 await until(async()=>{const s=await readJSON(target.dir+'/fixture-state.json');return s.release.version===version.version&&s.gateway?s:null;},'Cooperative host update and tunnel restoration');
 await until(()=>initial.child.exitCode===0,'Old signed manager exits normally');
 assert.notEqual(Number(await readFile(target.dir+'/fixture-pid','utf8')),initial.child.pid);
 const replay=await context.request.get(proxyOrigin+'/api/version');assert.equal(replay.status(),401,'Old browser session must not survive a new gateway instance');
 await page.unrouteAll();await page.goto(proxyOrigin+'/auth');await page.locator('#tunnel-key').fill('001234');await page.locator('#tunnel-login-submit').click();
 await page.waitForFunction(v=>document.getElementById('version-sync-message')?.textContent.includes('호스트 v'+v),version.version);
 assert.equal((await readJSON(target.dir+'/fixture-state.json')).pin,true);assert.equal(await page.locator('#sync-web').isVisible(),false);
 await until(async()=>!(await readdir(target.dir)).some(v=>v.startsWith('.AutoApprove-backup-')),'Installer health confirmation removes only its private backup');
 assert.deepEqual(errors,[]);
 checks.push('Signed helper replaces/restarts the host, restores its fixed gateway and PIN, rejects the old cookie, and the current page matches the higher version');
 const foreign=await app('foreign-source',{foreign:true}),foreignZip=await archive(foreign,'foreign.zip'),foreignMeta=await metadata(foreignZip,'foreign-release.json');
 const denied=await app('foreign-recipient',{low:true,archive:foreignZip,metadata:foreignMeta});await start(denied);
 const ready=await readJSON(denied.dir+'/fixture-state.json'),base=ready.loopbackURL;
 const result=await fetch(base+'/api/version/sync',{method:'POST',headers:{Origin:base,'Content-Type':'application/json'},body:JSON.stringify({client:version})});assert.equal(result.status,200);
 const rejected=await until(async()=>{const s=await (await fetch(base+'/api/state')).json();return s.update.phase==='failed'?s:null;},'Foreign publisher rejection');
 assert.match(rejected.update.detail,/게시자 서명/);assert.equal(rejected.release.version,'0.2.191');checks.push('A correct advertised digest cannot authorize a foreign publisher signature');
 const report={passed:true,release:version,checks,errors,userTerminalInputs:0,scope:'Signed isolated managers, actual PIN gateway/browser, real production staging/helper/rollback health path; official feed/ranges injected, no real Cloudflare account or user session'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));await page.screenshot({path:out+'/aligned-mobile.png'});console.log(JSON.stringify(report));
}catch(error){await writeFile(out+'/failure.json',JSON.stringify({error:error.message,proxyFailures,states:await Promise.all(configs.map(async dir=>({name:path.basename(dir),state:await readJSON(dir+'/fixture-state.json').catch(()=>null)})))},null,2));throw error;}finally{
 for(const dir of configs)await writeFile(dir+'/qa-stop','stop').catch(()=>{});await browser?.close();for(const s of sockets)s.destroy();await Promise.all(servers.map(s=>new Promise(resolve=>s.close(resolve))));
 await wait(500);const list=execFileSync('/bin/ps',['-axo','pid=,comm='],{encoding:'utf8'});
 for(const line of list.split('\n')){const match=line.trim().match(/^(\d+)\s+(.+)$/);if(match&&match[2].startsWith(root+'/')&&/\/Contents\/MacOS\/(AutoApproveApp|autoapprove)$/.test(match[2]))try{process.kill(Number(match[1]),'SIGTERM');}catch{}}
 for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill('SIGTERM');await rm(root,{recursive:true,force:true});
}
