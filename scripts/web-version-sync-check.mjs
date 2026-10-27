// Exact product assets in real browsers; owned version responses only.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,writeFile,mkdir} from 'node:fs/promises';
import path from 'node:path';
const option=n=>process.argv.find(v=>v.startsWith('--'+n+'='))?.slice(n.length+3);
const engine=process.argv.includes('--webkit')?'webkit':'chromium',out=path.resolve(option('output')||'.runtime/cloudflare-version-192/web-'+engine),web=path.resolve('Sources/AutoApproveCore/Resources/RemoteWeb');
await mkdir(out,{recursive:true});
const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
const version=(patch,build=patch+27)=>({version:'0.2.'+patch,build,api:1}),checks=[],errors=[];
const id='00000000-0000-4000-8000-000000000192';
async function scenario(name,client,initialHost,run) {
 let host=initialHost,latest=version(193),phase='idle',detail='정식 최신 버전을 확인할 수 있습니다.',enabled=true,update={enabled:true,phase:'idle',detail:'준비'},denied=false,legacy=false;
 const sockets=new Set(),posts=[];let port;
 const status=()=>({phase,detail,host,latest:phase==='ready'?latest:null,latestVersion:phase==='ready'?latest.version:null,canSync:phase==='ready'&&enabled,update:{...update,enabled}});
 const server=createServer(async(req,res)=>{
  const url=new URL(req.url,'http://fixture'),json=(code,value)=>{res.writeHead(code,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
  if(req.method==='POST') {
   let text='';for await(const part of req)text+=part;const body=JSON.parse(text);posts.push({path:url.pathname,body});
   if(denied){json(401,{error:'접속 시간이 끝났습니다.'});return;}
   if(legacy){json(404,{error:'지원하지 않는 동작입니다.'});return;}
   if(!['/api/version/check','/api/version/sync'].includes(url.pathname)){json(405,{});return;}
   if(url.pathname==='/api/version/sync')update={enabled,phase:'waiting',detail:'입력 전송이 끝난 뒤 업데이트합니다.'};
   await new Promise(resolve=>setTimeout(resolve,200));phase='ready';detail=enabled?'정식 릴리스를 확인했습니다.':'자동 업데이트가 꺼져 있습니다.';json(200,status());return;
  }
  if(url.pathname==='/api/version') {
   if(legacy){json(404,{});return;}
   const old=status();await new Promise(resolve=>setTimeout(resolve,500));json(200,old);return;
  }
  if(url.pathname==='/api/network'){
   json(200,{gatewayID:id,gatewayRelease:host,updatedAt:new Date().toISOString(),nodes:[{id,name:'버전 확인 Mac',local:true,online:true,state:{snapshot:{paused:false,events:[]},sessions:[],release:host,update:{...update,enabled}}}]});return;
  }
  if(url.pathname.startsWith('/api/')){json(200,{});return;}
  const file=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(!['index.html','app.js','app.css','favicon.svg','terminal-wire.js','input-channel.js'].includes(file)){res.writeHead(404);res.end();return;}
  let body=await readFile(path.join(web,file));
  if(file==='index.html'){
   const loaded=url.searchParams.has('version')?host:client;
   body=Buffer.from(body.toString().replace('<head>','<head><meta name="autoapprove-tunnel" content="stream">').replace('__AUTOAPPROVE_WEB_VERSION__',`${loaded.version}:${loaded.build}:1`));
  }
  res.writeHead(200,{'Content-Type':file.endsWith('html')?'text/html':file.endsWith('css')?'text/css':'text/javascript','Cache-Control':'no-store'});res.end(body);
 });
 server.on('connection',s=>{sockets.add(s);s.once('close',()=>sockets.delete(s));});
 await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));port=server.address().port;
 const context=await browser.newContext({viewport:{width:390,height:844}}),page=await context.newPage();page.setDefaultTimeout(5000);page.on('pageerror',e=>errors.push(e.message));
 const control={page,context,posts,url:'http://127.0.0.1:'+port,setHost:v=>host=v,setLatest:v=>latest=v,setEnabled:v=>enabled=v,setDenied:v=>denied=v,setLegacy:v=>legacy=v,setUpdate:v=>update=v};
 try {await run(control);assert.ok(posts.every(p=>['/api/version/check','/api/version/sync'].includes(p.path)));checks.push(name);}
 catch(e){await page.screenshot({path:out+'/'+name+'-failure.png'}).catch(()=>{});throw e;}
 finally {await context.close();for(const s of sockets)s.destroy();await new Promise(resolve=>server.close(resolve));}
}
try {
 await scenario('browser-newer',version(192),version(191),async({page,url,posts})=>{
  await page.goto(url);await page.locator('#sync-version').waitFor({state:'visible'});
  await page.waitForTimeout(600);assert.match(await page.locator('#version-sync-message').textContent(),/正式|정식 v0\.2\.193/);
  assert.equal(posts.filter(p=>p.path==='/api/version/check').length,1,'A late initial status cannot replace the completed check');
  await page.locator('#search').fill('작성 중 한글');await page.locator('#sync-version').click();
  await page.waitForFunction(()=>document.getElementById('version-sync-message').textContent.includes('입력 전송'));
  assert.equal(await page.locator('#sync-version').isDisabled(),true);assert.equal(await page.locator('#search').inputValue(),'작성 중 한글');
  assert.deepEqual(posts.at(-1).body.client,version(192));
  for(const[label,w,h]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width:w,height:h});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/waiting-'+label+'.png'});}
 });
 await scenario('host-newer',version(191),version(192),async({page,url,context})=>{
  await page.goto(url);await page.locator('#sync-web').waitFor({state:'visible'});await page.locator('#search').fill('원래 초안');
  const opened=context.waitForEvent('page');await page.locator('#sync-web').click();const fresh=await opened;await fresh.waitForLoadState();
  assert.equal(new URL(fresh.url()).origin,new URL(url).origin);assert.ok(new URL(fresh.url()).searchParams.has('version'));
  await fresh.waitForFunction(()=>document.getElementById('version-sync-message').textContent.includes('웹 v0.2.192'));
  assert.equal(await page.locator('#search').inputValue(),'원래 초안');assert.equal(page.url(),url+'/');
 });
 await scenario('equal-manual-latest',version(192),version(192),async({page,url,posts})=>{
  await page.goto(url);await page.locator('#version-sync').waitFor({state:'visible'});assert.equal(posts.length,0);
  await page.locator('#check-version').click();assert.equal(await page.locator('#check-version').isDisabled(),true);
  await page.locator('#sync-version').waitFor({state:'visible'});assert.match(await page.locator('#version-sync-message').textContent(),/PIN/);
  await page.emulateMedia({colorScheme:'dark'});await page.setViewportSize({width:1440,height:900});
  await page.waitForFunction(()=>connected&&!loadingNetwork&&!versionSyncBusy&&!document.getElementById('check-version').disabled);
  await page.screenshot({path:out+'/available-dark-desktop.png',animations:'disabled'});
  await page.locator('#check-version').focus();assert.equal(await page.locator('#check-version').evaluate(e=>e===document.activeElement),true);
 });
 await scenario('disabled',version(192),version(192),async({page,url,setEnabled})=>{
  setEnabled(false);await page.goto(url);await page.locator('#check-version').click();await page.waitForFunction(()=>document.getElementById('version-sync-message').textContent.includes('자동 업데이트'));
  assert.equal(await page.locator('#sync-version').isVisible(),false);
 });
 await scenario('unpublished-browser',version(194),version(192),async({page,url,posts})=>{
  await page.goto(url);await page.waitForFunction(()=>document.getElementById('version-sync-message').textContent.includes('아직 준비되지'));
  assert.equal(await page.locator('#sync-version').isVisible(),false);assert.equal(await page.locator('#sync-web').isVisible(),false);
  assert.ok(posts.every(p=>p.path==='/api/version/check'));
 });
 await scenario('failed-installation',version(192),version(192),async({page,url,setUpdate})=>{
  setUpdate({enabled:true,phase:'failed',detail:'같은 게시자 서명인지 확인하지 못해 업데이트를 중단했습니다.'});
  await page.goto(url);await page.waitForFunction(()=>document.getElementById('version-sync-message').textContent.includes('게시자 서명'));
  assert.equal(await page.locator('#check-version').isEnabled(),true);
 });
 await scenario('legacy',version(192),version(191),async({page,url,setLegacy})=>{
  setLegacy(true);await page.goto(url);await page.waitForFunction(()=>document.getElementById('version-sync-message').textContent.includes('지원하지 않습니다'));
  assert.equal(await page.locator('#check-version').isEnabled(),true);
 });
 await scenario('session-expiry',version(192),version(192),async({page,url,setDenied})=>{
  await page.goto(url);await page.locator('#version-sync').waitFor({state:'visible'});setDenied(true);await page.locator('#check-version').click();
  await page.waitForFunction(()=>tunnelAuthExpired);assert.equal(await page.locator('#check-version').isDisabled(),true);
 });
 await scenario('long-wait-and-applying',version(192),version(192),async({page,url,setUpdate})=>{
  setUpdate({enabled:true,phase:'waiting',detail:'덮개를 열면 업데이트합니다. '+('긴 연결 상태 안내 '.repeat(30))});await page.goto(url);await page.locator('#version-sync').waitFor({state:'visible'});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/long-mobile.png'});
  setUpdate({enabled:true,phase:'applying',detail:'AutoApprove를 업데이트하고 다시 엽니다.'});await page.getByRole('button',{name:'상태 새로고침'}).click();
  await page.waitForFunction(()=>document.getElementById('version-sync-message').textContent.includes('다시 엽니다'));
  assert.equal(await page.locator('#check-version').isDisabled(),true);
 });
 assert.deepEqual(errors,[]);const report={passed:true,engine,checks,errors,viewports:[[390,844],[768,1024],[1440,900]],scope:'Exact product web assets and controlled host/version replies in real browser; native signed installation is tested separately; no user terminal input'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
} finally {await browser.close();}
