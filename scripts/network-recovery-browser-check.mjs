// Real browser, exact web assets, synthetic inventories and owned HTTP faults.
// No installed app, user session, terminal input or system setting is changed.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';

const option = name => process.argv.find(value => value.startsWith('--'+name+'='))?.slice(name.length+3);
const engine = process.argv.includes('--webkit') ? 'webkit' : 'chromium';
const only = option('case');
const output = path.resolve(option('output') || 'dist/qa/network-recovery/'+engine);
const webRoot = path.resolve(option('web-root') || 'Sources/AutoApproveCore/Resources/RemoteWeb');
await mkdir(output,{recursive:true});
const playwright = await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const browser = await playwright[engine].launch({headless:true,...(engine==='chromium' && process.env.AUTOAPPROVE_CHROMIUM_PATH ? {executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH} : {})});
const checks = [], metrics = [], errors = [];
const view = {session:{id:'synthetic-original',agent:'codex',pid:7100,started:'fixture',tty:'/dev/fixture',cwd:'/fixture/project',terminal:'iterm',phase:'idle',automatic:false,queuedQuestions:[]},title:'연결 복구 검증',phaseTitle:'입력 대기',canRead:false,canReveal:false,canApprove:false,keys:[]};
const inventory = () => ({gatewayID:'fixture-mac',updatedAt:new Date().toISOString(),nodes:[{id:'fixture-mac',name:'연결 검증 Mac',local:true,online:true,state:{snapshot:{paused:false,events:[]},sessions:[view],release:{version:'0.2.179',build:206,api:1}}}]});

async function scenario(name,run) {
  if (only && name!==only) return;
  const sockets = new Set(), held = new Set(), reads = [];
  let mode = name==='optional-codec' ? 'codec-held' : ['online-recovery','deadline-recovery'].includes(name) ? 'held' : 'healthy';
  let failures = 0, writes = 0, active = 0, maxActive = 0;
  const server = createServer(async(req,res) => {
    const url = new URL(req.url,'http://fixture');
    if (req.method!=='GET') { writes++;res.writeHead(405);res.end();return; }
    if (url.pathname==='/api/network') {
      const row = {at:performance.now(),mode,initial:url.searchParams.get('initial')==='1',tag:req.headers['if-none-match'],closed:false};
      reads.push(row);active++;maxActive=Math.max(active,maxActive);
      res.once('close',()=>{row.closed=true;active--;held.delete(res);});
      if (mode==='held') { held.add(res);return; }
      if (failures>0) { failures--;res.writeHead(503,{'Content-Type':'application/json'});res.end('{"error":"Synthetic temporary outage"}');return; }
      const tag='W/"synthetic-inventory"',unchanged=req.headers['if-none-match']===tag;
      res.writeHead(unchanged?304:200,{'Content-Type':'application/json','Cache-Control':'no-store',ETag:tag,'X-AutoApprove-Observed-At':new Date().toISOString()});
      res.end(unchanged?undefined:JSON.stringify(inventory()));return;
    }
    if (url.pathname==='/terminal-wire.js' && mode==='codec-held') { held.add(res);res.once('close',()=>held.delete(res));return; }
    if (url.pathname.startsWith('/api/')) { res.writeHead(200,{'Content-Type':'application/json'});res.end('{}');return; }
    const file = url.pathname==='/' ? 'index.html' : url.pathname.slice(1);
    if (!['index.html','app.js','terminal-wire.js','app.css','favicon.svg'].includes(file)) { res.writeHead(404);res.end();return; }
    try {
      const body=await readFile(path.join(webRoot,file));
      res.writeHead(200,{'Content-Type':file.endsWith('.html')?'text/html':file.endsWith('.css')?'text/css':file.endsWith('.svg')?'image/svg+xml':'text/javascript','Cache-Control':'no-store'});res.end(body);
    } catch { res.writeHead(404);res.end(); }
  });
  server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const page=await browser.newPage({viewport:{width:390,height:844}});page.setDefaultTimeout(5000);page.on('pageerror',error=>errors.push(error.message));
  const fixture={page,reads,held,url:'http://127.0.0.1:'+server.address().port,setMode:value=>mode=value,setFailures:value=>failures=value};
  try { await run(fixture);assert.equal(writes,0);checks.push({name,passed:true,reads:reads.length,maxActive}); }
  finally { await page.close();for(const res of held)res.destroy();for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve)); }
}

