// Actual Core HTTP/relay/dashboard; synthetic originals, no user terminal input.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/release'),out=path.resolve(option('output')||'.runtime/codex-conversation-browser-check');
const engine=process.argv.includes('--webkit')?'webkit':'chromium';await mkdir(out,{recursive:true});
const binary=out+'/ConversationPreview';
execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/ConversationPreview'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/network-preview.swift','-o',binary],{stdio:'inherit',timeout:180000});
const root=await mkdtemp('/private/tmp/aa-conversation-http-'),children=[],checks=[];let browser;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function start(label){
 const child=spawn(binary,[root+'/'+label,label,'--direct-only','--codex-conversation','--terminal-history'],{stdio:['ignore','pipe','pipe']});children.push(child);
 let info,text='',stderr='';child.stdout.on('data',chunk=>{text+=chunk;for(const line of text.split('\n'))if(line.startsWith('{'))try{const row=JSON.parse(line);if(row.url)info=row;}catch{}});child.stderr.on('data',chunk=>stderr+=chunk);
 const end=Date.now()+15000;while(!info&&child.exitCode===null&&Date.now()<end)await wait(20);assert.ok(info,stderr||'Fixture startup timeout');return info;
}
async function json(url,body,headers={}){const response=await fetch(url,{method:body?'POST':'GET',headers:{...(body?{'content-type':'application/json'}:{}),...headers},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(15000)});return {status:response.status,value:await response.json()};}
try{
 const first=await start('A'),second=await start('B');assert.equal((await json(first.url+'/api/peers',{address:second.url})).status,200);
 for(const file of ['app.js','app.css','index.html','terminal-history.js']){
  const served=await(await fetch(second.url+'/'+file)).text();let expected=await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/'+file,'utf8');
  if(file==='index.html'){
   const version=served.match(/name="autoapprove-web-version" content="([^"]+)"/)?.[1],nonce=served.match(/name="autoapprove-style-nonce" content="([^"]+)"/)?.[1];
   const release=JSON.parse(await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/web-version.json','utf8'));assert.equal(version,`${release.version}:${release.build}:${release.api}`);assert.match(nonce,/^[0-9a-f-]{36}$/i);
   expected=expected.replaceAll('__AUTOAPPROVE_WEB_VERSION__',version).replaceAll('__AUTOAPPROVE_STYLE_NONCE__',nonce);
  }
  assert.equal(served,expected,'Served resources must match the current source: '+file);
 }
 const state=(await json(second.url+'/api/state')).value,id=state.sessions[0].session.id;
 for(const [gateway,node]of [[second,null],[first,second.id]]){
  const query=new URLSearchParams({session:id,...(node?{node}:{})});
  const result=await json(gateway.url+'/api/codex/history?'+query);assert.equal(result.status,200);assert.equal(result.value.sessionID,id);assert.equal(result.value.messages.length,2);
  assert.equal(result.value.messages[0].role,'user');assert.ok(result.value.messages[1].text.startsWith('Codex 답변'));
  query.set('thread',result.value.threadID);query.set('cursor',result.value.nextCursor);
  assert.equal((await json(gateway.url+'/api/codex/history?'+query)).value.nextCursor,'2');
  query.set('thread','wrong');assert.equal((await json(gateway.url+'/api/codex/history?'+query)).status,400);
 }
 assert.equal((await json(second.url+'/api/codex/history?session='+encodeURIComponent(id),null,{Origin:'https://invalid.example'})).status,403);
 checks.push('Production Core direct and relayed history, exact thread/cursor and origin rejection');
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
 browser=await playwright[engine].launch({headless:true,...(engine==='chromium'?{channel:'chrome'}:{})});
 const page=await browser.newPage({viewport:{width:1440,height:900}}),errors=[],posts=[],requests=[];
 page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));page.on('request',request=>{if(request.method()==='POST')posts.push(request.url());if(request.url().includes('/api/codex/history'))requests.push(request.url());});
 await page.goto(second.url);await page.getByRole('button',{name:/웹 관리 구현/}).first().click();
 await page.locator('#codex-conversation-open').waitFor();assert.equal(requests.length,0);
 await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').check();await page.locator('#terminal-settings summary').click();await page.locator('#terminal-input').fill('PRESERVE UNSENT DRAFT');
 await page.locator('#codex-conversation-open').click();await page.locator('.conversation-message').last().waitFor();
 assert.equal(await page.locator('#terminal-history-title').textContent(),'Codex 대화 기록');assert.equal(await page.locator('.conversation-message').count(),2);
 assert.equal(await page.locator('#terminal-history-output img').count(),0);assert.ok((await page.locator('#terminal-history-output').textContent()).includes('<img src=x onerror=alert(1)>'));
 assert.equal((await page.locator('#terminal-history-output').textContent()).includes('pnpm test'),false);
 await page.locator('#terminal-history-output').focus();await page.keyboard.press('Enter');assert.equal(posts.length,0);
 checks.push('Cold on-demand conversation, author separation, literal Unicode/code/XSS text, no terminal copy or keyboard writes');
 for(let i=0;i<8;i++){await page.locator('#terminal-history-older').click();await page.waitForFunction(()=>document.getElementById('terminal-history-output').getAttribute('aria-busy')==='false');}
 assert.equal(await page.locator('.conversation-page').count(),3);assert.equal(await page.locator('.conversation-message').count(),6);assert.equal(await page.locator('#terminal-history-older').isDisabled(),true);
 await page.locator('#terminal-history-refresh').click();await page.waitForFunction(()=>document.querySelectorAll('.conversation-message').length===2&&document.getElementById('terminal-history-output').textContent.includes('Codex 답변 0'));
 checks.push('Eight older pages retain at most three DOM pages; latest refresh resets the range');
 const screenshots=[];
 for(const theme of ['light','dark'])for(const [name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.emulateMedia({colorScheme:theme});await page.setViewportSize({width,height});
  await page.waitForFunction(()=>!terminalHistoryViewer.busy);await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  await page.screenshot({path:out+'/'+engine+'-'+theme+'-'+name+'.png',animations:'disabled',caret:'hide'});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  for(const selector of ['#terminal-history-close','#terminal-history-older','#terminal-history-refresh']){
   const box=await page.locator(selector).boundingBox();assert.ok(box&&box.width>=44&&box.height>=44);assert.ok(box.y>=0&&box.y+box.height<=height);
  }screenshots.push({theme,width,height});
 }
 const route='**/api/codex/history?**',retained=await page.locator('#terminal-history-output').textContent();
 await page.route(route,route=>route.fulfill({status:503,json:{error:'합성 오류: 대화 기록을 다시 불러와주세요.'}}));await page.locator('#terminal-history-refresh').click();await page.locator('#terminal-history-error').waitFor();
 assert.equal(await page.locator('#terminal-history-output').textContent(),retained);assert.equal(await page.locator('#terminal-history-refresh').isEnabled(),true);await page.screenshot({path:out+'/'+engine+'-error.png'});await page.unroute(route);
 await page.locator('#terminal-history-refresh').click();await page.waitForFunction(()=>document.getElementById('terminal-history-error').hidden);checks.push('Failed refresh retains readable messages; retry recovers');
 await page.keyboard.press('Escape');assert.equal(await page.locator('#terminal-history-dialog').isVisible(),false);assert.equal(await page.locator('#terminal-input').inputValue(),'PRESERVE UNSENT DRAFT');
 await page.route(route,route=>route.fulfill({status:409,json:{error:'대화를 확정하지 못했습니다. 확인할 대화를 선택해주세요.'}}));await page.locator('#codex-conversation-open').click();await page.locator('#terminal-history-picker').waitFor();
 assert.equal(await page.locator('#terminal-history-use').isDisabled(),true);await page.unroute(route);
 await page.locator('#terminal-history-conversation').selectOption({index:1});await page.locator('#terminal-history-use').click();await page.locator('.conversation-message').last().waitFor();
 assert.ok(requests.at(-1).includes('thread='));assert.equal(await page.locator('#terminal-history-picker').isVisible(),false);checks.push('Ambiguous original offers an explicit read-only conversation picker without changing message transport');
 const identity=await page.evaluate(()=>({sessionID:selectedItem.session.id,threadID:terminalHistoryViewer.threadID}));
 const empty={...identity,messages:[],nextCursor:null};
 await page.route(route,route=>route.fulfill({json:empty}));await page.locator('#terminal-history-refresh').click();await page.locator('#terminal-history-output').filter({hasText:'저장된 사용자 메시지와 답변이 없습니다.'}).waitFor();await page.screenshot({path:out+'/'+engine+'-empty.png'});await page.unroute(route);
 await page.keyboard.press('Escape');
 let release;const held=new Promise(resolve=>release=resolve);
 await page.route(route,async route=>{await held;try{await route.fulfill({json:empty});}catch{}});
 await page.locator('#codex-conversation-open').click();await page.waitForFunction(()=>document.getElementById('terminal-history-output').getAttribute('aria-busy')==='true');
 await page.screenshot({path:out+'/'+engine+'-loading.png'});await page.keyboard.press('Escape');release();await page.unroute(route);
 await page.locator('.session-row').nth(1).click();await page.locator('#codex-conversation-open').click();await page.locator('.conversation-message').last().waitFor();
 assert.ok((await page.locator('#terminal-history-output').textContent()).includes('Codex 답변'));checks.push('Empty/loading/close and abandoned request isolation; original composer draft preserved');
 assert.deepEqual(errors,[]);assert.equal(posts.length,0);
 const report={engine,verified:true,checks,screenshots,historyRequests:requests.length,posts:posts.length,errors,scope:'Production Core and dashboard, synthetic originals; no actual Terminal or user dialogue rendered'};
 await writeFile(out+'/'+engine+'.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{await browser?.close();for(const child of children)if(child.exitCode===null)child.kill();await rm(root,{recursive:true,force:true});}
