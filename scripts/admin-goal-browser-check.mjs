// Real Core HTTP + browser, synthetic CLI/OS/Goal state only. All fixture
// processes are explicitly started for this check and stopped in finally.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const opt=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(opt('build')||'.build/network-stability/release'),out=path.resolve(opt('output')||'.runtime/admin-goal-browser');
await mkdir(out,{recursive:true});const binary=out+'/AdminPreview';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/AdminPreview'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
const root=await mkdtemp('/private/tmp/aa-admin-http-'),children=[],wait=ms=>new Promise(r=>setTimeout(r,ms));let browser,page;
async function until(test,label,timeout=20000){const end=Date.now()+timeout;while(!await test()){if(Date.now()>end)throw Error(label);await wait(60);}}
async function start(label,version='0.2.209:236'){const home=root+'/'+label,child=spawn(binary,[home,label,'--direct-only','--os-permissions','--codex-goals','--web-version='+version],{stdio:['ignore','pipe','pipe']});children.push(child);let info,stdout='',stderr='';child.stdout.on('data',b=>{stdout+=b;for(const line of stdout.split('\n'))if(line.startsWith('{'))try{const x=JSON.parse(line);if(x.url)info=x;}catch{}});child.stderr.on('data',b=>stderr+=b);await until(()=>info||child.exitCode!==null,'Fixture startup '+stderr);assert.ok(info,stderr);return {...info,home};}
async function json(url,body,status=200){const response=await fetch(url,{method:body?'POST':'GET',headers:body?{'content-type':'application/json'}:{},body:body?JSON.stringify({requestID:randomUUID(),...body}):undefined,signal:AbortSignal.timeout(15000)});assert.equal(response.status,status,await response.clone().text());return response.json();}
async function state(node){return json(node.url+'/api/state');}
async function report(node){return JSON.parse(await readFile(node.home+'/goal-report.json','utf8'));}
async function select(label,suffix='웹 관리 구현'){await page.getByRole('button',{name:new RegExp('검증용 '+label+' · '+suffix)}).click();await page.locator('#os-permissions').waitFor({state:'visible'});}
async function settled(){await page.waitForFunction(()=>!mutation);}
try{
 const a=await start('Admin A'),b=await start('Admin B'),old=await start('Admin Old','0.2.207:234');
 await json(a.url+'/api/peers',{address:b.url});await json(a.url+'/api/peers',{address:old.url});
 const module=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await module.chromium.launch({headless:true,channel:'chrome'});
 const context=await browser.newContext({viewport:{width:1440,height:900}});page=await context.newPage();const errors=[],mutations=[];page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(r.method()==='POST'&&r.url().includes('/api/action'))mutations.push(r.postDataJSON());});
 await page.goto(a.url);await select('Admin A');await page.waitForFunction(()=>document.querySelector('#resume-goal')?.disabled===false);
 let missingThread=true;await page.route('**/api/codex/goal**',route=>{if(missingThread){missingThread=false;return route.fulfill({status:409,contentType:'application/json',body:JSON.stringify({error:'원래 대화를 선택해주세요.'})});}return route.continue();});
 await page.locator('#refresh-goal').click();await page.locator('#choose-goal-thread').waitFor({state:'visible'});await page.locator('#choose-goal-thread').click();await page.locator('#goal-thread').selectOption({index:1});await page.locator('#use-goal-thread').click();await page.waitForFunction(()=>!document.querySelector('#resume-goal').disabled);await page.unroute('**/api/codex/goal**');
 const sa=(await state(a)).sessions.find(v=>v.title==='검증용 Admin A · 웹 관리 구현').session;
 await page.locator('#os-permission-options').evaluate(e=>e.open=true);await page.locator('#os-permission-requests details').first().evaluate(e=>e.open=true);
 await page.locator('#os-permission-camera').check();await settled();assert.ok(await page.locator('#os-permission-camera').isChecked());
 assert.ok(await page.locator('#os-permission-requests details').first().evaluate(e=>e.open),'Disclosure survived policy refresh');
 let held=null,holdNext=false,heldCount=0,staleBody='';
 await page.route('**/api/network**',async route=>{if(!holdNext)return route.continue();holdNext=false;heldCount++;await new Promise(resolve=>held=resolve);try{await route.fulfill({status:200,contentType:'application/json',body:staleBody});}catch{}});
 async function holdInventory(){staleBody=JSON.stringify(await json(a.url+'/api/network'));const count=heldCount;holdNext=true;await page.evaluate(()=>{void refreshNetwork(false,true);});await until(()=>heldCount>count,'Inventory was not held');}
 async function releaseInventory(){held?.();held=null;await wait(150);}
 await holdInventory();const started=Date.now();await page.locator('#os-permission-microphone').check();await settled();const writeRefreshMS=Date.now()-started;
 assert.ok(await page.locator('#os-permission-camera').isChecked());assert.ok(await page.locator('#os-permission-microphone').isChecked());await releaseInventory();
 assert.ok(await page.locator('#os-permission-microphone').isChecked(),'Late old response must not roll back policy');
 await holdInventory();const before=(await state(a)).sessions.find(v=>v.session.id===sa.id).session.osPermissionPolicy;
 await json(a.url+'/api/action',{action:'osPermissionPolicy',sessionID:sa.id,allowed:[],policyRevision:before.revision});
 await page.locator('#os-permission-camera').uncheck();await settled();await releaseInventory();
 assert.equal(await page.locator('#os-permission-camera').isChecked(),false);assert.equal(await page.locator('#os-permission-microphone').isChecked(),false);
 assert.match(await page.locator('#os-permission-status').innerText(),/바뀌었습니다/);
 const policy=(await state(a)).sessions.find(v=>v.session.id===sa.id).session.osPermissionPolicy;assert.deepEqual(policy.allowed,[]);
 await json(a.url+'/api/action',{action:'osPermissionPolicy',sessionID:sa.id,allowed:['camera'],policyRevision:before.revision},409);
 // A delayed mutation belongs to the original session even after selecting another.
 let delayed=false;await page.route('**/api/action**',async route=>{const body=route.request().postDataJSON();if(!delayed&&body.action==='osPermissionPolicy'){delayed=true;await wait(400);}await route.continue();});
 await page.locator('#os-permission-camera').check();await select('Admin A','질문 응답 대기');await settled();assert.equal(await page.locator('#os-permission-camera').isChecked(),false);await page.unroute('**/api/action**');
 await select('Admin A');await page.locator('#refresh-goal').click();await page.waitForFunction(()=>!document.querySelector('#resume-goal').disabled);
 await page.locator('#resume-goal').click();await page.waitForFunction(()=>document.querySelector('#goal-status').textContent==='진행 중');assert.equal((await report(a)).actions.length,1);
 // The same route forwarded to another Mac changes only that Mac's Goal.
 await select('Admin B');await page.waitForFunction(()=>!document.querySelector('#cancel-goal').disabled);await page.locator('#cancel-goal').click();await page.locator('#keep-goal').click();assert.equal((await report(b)).actions.length,0);
 await page.locator('#cancel-goal').click();await page.locator('#confirm-cancel-goal').click();await page.waitForFunction(()=>document.querySelector('#goal-status').textContent.includes('Goal이 없습니다'));assert.equal((await report(b)).actions.length,1);assert.equal((await report(a)).actions.length,1);
 const sb=(await state(b)).sessions.find(v=>v.title==='검증용 Admin B · 웹 관리 구현').session,thread='00000000-0000-4000-8000-'+String(sb.pid).padStart(12,'0');
 await writeFile(b.home+'/goal-control.json',JSON.stringify({threadID:thread,status:'blocked',objective:'다시 확인할 목표',createdAt:300}));await page.locator('#refresh-goal').click();await page.waitForFunction(()=>!document.querySelector('#resume-goal').disabled);
 await writeFile(b.home+'/goal-control.json',JSON.stringify({threadID:thread,status:'blocked',objective:'교체된 목표 · 오래된 조작은 거절',createdAt:400}));await page.locator('#resume-goal').click();await page.waitForFunction(()=>document.querySelector('#goal-error').textContent.includes('바뀌었습니다'));assert.equal((await report(b)).actions.length,1);
 await page.locator('#refresh-goal').click();await page.waitForFunction(()=>!document.querySelector('#resume-goal').disabled);
 // Drop the HTTP acknowledgement after the host applied exactly one command.
 let dropped=0;await page.route('**/api/action**',async route=>{if(route.request().postDataJSON().action==='resumeGoal'&&!dropped){dropped++;await route.fetch();await route.abort('failed');}else await route.continue();});
 const beforeLost=mutations.filter(v=>v.action==='resumeGoal').length;await page.locator('#resume-goal').click();await page.waitForFunction(()=>document.querySelector('#goal-error').textContent.includes('다시 보내지'));await page.unroute('**/api/action**');
 assert.equal((await report(b)).actions.length,2);assert.equal(mutations.filter(v=>v.action==='resumeGoal').length,beforeLost+1);
 await context.setOffline(true);await page.evaluate(()=>{void refreshNetwork(false,true);});await page.waitForFunction(()=>!connected);assert.ok(await page.locator('#os-permission-camera').isDisabled());assert.ok(await page.locator('#cancel-goal').isDisabled());
 const recoveredAt=Date.now();await context.setOffline(false);await page.evaluate(()=>window.dispatchEvent(new Event('online')));await page.waitForFunction(()=>connected&&currentNode()?.online);const reconnectMS=Date.now()-recoveredAt;
 await page.locator('#refresh-goal').click();await page.waitForFunction(()=>document.querySelector('#goal-status').textContent==='진행 중'&&!document.querySelector('#cancel-goal').disabled);assert.equal((await report(b)).actions.length,2);
 const stable=await page.evaluate(async()=>{let childChanges=0;const observer=new MutationObserver(rows=>childChanges+=rows.filter(r=>r.type==='childList').length);observer.observe(document.querySelector('#os-permission-requests'),{childList:true,subtree:true});const before=performance.now();for(let i=0;i<250;i++)renderOSPermissions(selectedItem);await Promise.resolve();observer.disconnect();return {renders:250,childChanges,elapsedMS:performance.now()-before};});assert.equal(stable.childChanges,0);
 await writeFile(b.home+'/goal-control.json',JSON.stringify({threadID:thread,status:'active',objective:'긴 목표와 원래 대화의 내용 · <img src=x onerror=alert(1)>\n'+'한글🙂 길이가 긴 목표를 확인하면서 현재 작업과 연결을 유지합니다. '.repeat(60),createdAt:400}));await page.locator('#refresh-goal').click();await page.waitForFunction(()=>document.querySelector('#goal-objective').textContent.length>1000);
 await page.locator('#goal-objective-details').evaluate(e=>e.open=true);assert.equal(await page.locator('#codex-goal img').count(),0);await page.locator('#feedback').waitFor({state:'hidden',timeout:15000});
 const viewports=[];for(const theme of ['light','dark'])for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.emulateMedia({colorScheme:theme});await page.setViewportSize({width,height});await page.locator('#codex-goal').evaluate(e=>e.scrollIntoView({block:'start'}));await page.screenshot({path:out+'/'+name+'-'+theme+'.png'});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);const buttons=await page.locator('#codex-goal button:visible').evaluateAll(es=>es.map(e=>({height:e.getBoundingClientRect().height,label:e.textContent})));assert.ok(buttons.every(b=>b.height>=44));viewports.push({width,height,theme});}
 await page.setViewportSize({width:390,height:844});await page.locator('#os-permission-options').evaluate(e=>e.open=true);await page.locator('#os-permissions').evaluate(e=>e.scrollIntoView({block:'start'}));await page.screenshot({path:out+'/permissions-mobile-dark.png'});
 await page.locator('#cancel-goal').focus();assert.equal(await page.evaluate(()=>document.activeElement.id),'cancel-goal');await page.keyboard.press('Enter');assert.equal(await page.evaluate(()=>document.activeElement.id),'keep-goal');await page.keyboard.press('Enter');assert.equal(await page.evaluate(()=>document.activeElement.id),'cancel-goal');
 await page.setViewportSize({width:1440,height:900});await page.getByRole('button',{name:/검증용 Admin Old · 웹 관리 구현/}).click();assert.ok(await page.locator('#codex-goal').isHidden());assert.ok(await page.locator('#os-permissions').isHidden());assert.deepEqual(errors,[]);
 const result={passed:true,nodes:3,writeRefreshMS,reconnectMS,lateResponsePreserved:true,policyConflictRejected:true,sessionSwitchPreserved:true,goalForwarded:true,goalReplacementRejected:true,lostReplyReplays:0,stable,viewports,errors,realTerminalInputs:0,realOSInputs:0};await writeFile(out+'/report.json',JSON.stringify(result,null,2));console.log(JSON.stringify(result));
}catch(error){if(page)await page.screenshot({path:out+'/failure.png'}).catch(()=>{});throw error;}
finally{await browser?.close();for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(r=>child.once('exit',r))));await rm(root,{recursive:true,force:true});}