try {
  await scenario('optional-codec',async({page,url,reads})=>{
    // A deferred optional script must not gate the main application or its API.
    const start=performance.now();await page.goto(url,{waitUntil:'commit'});
    await page.locator('.session-row').waitFor({timeout:2500});
    assert.ok(reads.length>0);assert.match(await page.locator('#connection').textContent(),/1대 연결/);
    await page.getByRole('button',{name:'Mac 추가',exact:true}).click();await page.locator('#add-dialog').waitFor({state:'visible'});await page.keyboard.press('Escape');
    metrics.push({case:'Inventory usable while optional codec never responds',ms:Math.round(performance.now()-start)});
  });
  await scenario('online-recovery',async({page,url,reads,setMode})=>{
    await page.goto(url);await page.waitForFunction(()=>loadingNetwork);
    assert.equal(reads.length,1);setMode('healthy');const start=performance.now();
    await page.evaluate(()=>{for(let i=0;i<8;i++)window.dispatchEvent(new Event('online'));});
    await page.locator('.session-row').waitFor({timeout:2000});
    assert.equal(reads.filter(row=>row.initial).length,2,'Connectivity notifications coalesce into one replacement initial read');assert.equal(reads[0].closed,true);
    await page.waitForFunction(()=>!loadingNetwork);
    assert.equal(await page.locator('#refresh').getAttribute('aria-busy'),null);
    metrics.push({case:'Online replaces a stalled inventory read',ms:Math.round(performance.now()-start)});
  });
  await scenario('deadline-recovery',async({page,url,reads,setMode})=>{
    await page.goto(url);await page.waitForFunction(()=>loadingNetwork);setMode('healthy');const start=performance.now();
    await page.locator('.session-row').waitFor({timeout:12000});
    assert.equal(reads[0].closed,true);assert.equal(reads.filter(row=>row.initial).length,2);
    metrics.push({case:'Stalled first read recovers without browser connectivity notifications',ms:Math.round(performance.now()-start)});
  });
  await scenario('sustained-outage',async({page,url,reads,setFailures})=>{
    setFailures(100);await page.goto(url);await page.locator('#network-error').waitFor({state:'visible'});
    await page.waitForTimeout(4200);
    assert.ok(reads.length>=3&&reads.length<=4,'A sustained outage backs off instead of continuously polling');
    await page.screenshot({path:path.join(output,'disconnected.png')});
    const before=reads.length;setFailures(0);await page.evaluate(()=>window.dispatchEvent(new Event('online')));
    await page.locator('.session-row').waitFor({timeout:2000});assert.ok(reads.length>before);
    metrics.push({case:'Persistent errors back off and online bypasses their wait',failedReads:before});
  });
  await scenario('transient-recovery',async({page,url,reads,setFailures,setMode})=>{
    await page.goto(url);await page.locator('.session-row').waitFor();await page.waitForFunction(()=>!loadingNetwork);
    // Reach steady conditional polling before injecting one failed read.
    await page.getByRole('button',{name:'상태 새로고침'}).click();await page.waitForFunction(()=>!loadingNetwork);
    assert.ok(reads.at(-1).tag);setFailures(1);const start=performance.now();
    await page.getByRole('button',{name:'상태 새로고침'}).click();await page.locator('#network-error').waitFor({state:'visible'});
    assert.equal(await page.locator('.session-row').count(),1);
    await page.locator('#network-error').waitFor({state:'hidden',timeout:2500});
    metrics.push({case:'One failed read recovers automatically',ms:Math.round(performance.now()-start)});
    await page.waitForFunction(()=>!loadingNetwork);
    const count=reads.length;await page.waitForTimeout(1100);assert.equal(reads.length,count,'Healthy inventories retain their 2.5-second cadence');
    setMode('held');await page.getByRole('button',{name:'상태 새로고침'}).click();await page.waitForFunction(()=>loadingNetwork);
    await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});
    await page.waitForFunction(()=>!loadingNetwork);const hiddenReads=reads.length;await page.waitForTimeout(300);assert.equal(reads.length,hiddenReads);
    setMode('healthy');await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));});
    await page.waitForFunction(()=>connected&&!loadingNetwork);
    for(const [name,width,height] of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]) {
      await page.setViewportSize({width,height});await page.screenshot({path:path.join(output,name+'.png')});
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    }
  });
  assert.deepEqual(errors,[]);
  const report={result:'PASS',engine,checks,metrics,errors,scope:'Real browser, exact web resources, synthetic HTTP faults; no physical phone/LAN or user-session input'};
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
} finally { await browser.close(); }
