// Actual Core HTTP, relay and browser; all terminal sources and inputs are synthetic.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),out=path.resolve(option('output')||'.runtime/terminal-history-check');
await mkdir(out,{recursive:true});const binary=out+'/HistoryPreview';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/HistoryPreview'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
const root=await mkdtemp('/private/tmp/aa-history-http-'),children=[];
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function start(label){
 const home=root+'/'+label,child=spawn(binary,[home,label,'--direct-only','--terminal-history'],{stdio:['ignore','pipe','pipe']});children.push(child);
 let info,text='',stderr='';child.stdout.on('data',chunk=>{text+=chunk;for(const line of text.split('\n'))if(line.startsWith('{'))try{const row=JSON.parse(line);if(row.url)info=row;}catch{}});child.stderr.on('data',chunk=>stderr+=chunk);
 const end=Date.now()+15000;while(!info&&child.exitCode===null&&Date.now()<end)await wait(20);assert.ok(info,stderr||'Fixture startup timeout');return {...info,home};
}
async function json(url,body,headers={}){const response=await fetch(url,{method:body?'POST':'GET',headers:{...(body?{'content-type':'application/json'}:{}),...headers},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(15000)});return {status:response.status,value:await response.json()};}
let browser;
try{
 const first=await start('A'),second=await start('B');
 assert.equal((await json(first.url+'/api/peers',{address:second.url})).status,200);
 const state=(await json(second.url+'/api/state')).value,id=state.sessions.find(view=>view.session.cwd.endsWith('/autoapprove')).session.id;
 for(const [label,gateway,node] of [['direct',second,null],['relayed',first,second.id]]){
  const query=new URLSearchParams({session:id,...(node?{node}:{})});
  const before=(await json(gateway.url+'/api/terminal?'+query)).value;
  const pending=json(gateway.url+'/api/terminal/history?'+query);
  const started=performance.now(),live=await json(gateway.url+'/api/terminal?'+query);assert.equal(live.status,200);assert.ok(performance.now()-started<1500,'Cold history must not block live frame requests');
  const tail=await pending;assert.equal(tail.status,200);assert.ok(tail.value.text.endsWith('LATEST HISTORY · 가장 최근 기록'));assert.ok(tail.value.totalBytes>160000);
  const earliest=await json(gateway.url+'/api/terminal/history?'+query+'&snapshot='+tail.value.snapshot+'&page=0');assert.equal(earliest.status,200);assert.ok(earliest.value.text.startsWith('EARLIEST HISTORY'));
  const after=(await json(gateway.url+'/api/terminal?'+query)).value;assert.equal(after.revision,before.revision);
  assert.equal((await json(gateway.url+'/api/terminal/history?'+query+'&snapshot='+tail.value.snapshot+'&page=999999')).status,400);
  assert.equal((await json(gateway.url+'/api/terminal/history?'+query+'&snapshot=bad')).status,400);
  console.log('PASS '+label+': complete cached history pages, bounded replies, unchanged live revision');
 }
 assert.equal((await json(second.url+'/api/terminal/history?session='+encodeURIComponent(id),null,{Origin:'https://invalid.example'})).status,403);
 const module=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
 browser=await module.chromium.launch({headless:true,...(process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{channel:'chrome'})});
 const page=await browser.newPage({viewport:{width:1440,height:900}}),errors=[],historyRequests=[],inputs=[];
 page.on('pageerror',error=>errors.push(error.message));page.on('request',request=>{if(request.url().includes('/api/terminal/history'))historyRequests.push(request.url());if(request.url().includes('/api/input')&&request.method()==='POST')inputs.push(request.url());});
 await page.goto(second.url);await page.getByRole('button',{name:/웹 관리 구현/}).first().click();await page.waitForFunction(()=>document.getElementById('terminal-screen').textContent.includes('합성 데이터'));
 assert.equal(historyRequests.length,0);assert.equal(await page.locator('script[src="/terminal-history.js"]').count(),0);
 await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').check();await page.locator('#terminal-settings summary').click();
 await page.locator('#terminal-input').fill('PRESERVE UNSENT DRAFT');
 await page.locator('#terminal-history-open').click();await page.waitForFunction(()=>document.getElementById('terminal-history-output').textContent.includes('LATEST HISTORY'));
 assert.equal(await page.locator('#terminal-history-output img').count(),0);
 await page.locator('#terminal-history-output').focus();await page.keyboard.press('Enter');assert.equal(inputs.length,0,'Reading history never enters the original terminal');
 await page.getByRole('button',{name:'맨 처음',exact:true}).click();await page.waitForFunction(()=>document.getElementById('terminal-history-output').textContent.startsWith('EARLIEST HISTORY'));
 await page.getByRole('button',{name:'다음',exact:true}).click();await page.waitForFunction(()=>document.querySelectorAll('.terminal-history-page').length>=2);
 for(let i=0;i<8;i++){await page.waitForFunction(()=>!document.getElementById('terminal-history-next').disabled);await page.getByRole('button',{name:'다음',exact:true}).click();await page.waitForFunction(()=>document.getElementById('terminal-history-output').getAttribute('aria-busy')==='false');}
 assert.ok(await page.locator('.terminal-history-page').count()<=3);assert.ok((await page.locator('#terminal-history-output').textContent()).length<=49152);
 assert.ok((await page.locator('#terminal-history-output').textContent()).includes('<img src=x onerror=alert(1)>'));
 const screenshots=[];
 for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.setViewportSize({width,height});await page.screenshot({path:out+'/'+name+'.png'});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  assert.equal(await page.locator('#terminal-history-close').isVisible(),true);assert.equal(await page.locator('#terminal-history-next').isVisible(),true);screenshots.push({width,height});
 }
 const retained=await page.locator('#terminal-history-output').textContent(),historyRoute='**/api/terminal/history?**';
 await page.route(historyRoute,route=>route.fulfill({status:503,json:{error:'합성 오류: 기록을 다시 불러와주세요.'}}));
 await page.getByRole('button',{name:'새로고침',exact:true}).click();await page.waitForFunction(()=>!document.getElementById('terminal-history-error').hidden);
 assert.equal(await page.locator('#terminal-history-output').textContent(),retained,'A failed refresh preserves the readable history');
 assert.equal(await page.locator('#terminal-history-refresh').isEnabled(),true);await page.screenshot({path:out+'/error.png'});await page.unroute(historyRoute);
 const sample=(await json(second.url+'/api/terminal/history?session='+encodeURIComponent(id))).value;
 await page.route(historyRoute,route=>route.fulfill({json:{...sample,page:0,pageCount:1,totalBytes:0,totalLines:0,text:''}}));
 await page.getByRole('button',{name:'새로고침',exact:true}).click();await page.waitForFunction(()=>document.getElementById('terminal-history-output').textContent==='Terminal에 보관된 출력이 없습니다.');
 assert.equal(await page.locator('#terminal-history-first').isDisabled(),true);assert.equal(await page.locator('#terminal-history-next').isDisabled(),true);await page.screenshot({path:out+'/empty.png'});await page.unroute(historyRoute);
 await page.keyboard.press('Escape');await page.waitForFunction(()=>!document.getElementById('terminal-history-dialog').open);
 let delayed;
 await page.route(historyRoute,route=>delayed=(async()=>{await wait(500);try{await route.fulfill({json:sample});}catch{}})());
 await page.locator('#terminal-history-open').click();await page.waitForFunction(()=>document.getElementById('terminal-history-output').getAttribute('aria-busy')==='true');
 await page.keyboard.press('Escape');await delayed;await page.unroute(historyRoute);
 assert.equal(await page.locator('#terminal-history-dialog').evaluate(dialog=>dialog.open),false);assert.equal(await page.locator('.terminal-history-page').count(),0,'A closed dialog ignores its delayed response');
 assert.equal(await page.locator('#terminal-input').inputValue(),'PRESERVE UNSENT DRAFT');assert.equal(inputs.length,0);
 await page.locator('#terminal-input').fill('HISTORY LIVE ECHO');const echoStart=performance.now();await page.locator('#send-input').click();await page.waitForFunction(()=>document.getElementById('terminal-screen').textContent.includes('HISTORY LIVE ECHO'));const echoMS=Math.round(performance.now()-echoStart);assert.ok(echoMS<2000);
 const captures=JSON.parse(await readFile(second.home+'/history-captures.json','utf8'));assert.equal(captures.captures,1);assert.equal(captures.realTerminalReads,0);
 assert.deepEqual(errors,[]);
 const report={passed:true,sourceBytes:sample.totalBytes,captures:captures.captures,domPages:3,historyInputPosts:0,syntheticEchoMS:echoMS,screenshots,uiStates:['loading','populated','empty','error','cancelled'],realTerminalReads:0,errors};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{
 await browser?.close();for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();
 await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));await rm(root,{recursive:true,force:true});
}
