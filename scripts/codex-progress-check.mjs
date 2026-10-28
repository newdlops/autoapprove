// Actual Core HTTP and browser, with entirely synthetic terminal sources.
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const opt=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3),build=path.resolve(opt('build')||'.build/network-stability/release'),out=path.resolve(opt('output')||'.runtime/codex-progress-check');
await mkdir(out,{recursive:true});const binary=out+'/ProgressPreview',cache=path.resolve('.build/cache/ProgressPreview');await mkdir(cache,{recursive:true});
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
const root=await mkdtemp('/private/tmp/aa-progress-http-'),children=[],wait=ms=>new Promise(r=>setTimeout(r,ms));let browser;
async function until(test,label){const end=Date.now()+15000;while(!await test()){if(Date.now()>end)throw Error(label);await wait(40);}}
async function start(label,args=[]){const home=root+'/'+label,child=spawn(binary,[home,label,'--direct-only','--codex-progress',...args],{stdio:['ignore','pipe','pipe']});children.push(child);let info,output='',error='';child.stdout.on('data',data=>{output+=data;for(const line of output.split('\n'))if(line.startsWith('{'))try{const row=JSON.parse(line);if(row.url)info=row;}catch{}});child.stderr.on('data',data=>error+=data);await until(()=>info||child.exitCode!==null,'startup '+error);assert.ok(info,error);return {...info,home};}
async function json(url,body){if(body&&new URL(url).pathname==='/api/action')body={requestID:randomUUID(),...body};const response=await fetch(url,{method:body?'POST':'GET',headers:body?{'content-type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(10000)});return {status:response.status,value:await response.json()};}
async function inputs(node){try{return JSON.parse(await readFile(node.home+'/progress-inputs.json','utf8')).inputs;}catch{return [];}}
try{
 const automatic=await start('Auto',['--progress-delay=0.05']),manual=await start('Manual'),hanging=await start('Hang',['--progress-hang']);
 await until(async()=> (await inputs(automatic)).length===2,'Automatic threshold did not complete');
 assert.deepEqual((await inputs(automatic)).map(x=>x.kind),['escape','submit']);
 assert.equal((await json(automatic.url+'/api/state')).value.snapshot.codexProgressRecoveryEnabled,true);
 assert.equal((await json(automatic.url+'/api/action',{action:'codexProgressRecovery',enabled:false})).status,200);
 assert.equal((await json(manual.url+'/api/peers',{address:hanging.url})).status,200);
 const module=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await module.chromium.launch({headless:true,channel:'chrome'});
 const page=await browser.newPage({viewport:{width:1440,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.goto(manual.url);await page.getByRole('button',{name:/검증용 Manual · 웹 관리 구현/}).click();await page.locator('#codex-progress').waitFor({state:'visible'});
 assert.equal(await page.locator('#codex-progress-enabled').isChecked(),true);
 await page.locator('#codex-progress-check').click();await until(async()=>(await inputs(manual)).length===2,'Manual check did not submit');
 assert.deepEqual((await inputs(manual)).map(x=>x.kind),['escape','submit']);assert.ok((await inputs(manual))[1].text.includes('실제로 완료한 변경'));
 await page.locator('#codex-progress-enabled').uncheck();await until(async()=>(await json(manual.url+'/api/state')).value.snapshot.codexProgressRecoveryEnabled===false,'Opt-out not stored');
 assert.equal(await page.locator('#codex-progress-check').isDisabled(),true);assert.equal((await json(hanging.url+'/api/state')).value.snapshot.codexProgressRecoveryEnabled,true);
 await page.getByRole('button',{name:/검증용 Hang · 웹 관리 구현/}).click();await page.locator('#codex-progress-check').waitFor({state:'visible'});await page.waitForFunction(()=>!document.getElementById('codex-progress-check').disabled);
 await page.locator('#codex-progress-check').click();await page.locator('#codex-progress-cancel').waitFor({state:'visible'});
 const viewports=[];for(const[name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.screenshot({path:out+'/'+name+'.png'});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);viewports.push({width,height});}
 await page.locator('#codex-progress-cancel').click();await until(async()=>{const state=(await json(hanging.url+'/api/state')).value;return state.sessions.some(v=>v.session.codexProgressRecovery?.phase==='review');},'Relayed cancel did not stop the check');
 await wait(1000);assert.deepEqual((await inputs(hanging)).map(x=>x.kind),['escape']);assert.deepEqual(errors,[]);
 const report={passed:true,automaticInputs:2,manualInputs:2,cancelledInputs:1,relayedCancel:true,viewports,errors,realTerminalInputs:0};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{await browser?.close();for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(r=>child.once('exit',r))));await rm(root,{recursive:true,force:true});}
