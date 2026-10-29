// Real Core HTTP/browser paths. Permission windows and CLI identities are synthetic.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const opt=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(opt('build')||'.build/network-stability/release'),out=path.resolve(opt('output')||'.runtime/os-permission-check');
await mkdir(out,{recursive:true});const binary=out+'/PermissionPreview',cache=path.resolve('.build/cache/PermissionPreview');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
const root=await mkdtemp('/private/tmp/aa-os-http-'),children=[],wait=ms=>new Promise(r=>setTimeout(r,ms));let browser;
async function until(test,label){const end=Date.now()+20000;while(!await test()){if(Date.now()>end)throw Error(label);await wait(70);}}
async function start(label,args=[]){const home=root+'/'+label,child=spawn(binary,[home,label,'--direct-only','--os-permissions',...args],{stdio:['ignore','pipe','pipe']});children.push(child);let info,output='',error='';child.stdout.on('data',data=>{output+=data;for(const line of output.split('\n'))if(line.startsWith('{'))try{const row=JSON.parse(line);if(row.url)info=row;}catch{}});child.stderr.on('data',data=>error+=data);await until(()=>info||child.exitCode!==null,'startup '+error);assert.ok(info,error);return {...info,home};}
async function json(url,body){const response=await fetch(url,{method:body?'POST':'GET',headers:body?{'content-type':'application/json'}:{},body:body?JSON.stringify({requestID:randomUUID(),...body}):undefined,signal:AbortSignal.timeout(10000)});assert.equal(response.status,200,await response.clone().text());return response.json();}
async function inputs(node){try{return JSON.parse(await readFile(node.home+'/os-inputs.json','utf8')).inputs;}catch{return [];}}
async function state(node){return json(node.url+'/api/state');}
async function control(node,value){await writeFile(node.home+'/os-control.json',JSON.stringify(value));}
try{
 const a=await start('Permission A'),b=await start('Permission B'),old=await start('Permission Old',['--web-version=0.2.207:234']);
 await json(a.url+'/api/peers',{address:b.url});await json(a.url+'/api/peers',{address:old.url});
 const module=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await module.chromium.launch({headless:true,channel:'chrome'});
 const page=await browser.newPage({viewport:{width:1440,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(a.url);await page.getByRole('button',{name:/검증용 Permission A · 웹 관리 구현/}).click();await page.locator('#os-permissions').waitFor({state:'visible'});
 await page.locator('#os-permission-options').evaluate(e=>e.open=true);
 await page.locator('#os-permission-requests').getByRole('button',{name:'이 앱을 이 세션에 등록'}).waitFor();
 assert.equal(await page.locator('#os-permission-camera').isChecked(),false);assert.deepEqual(await inputs(a),[]);
 await page.locator('#os-permission-camera').check();await until(async()=>(await state(a)).sessions.some(v=>v.session.osPermissionPolicy?.allowed.includes('camera')),'Policy was not saved');
 assert.deepEqual(await inputs(a),[]);await page.locator('#os-permission-requests').getByRole('button',{name:'이 앱을 이 세션에 등록'}).click();
 await until(async()=>(await inputs(a)).length===1,'Registered request was not approved');
 await page.getByRole('button',{name:/검증용 Permission A · 질문 응답 대기/}).click();assert.equal(await page.locator('#os-permission-camera').isChecked(),false);
 await page.locator('#os-permission-options').evaluate(e=>e.open=true);await page.locator('#os-permission-microphone').check();
 await control(a,{suffix:'second',kind:'camera'});await until(async()=>(await inputs(a)).length===2,'App policy did not retain its original session');
 await control(a,{suffix:'third',kind:'microphone'});await until(async()=>(await state(a)).snapshot.osPermissions.requests.some(r=>r.kind==='microphone'&&r.phase==='waiting'),'New resource did not wait');assert.equal((await inputs(a)).length,2);
 await page.getByRole('button',{name:/검증용 Permission A · 웹 관리 구현/}).click();await page.locator('#os-permission-requests').getByRole('button',{name:'이 세션에서 마이크 허용'}).click();await until(async()=>(await inputs(a)).length===3,'Explicit resource policy was not applied');
 await json(a.url+'/api/action',{action:'pause',paused:true});await control(a,{suffix:'paused',kind:'camera'});await until(async()=>(await state(a)).snapshot.osPermissions.requests.some(r=>r.windowToken==='paused'),'Paused request was not observed');assert.equal((await inputs(a)).length,3);
 await page.locator('#os-permission-targets').getByRole('button',{name:'등록 해제'}).click();await until(async()=>(await state(a)).sessions.every(v=>!(v.session.osPermissionPolicy?.targets.length)),'Registration was not revoked');
 await json(a.url+'/api/action',{action:'pause',paused:false});await wait(1300);assert.equal((await inputs(a)).length,3);
 await page.getByRole('button',{name:/검증용 Permission B · 웹 관리 구현/}).click();await page.locator('#os-permission-options').evaluate(e=>e.open=true);await page.locator('#os-permission-camera').check();
 await page.locator('#os-permission-requests').getByRole('button',{name:'이 앱을 이 세션에 등록'}).click();await until(async()=>(await inputs(b)).length===1,'Relayed policy/registration did not reach B');assert.equal((await inputs(a)).length,3);
 await control(b,{suffix:'not-enabled',kind:'microphone'});await until(async()=>(await state(b)).snapshot.osPermissions.requests.some(r=>r.windowToken==='not-enabled'),'B pending request missing');
 await page.waitForFunction(()=>document.querySelector('#os-permission-requests')?.textContent.includes('마이크'));
 assert.equal(await page.locator('#os-permissions img').count(),0,'OS message is text, never HTML');
 await page.waitForFunction(()=>!mutation&&!loadingNetwork);await page.locator('#feedback').waitFor({state:'hidden',timeout:15000});await page.locator('#os-permission-options').evaluate(e=>e.open=false);
 const viewports=[];for(const[name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.locator('#os-permissions').evaluate(e=>e.scrollIntoView({block:'start'}));await page.screenshot({path:out+'/'+name+'.png'});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);viewports.push({width,height});}
 await page.emulateMedia({colorScheme:'dark'});await page.waitForTimeout(220);await page.screenshot({path:out+'/desktop-dark.png'});
 await page.setViewportSize({width:1440,height:900});await page.emulateMedia({colorScheme:'light'});await page.getByRole('button',{name:/검증용 Permission Old · 웹 관리 구현/}).click();assert.equal(await page.locator('#os-permissions').isHidden(),true);
 assert.deepEqual(errors,[]);const report={passed:true,nodes:3,sessionIsolation:true,relayedPolicy:true,revocation:true,pausedInputs:0,approvedA:3,approvedB:1,legacyHidden:true,viewports,errors,realOSInputs:0,realTerminalInputs:0};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{await browser?.close();for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(r=>child.once('exit',r))));await rm(root,{recursive:true,force:true});}
