// Real Swift HTTP action handlers and product assets; two isolated synthetic
// Macs on loopback. The browser proxy changes only node addressing/test faults.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,rm,writeFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const {chromium,webkit}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const engine=process.argv.includes('--webkit')?'webkit':'chromium';
const build=path.resolve(process.env.AUTOAPPROVE_QA_BUILD||'.build/release');
const assets=path.resolve(process.env.AUTOAPPROVE_QA_ASSETS||'Sources/AutoApproveCore/Resources/RemoteWeb');
const out=path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT||'dist/qa/automation-reset');
const root=await mkdtemp('/private/tmp/aa-reset-web-');
await mkdir(out,{recursive:true});
const children=[],errors=[],checks=[],views=[],posts=[];
let browser,server,holdReset=null,releaseReset=null,failReset=false,peerOnline=true,peerOld=false;
const hash=data=>createHash('sha256').update(data).digest('hex');
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function state(base){const response=await fetch(base+'/api/network');assert.equal(response.status,200);return response.json();}
async function ready(directory){
 for(let i=0;i<400;i++){try{return JSON.parse(await readFile(directory+'/ready.json','utf8'));}catch{}await delay(25);}
 throw Error('Synthetic server did not become ready');
}
try {
 const binary=root+'/fixture',cache=root+'/module-cache';await mkdir(cache);
 const objects=(await readdir(build+'/AutoApproveCore.build')).filter(name=>name.endsWith('.swift.o')).map(name=>build+'/AutoApproveCore.build/'+name);
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/web-interaction-fixture.swift','-o',binary],{stdio:'inherit'});
 const bases=[];
 for(const name of ['a','b']){
  const directory=root+'/'+name;await mkdir(directory);
  const child=spawn(binary,[directory],{stdio:['ignore','ignore','pipe']});children.push(child);
  child.stderr.on('data',data=>errors.push(String(data)));
  const info=await ready(directory);bases.push('http://127.0.0.1:'+info.port);
 }
 const inventories=await Promise.all(bases.map(state));
 const ids=inventories.map(value=>value.nodes[0].id);
 assert.notEqual(ids[0],ids[1]);
 const published=JSON.parse(await readFile(assets+'/web-version.json'));
 assert.deepEqual(published,inventories[0].nodes[0].release,'Run against assets matching the compiled fixture');
 const eventCount=async index=>(await(await fetch(bases[index]+'/api/state')).json()).snapshot.events.filter(event=>event.source==='자동화 복구').length;
 server=createServer(async(req,res)=>{
  try {
   const url=new URL(req.url,'http://localhost'),json=(code,value)=>{res.writeHead(code,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
   if(url.pathname==='/api/network'){
    const [a,b]=await Promise.all(bases.map(state));
    const own=a.nodes[0],peer=b.nodes[0];own.name='합성 Mac A';own.state.name=own.name;
    peer.name='합성 Mac B';peer.state.name=peer.name;peer.local=false;peer.online=peerOnline;
    if(peerOld)peer.release=peer.state.release={version:'0.2.158',build:185,api:1};
    return json(200,{...a,partial:false,nodes:[own,peer]});
   }
   if(url.pathname.startsWith('/api/')){
    const node=url.searchParams.get('node'),index=node===ids[1]?1:0;url.searchParams.delete('node');
    const body=req.method==='POST'?await new Promise((resolve,reject)=>{let text='';req.on('data',v=>text+=v);req.on('end',()=>resolve(text));req.on('error',reject);}):undefined;
    const payload=body?JSON.parse(body):null;
    if(payload){posts.push({index,path:url.pathname,...payload});assert.equal(url.pathname,'/api/action');assert.ok(['resetAutomation','beginQuestion','automatic'].includes(payload.action),'Unexpected mutation '+payload.action);}
    if(payload?.action==='resetAutomation'&&failReset){failReset=false;return json(503,{error:'합성 연결 오류 · 현재 상태를 확인한 뒤 다시 시도해주세요.'});}
    if(url.pathname==='/api/terminal/stream'){
     const controller=new AbortController();res.once('close',()=>controller.abort());
     try {
      const upstream=await fetch(bases[index]+url.pathname+url.search,{signal:controller.signal});
      res.writeHead(upstream.status,{'Content-Type':upstream.headers.get('content-type')||'text/event-stream','Cache-Control':'no-store'});
      for await(const bytes of upstream.body){if(controller.signal.aborted)break;res.write(bytes);}
      res.end();
     }catch(error){if(!controller.signal.aborted)throw error;}
     return;
    }
    const upstream=await fetch(bases[index]+url.pathname+url.search,{method:req.method,...(body?{body,headers:{'Content-Type':'application/json'}}:{})});
    const bytes=Buffer.from(await upstream.arrayBuffer());
    if(payload?.action==='resetAutomation'&&holdReset)await holdReset;
    res.writeHead(upstream.status,{'Content-Type':upstream.headers.get('content-type')||'application/json','Cache-Control':'no-store'});res.end(bytes);return;
   }
   const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
   if(!['index.html','app.js','app.css','favicon.svg'].includes(name)){res.writeHead(404);res.end();return;}
   let bytes=await readFile(assets+'/'+name);
   if(name==='index.html')bytes=Buffer.from(bytes.toString().replace('__AUTOAPPROVE_WEB_VERSION__',JSON.stringify(published).replaceAll('"','&quot;')));
   res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});res.end(bytes);
  }catch(error){errors.push(error.message);if(!res.headersSent)res.writeHead(500);res.end();}
 });
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
 browser=await(engine==='webkit'?webkit:chromium).launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 const base='http://127.0.0.1:'+server.address().port;
 for(const [label,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  peerOnline=true;peerOld=false;
  const page=await browser.newPage({viewport:{width,height},hasTouch:width<1000});page.setDefaultTimeout(15000);
  page.on('pageerror',error=>errors.push(error.message));
  await page.goto(base);await page.waitForFunction(()=>connected&&!loadingNetwork);
  async function select(index){
   if(await page.locator('#terminal-back').isVisible())await page.locator('#terminal-back').click();
   const row=page.locator('#session-list .session-row').filter({hasText:'Codex'}).nth(index);
   await row.click();await page.waitForFunction(()=>!!selectedItem);
  }
  async function settings(){if(await page.locator('#terminal-settings').getAttribute('open')===null)await page.locator('#terminal-settings>summary').click();}
  async function capture(name){
   await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
   await page.screenshot({path:path.join(out,engine+'-'+label+'-'+name+'.png'),fullPage:true});
   assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,label+' overflow');views.push(label+'-'+name);
   if(await page.locator('#terminal-settings').evaluate(el=>el.open)){
    const bounds=await page.locator('#terminal-settings .terminal-options').boundingBox(),detail=await page.locator('#detail').boundingBox();
    const visible=await page.evaluate(()=>({top:visualViewport?.offsetTop||0,height:visualViewport?.height||innerHeight}));
    assert.ok(bounds.y>=Math.max(visible.top,detail.y)-1&&bounds.y+bounds.height<=Math.min(visible.top+visible.height,detail.y+detail.height)+1,name+' menu is clipped');
    assert.equal(await page.locator('#terminal-settings .terminal-options').evaluate(el=>getComputedStyle(el).flexWrap),'nowrap');
   }
  }
  await select(0);await settings();assert.equal(await page.locator('#reset-automation').isDisabled(),false);
  await page.locator('#reset-automation').focus();await capture('ready');
  assert.equal(await page.locator('#reset-automation').evaluate(el=>el.getBoundingClientRect().height>=44),true);
  assert.equal(await page.locator('#reset-automation').getAttribute('aria-describedby'),'reset-automation-help');
  if(width===1440){
   await page.setViewportSize({width,height:650});await page.locator('#terminal-settings>summary').scrollIntoViewIfNeeded();
   await page.waitForFunction(()=>$('terminal-settings').dataset.placement==='above');await capture('short-window-above');
   await page.setViewportSize({width,height});
  }
  if(width===390){
   await page.evaluate(()=>{Object.defineProperty(visualViewport,'height',{configurable:true,value:280});visualViewport.dispatchEvent(new Event('resize'));});
   await page.locator('#reset-automation').scrollIntoViewIfNeeded();
   const bounds=await page.locator('#terminal-settings .terminal-options').boundingBox();assert.ok(bounds.y+bounds.height<=282,'Recovery menu must fit above a simulated phone keyboard');await capture('keyboard-height-280');
   await page.evaluate(()=>{delete visualViewport.height;visualViewport.dispatchEvent(new Event('resize'));});
  }
  // A recovery must preserve a user-authored draft and its original session key.
  await page.evaluate(()=>{drafts.set(selectedKey,'작성 중인 한글 초안 👩🏽‍💻');$('terminal-input').value=drafts.get(selectedKey);});
  const aBefore=await eventCount(0),bBefore=await eventCount(1),before=posts.length;
  holdReset=new Promise(resolve=>releaseReset=resolve);
  await page.locator('#reset-automation').click();
  await page.waitForFunction(()=>$('reset-automation').disabled&&$('reset-automation').getAttribute('aria-busy')==='true');
  await capture('pending');assert.match(await page.locator('#reset-automation-result').textContent(),/비우고/);
  releaseReset();holdReset=null;releaseReset=null;
  await page.waitForFunction(()=>!automationResets.size&&$('reset-automation-result').textContent.includes('초기화했습니다'));
  assert.equal(posts.slice(before).filter(value=>value.action==='resetAutomation').length,1);
  assert.equal(posts.at(-1).index,0);assert.equal(await eventCount(0),aBefore+1);assert.equal(await eventCount(1),bBefore);
  assert.match(await page.locator('#reset-automation-result').textContent(),/일시정지/);
  assert.equal(await page.evaluate(()=>$('terminal-input').value),'작성 중인 한글 초안 👩🏽‍💻');await capture('success');
  failReset=true;await page.locator('#reset-automation').click();await page.waitForFunction(()=>!automationResets.size&&automationResetResult?.error);
  assert.match(await page.locator('#reset-automation-result').textContent(),/연결 오류/);assert.equal(await page.locator('#reset-automation').isDisabled(),false);await capture('failure');
  await page.locator('#reset-automation').click();await page.waitForFunction(()=>!automationResets.size&&automationResetResult&&!automationResetResult.error);
  await page.evaluate(async()=>{clearTimeout(networkTimer);await refreshNetwork();clearTimeout(networkTimer);});
  peerOld=true;await page.evaluate(async()=>{await refreshNetwork();clearTimeout(networkTimer);});await select(1);await settings();
  assert.equal(await page.locator('#reset-automation').isDisabled(),true);assert.match(await page.locator('#reset-automation-help').textContent(),/0\.2\.159/);
  await capture('old-version');
  peerOld=false;peerOnline=false;await page.evaluate(async()=>{await refreshNetwork();clearTimeout(networkTimer);});
  assert.equal(await page.locator('#reset-automation').isDisabled(),true);
  peerOnline=true;await page.evaluate(async()=>{await refreshNetwork();clearTimeout(networkTimer);});
  assert.equal(await page.locator('#reset-automation').isDisabled(),false);
  const aStable=await eventCount(0),bStable=await eventCount(1);
  await page.locator('#reset-automation').click();await page.waitForFunction(()=>!automationResets.size&&automationResetResult?.key===selectedKey&&!automationResetResult.error);
  assert.equal(posts.at(-1).index,1);assert.equal(await eventCount(0),aStable);assert.equal(await eventCount(1),bStable+1);
  await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});await capture('peer-dark');
  checks.push(label+': ready/focus, 44px target, pending/single POST, success, preserved draft/pause, error/retry, old/offline/reconnected peer, exact Mac isolation');
  await page.close();
 }
 assert.deepEqual(errors,[]);
 const report={passed:true,engine,checks,views,posts:posts.map(({index,path,action})=>({index,path,action})),errors,
  assets:Object.fromEntries(await Promise.all(['index.html','app.js','app.css','web-version.json'].map(async name=>[name,hash(await readFile(assets+'/'+name))]))),
  scope:'Two production Swift HTTP handlers with isolated synthetic sessions on loopback; no original terminal input, capture, services or LAN discovery. UI proxy injects old/offline states and one pre-dispatch HTTP error. Physical phone not tested.'};
 await writeFile(path.join(out,engine+'-report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}catch(error){await writeFile(path.join(out,engine+'-failure.json'),JSON.stringify({error:error.message,errors,checks,views,posts},null,2)+'\n');throw error;}
finally{
 releaseReset?.();await browser?.close();
 if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
 for(const child of children)if(child.exitCode===null)child.kill('SIGTERM');
 await Promise.all(children.map(child=>child.exitCode!==null?null:new Promise(resolve=>{child.once('exit',resolve);setTimeout(resolve,2000);})));await rm(root,{recursive:true,force:true});
}
