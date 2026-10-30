// Real Core direct/relay HTTP and shipped dashboard; isolated OS/CLI sources only.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const opt=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(opt('build')||'.build/release'),out=path.resolve(opt('output')||'.runtime/os-response-check'),engine=process.argv.includes('--webkit')?'webkit':'chromium';
await mkdir(out,{recursive:true});const binary=out+'/PermissionPreview',cache=path.resolve('.build/cache/PermissionResponsePreview');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
const root=await mkdtemp('/private/tmp/aa-os-response-'),children=[],checks=[],wait=ms=>new Promise(r=>setTimeout(r,ms));let browser;
async function until(test,label){const end=Date.now()+20000;while(!await test()){if(Date.now()>end)throw Error(label);await wait(60);}}
async function start(label){const home=root+'/'+label,child=spawn(binary,[home,label,'--direct-only','--os-permissions'],{stdio:['ignore','pipe','pipe']});children.push(child);let info,output='',error='';child.stdout.on('data',data=>{output+=data;for(const line of output.split('\n'))if(line.startsWith('{'))try{const row=JSON.parse(line);if(row.url)info=row;}catch{}});child.stderr.on('data',data=>error+=data);await until(()=>info||child.exitCode!==null,'startup '+error);assert.ok(info,error);return {...info,home};}
async function json(url,body){const response=await fetch(url,{method:body?'POST':'GET',headers:body?{'content-type':'application/json'}:{},body:body?JSON.stringify({requestID:randomUUID(),...body}):undefined,signal:AbortSignal.timeout(10000)});return {status:response.status,value:await response.json()};}
async function inputs(node){try{return JSON.parse(await readFile(node.home+'/os-inputs.json','utf8')).inputs;}catch{return [];}}
async function state(node){return (await json(node.url+'/api/state')).value;}
async function control(node,value){await writeFile(node.home+'/os-control.json',JSON.stringify(value));await until(async()=>(await state(node)).snapshot.osPermissions.requests.some(r=>r.windowToken===value.suffix),'request not observed');}
async function openRequest(page,node,suffix){const request=(await state(node)).snapshot.osPermissions.requests.find(r=>r.windowToken===suffix);assert.ok(request);await page.locator('#os-permission-requests article').filter({has:page.locator(`[data-permission-focus="view-${request.id}"]`)}).getByRole('button',{name:'요청 창 보기·응답'}).click();}
try{
 const a=await start('Response A'),b=await start('Response B');assert.equal((await json(a.url+'/api/peers',{address:b.url})).status,200);
 for(const file of ['app.js','app.css','index.html']){
  const served=await(await fetch(a.url+'/'+file)).text();let expected=await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/'+file,'utf8');
  if(file==='index.html'){const release=JSON.parse(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/web-version.json','utf8')),version=served.match(/name="autoapprove-web-version" content="([^"]+)"/)?.[1],nonce=served.match(/name="autoapprove-style-nonce" content="([^"]+)"/)?.[1];assert.equal(version,`${release.version}:${release.build}:${release.api}`);expected=expected.replaceAll('__AUTOAPPROVE_WEB_VERSION__',version).replaceAll('__AUTOAPPROVE_STYLE_NONCE__',nonce);}assert.equal(served,expected,'Final served '+file);
 }
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await playwright[engine].launch({headless:true,...(engine==='chromium'?{channel:'chrome'}:{})});
 const page=await browser.newPage({viewport:{width:1440,height:900}}),errors=[];page.setDefaultTimeout(15000);page.on('pageerror',e=>errors.push(e.message));
 await page.goto(a.url);
 for(const [node,label,choice]of [[a,'Response A',"Don't Allow"],[b,'Response B','Allow']]){
  const id=(await state(node)).sessions[0].session.id;assert.equal((await json(node.url+'/api/action',{action:'automatic',sessionID:id,enabled:false})).status,200);
  await page.getByRole('button',{name:new RegExp('검증용 '+label+' · 웹 관리 구현')}).click();
  await page.locator('#os-permission-requests').getByRole('button',{name:'요청 창 보기·응답'}).click();await page.locator('#os-request-dialog').waitFor();
  assert.equal(await page.getByRole('button',{name:choice,exact:true}).isDisabled(),true);assert.equal(await page.locator('#os-request-content img').count(),0);assert.match(await page.locator('#os-request-content').textContent(),/<img src=x/);
  await page.locator('#os-request-dialog').getByRole('button',{name:'이 요청만 이 세션에 연결'}).click();await until(async()=>await page.getByRole('button',{name:choice,exact:true}).isEnabled(),'binding not confirmed');
  assert.equal(await page.locator('#os-request-status').evaluate(e=>document.activeElement===e),true);await page.keyboard.press(engine==='webkit'?'Alt+Tab':'Tab');assert.equal(await page.locator('#os-request-buttons button').first().evaluate(e=>document.activeElement===e),true);
  await page.getByRole('button',{name:choice,exact:true}).click();await until(async()=>(await inputs(node)).length===1,'manual choice missing');
  await until(async()=>await page.getByRole('button',{name:choice,exact:true}).isDisabled(),'delivered choice remains enabled');
  assert.equal((await inputs(node))[0].action,choice==='Allow'?'allow':'deny');assert.equal((await state(node)).sessions[0].session.automatic,false);assert.deepEqual((await state(node)).sessions[0].session.osPermissionPolicy?.allowed||[],[]);
  await page.keyboard.press('Escape');assert.equal(await page.locator('#os-request-dialog').isVisible(),false);
 }
 checks.push('Direct deny and relayed allow, explicit binding, AUTO off, no policy changes, one delivery');
 await control(b,{suffix:'long',long:true});await openRequest(page,b,'long');
 await page.locator('#os-request-dialog').getByRole('button',{name:'이 요청만 이 세션에 연결'}).click();await until(async()=>await page.getByRole('button',{name:'Allow',exact:true}).isEnabled(),'long request binding');
 const screenshots=[];for(const theme of ['light','dark'])for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.emulateMedia({colorScheme:theme});await page.setViewportSize({width,height});await page.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  for(const selector of ['#close-os-request','#os-request-buttons button'])for(const button of await page.locator(selector).all()){const box=await button.boundingBox();assert.ok(box&&box.width>=44&&box.height>=44&&box.y>=0&&box.y+box.height<=height,selector+' in viewport');}
  assert.equal(await page.locator('#os-request-content').evaluate(e=>e.scrollHeight>e.clientHeight),true);await page.screenshot({path:out+'/'+engine+'-'+theme+'-'+name+'.png',animations:'disabled'});screenshots.push({theme,width,height});
 }
 await json(b.url+'/api/action',{action:'pause',paused:true});await page.waitForFunction(()=>document.getElementById('os-request-status').textContent.includes('전체 일시정지'));assert.equal(await page.getByRole('button',{name:'Allow',exact:true}).isDisabled(),true);
 await json(b.url+'/api/action',{action:'pause',paused:false});await until(async()=>await page.getByRole('button',{name:'Allow',exact:true}).isEnabled(),'unpause');
 await page.context().setOffline(true);await page.waitForFunction(()=>document.getElementById('os-request-buttons').querySelector('button').disabled);await page.screenshot({path:out+'/'+engine+'-offline.png'});await page.context().setOffline(false);
 await until(async()=>await page.getByRole('button',{name:'Allow',exact:true}).isEnabled(),'reconnect');
 await control(b,{suffix:'changed'});await page.waitForFunction(()=>document.getElementById('os-request-status').textContent.includes('닫혔'));
 assert.equal(await page.locator('#os-request-buttons button:not(:disabled)').count(),0);await page.keyboard.press('Escape');
 checks.push('Long text six viewport/theme states; pause, offline/recovery and replaced original prevent stale actions');
 await control(b,{suffix:'uncertain',uncertain:true});await openRequest(page,b,'uncertain');await page.locator('#os-request-dialog').getByRole('button',{name:'이 요청만 이 세션에 연결'}).click();await until(async()=>await page.getByRole('button',{name:'Allow',exact:true}).isEnabled(),'uncertain binding');
 await page.getByRole('button',{name:'Allow',exact:true}).click();await page.locator('#os-request-error').waitFor();assert.match(await page.locator('#os-request-error').textContent(),/미확인/);assert.equal(await page.getByRole('button',{name:'Allow',exact:true}).isDisabled(),true);await page.screenshot({path:out+'/'+engine+'-uncertain.png'});assert.equal((await inputs(b)).length,2);await page.keyboard.press('Escape');
 await control(b,{suffix:'auth',kind:'authentication'});await openRequest(page,b,'auth');assert.match(await page.locator('#os-request-status').textContent(),/Mac에서 직접/);assert.equal(await page.locator('#os-request-buttons button').count(),0);await page.screenshot({path:out+'/'+engine+'-protected.png'});await page.keyboard.press('Escape');
 await page.getByRole('button',{name:/검증용 Response A · 웹 관리 구현/}).click();assert.equal(await page.locator('#os-request-dialog').isVisible(),false);assert.deepEqual(errors,[]);
 checks.push('Uncertain delivery disables replay; protected authentication has no remote buttons; session isolation');
 const report={verified:true,engine,checks,screenshots,errors,directInputs:(await inputs(a)).length,relayInputs:(await inputs(b)).length,realOSInputs:0,realTerminalInputs:0};await writeFile(out+'/'+engine+'.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{await browser?.close();for(const child of children)if(child.exitCode===null)child.kill();await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(r=>child.once('exit',r))));await rm(root,{recursive:true,force:true});}
