// Synthetic originals only. Measures idle inventory traffic and DOM work, then
// exercises updates/reconnection without ever reaching a user's terminal.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {readFile, mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
const {chromium, webkit} = await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const baseline = process.argv.includes('--baseline');
const useWebKit = process.argv.includes('--webkit');
const output = path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT || 'dist/qa/web-resource');
const assets = path.resolve(process.env.AUTOAPPROVE_QA_ASSETS || 'Sources/AutoApproveCore/Resources/RemoteWeb');
await mkdir(output, {recursive:true});
const release = JSON.parse(await readFile(path.join(assets, 'web-version.json'), 'utf8'));
const keys = ['text','submit','characters','backspace','enter','left','right','up','down','tab','escape'];
const sessions = Array.from({length:24}, (_, index) => ({
  title:`합성 터미널 ${index+1} · 긴 프로젝트 이름과 한글 입력`, phaseTitle:'입력 대기', canRead:true, canApprove:true, canReveal:false, keys,
  session:{id:'session-'+index,agent:index%2?'claude':'codex',pid:81000+index,started:'fixture-start-'+index,tty:'/dev/fixture-'+index,
    cwd:'/fixture/긴-프로젝트-'+index,terminal:'iterm',phase:'idle',automatic:false,queuedQuestions:[]}
}));
const frame = {sessionID:sessions[0].session.id, revision:'1', sequence:1, streamID:'fixture-original', screen:'합성 원본 터미널\nREADY> ', keys};
let unavailable = false, protocol = true, unexpected304 = false, hanging = false;
const stats = {inventory:0, full:0, unchanged:0, bytes:0, posts:0, streams:0};
const clients = new Set(), errors = [], checks = [], screenshots = [];
const state = () => ({gatewayID:'fixture',gatewayRelease:release,nodes:[{id:'fixture',name:'검증 Mac · 원본 유지',local:true,online:true,release,
  state:{id:'fixture',name:'검증 Mac · 원본 유지',release,historyDeferred:true,snapshot:{paused:false,events:[]},sessions}}]});
const server = createServer(async (req,res) => {
  const url = new URL(req.url,'http://localhost');
  const json = value => {res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
  if (url.pathname === '/api/network') {
    stats.inventory++;
    if (hanging) return;
    if (unavailable) {res.writeHead(503,{'Content-Type':'application/json'});res.end(JSON.stringify({error:'검증용 일시 연결 끊김'}));return;}
    const value = state(), now = new Date().toISOString();
    const etag = 'W/"'+createHash('sha256').update(JSON.stringify(value)).digest('hex')+'"';
    const notModified = protocol && (req.headers['if-none-match'] === etag || unexpected304);
    const body = notModified ? '' : JSON.stringify({...value,updatedAt:now});
    stats[notModified?'unchanged':'full']++;stats.bytes += Buffer.byteLength(body);
    res.writeHead(notModified?304:200,{'Content-Type':'application/json','Cache-Control':'no-store',
      ...(protocol?{'ETag':etag,'X-AutoApprove-Observed-At':now}:{})});res.end(body);return;
  }
  if (url.pathname === '/api/history') return json([]);
  if (url.pathname === '/api/terminal/stream') {
    stats.streams++;res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store'});res.flushHeaders();
    const send = () => res.write('event: screen\ndata: '+JSON.stringify({...frame,observedAt:new Date().toISOString()})+'\n\n');
    send();const timer = setInterval(send,1000);clients.add(res);
    res.on('close',()=>{clearInterval(timer);clients.delete(res);});return;
  }
  if (url.pathname === '/api/terminal') return json({...frame,observedAt:new Date().toISOString()});
  if (req.method === 'POST') {stats.posts++;return json({message:'합성 입력 확인'});}
  if (url.pathname.startsWith('/api/')) return json({});
  const file = url.pathname === '/' ? 'index.html' : url.pathname.slice(1);
  if (!['index.html','app.js','app.css','favicon.svg'].includes(file)) {res.writeHead(404);res.end();return;}
  res.writeHead(200,{'Content-Type':file.endsWith('.html')?'text/html':file.endsWith('.css')?'text/css':file.endsWith('.svg')?'image/svg+xml':'text/javascript'});
  res.end(await readFile(path.join(assets,file)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser = await (useWebKit ? webkit : chromium).launch({headless:true,...(!useWebKit && process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
let metrics;
try {
  const page = await browser.newPage({viewport:{width:1440,height:900}});
  page.setDefaultTimeout(7000);page.on('pageerror',error=>errors.push(error.message));
  await page.goto('http://127.0.0.1:'+server.address().port);
  await page.waitForFunction(()=>!loadingNetwork&&allSessions.length===24);
  await page.evaluate(()=>selectSession(allSessions[0].key));
  await page.waitForFunction(()=>latestFrame?.screen.includes('READY>'));
  await page.evaluate(()=>{$('terminal-settings').open=true;$('compose-input').click();});
  await page.locator('#terminal-input').fill('유지할 한글 초안 🙂');
  await page.evaluate(async()=>{await refreshNetwork();clearTimeout(networkTimer);});
  const before = {...stats};
  await page.evaluate(()=>{
    window.resourceCounts={mutations:0,list:0,machines:0,detail:0};
    const observer = new MutationObserver(entries=>{window.resourceCounts.mutations+=entries.filter(entry=>!['refresh','connection'].includes(entry.target.id)).length;});
    observer.observe(document.body,{attributes:true,childList:true,subtree:true,characterData:true});window.resourceObserver=observer;
    const list=renderList,machines=renderMachines,detail=renderDetail;
    renderList=(...args)=>{window.resourceCounts.list++;return list(...args);};
    renderMachines=(...args)=>{window.resourceCounts.machines++;return machines(...args);};
    renderDetail=(...args)=>{window.resourceCounts.detail++;return detail(...args);};
  });
  const start = performance.now();
  for(let index=0;index<20;index++) await page.evaluate(async()=>{await refreshNetwork();clearTimeout(networkTimer);});
  metrics = {...await page.evaluate(()=>{window.resourceObserver.disconnect();return window.resourceCounts;}),
    inventory:stats.inventory-before.inventory,full:stats.full-before.full,unchanged:stats.unchanged-before.unchanged,
    responseBodyBytes:stats.bytes-before.bytes,elapsedMS:performance.now()-start};
  await writeFile(path.join(output,'metrics.json'),JSON.stringify(metrics,null,2));
  assert.equal(metrics.inventory,20);assert.equal(await page.locator('#terminal-input').inputValue(),'유지할 한글 초안 🙂');
  if (!baseline) {assert.equal(metrics.unchanged,20);assert.equal(metrics.responseBodyBytes,0);assert.equal(metrics.list,0);assert.equal(metrics.machines,0);assert.equal(metrics.detail,0);}
  checks.push('20 unchanged inventories: payload, render calls and DOM mutations measured; original input draft retained');
  sessions[0].title='갱신된 원본 터미널';
  await page.evaluate(()=>refreshNetwork());await page.getByRole('heading',{name:'갱신된 원본 터미널',exact:true}).first().waitFor();
  assert.equal(await page.locator('#terminal-input').inputValue(),'유지할 한글 초안 🙂');
  unavailable=true;await page.evaluate(()=>refreshNetwork());assert.equal(await page.locator('#network-error').isVisible(),true);
  assert.equal(await page.evaluate(()=>!!terminalStream&&latestFrame?.streamID==='fixture-original'),true);
  unavailable=false;await page.evaluate(()=>refreshNetwork());assert.equal(await page.locator('#network-error').isVisible(),false);
  assert.equal(await page.locator('#terminal-input').inputValue(),'유지할 한글 초안 🙂');
  protocol=false;await page.evaluate(()=>refreshNetwork());sessions[0].title='이전 Mac 호환 원본';await page.evaluate(()=>refreshNetwork());
  await page.getByRole('heading',{name:'이전 Mac 호환 원본',exact:true}).first().waitFor();protocol=true;
  checks.push('Changed inventory, transient failure, 304 recovery and legacy 200 responses preserve original ownership and drafts');
  if (!baseline) {
    // No saved body exists for a fresh page: a stray 304 must fail visibly,
    // then recover with a normal full read rather than accepting empty state.
    unexpected304=true;const fresh=await browser.newPage();await fresh.goto('http://127.0.0.1:'+server.address().port);
    await fresh.locator('#network-error').waitFor({state:'visible'});unexpected304=false;
    await fresh.evaluate(()=>refreshNetwork());await fresh.waitForFunction(()=>allSessions.length===24&&connected);await fresh.close();
    checks.push('Unexpected 304 without an in-memory snapshot fails visibly and recovers');
  }
  // A document can become hidden while an inventory request is in flight.
  // The browser must not accept its late result or leave it running for 20s.
  if (!baseline) {
    hanging=true;await page.evaluate(()=>{void refreshNetwork();});
    await page.waitForFunction(()=>loadingNetwork);
    await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'));});
    await page.waitForFunction(()=>!loadingNetwork,undefined,{timeout:2000});hanging=false;
    await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>false});document.dispatchEvent(new Event('visibilitychange'));});
    await page.waitForFunction(()=>connected&&!loadingNetwork&&!!latestFrame);
    checks.push('Hidden-tab in-flight inventory is aborted; visibility restore reconnects the same original without input replay');
  }
  for (const [label,size] of [['desktop',{width:1440,height:900}],['tablet',{width:768,height:1024}],['mobile',{width:390,height:844}]]) {
    await page.setViewportSize(size);await page.evaluate(()=>{terminalFocus(false);});
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,label+' page overflow');
    const name=label+'.png';await page.screenshot({path:path.join(output,name)});screenshots.push(name);
    if(size.width<760) {await page.locator('#back').click();await page.getByRole('button',{name:/이전 Mac 호환 원본/}).click();assert.equal(await page.locator('#terminal-input').inputValue(),'유지할 한글 초안 🙂');}
  }
  if (await page.locator('body').evaluate(body=>body.classList.contains('terminal-focus'))) await page.locator('#terminal-focus').click();
  await page.locator('#back').click();await page.locator('#search').fill('찾을 수 없는 합성 세션');
  assert.equal(await page.locator('#list-empty').isVisible(),true);
  assert.equal(stats.posts,0,'No input or mutation should be replayed by inventory validation/reconnect');
  checks.push('Mobile/tablet/desktop overflow, mobile back, long labels, empty search and no input replay');
  assert.deepEqual(errors,[]);
  await writeFile(path.join(output,baseline?'baseline.json':'verification.json'),JSON.stringify({browser:useWebKit?'webkit':'chromium',baseline,metrics,checks,screenshots,errors},null,2));
  console.log(JSON.stringify({browser:useWebKit?'webkit':'chromium',baseline,metrics,checks:checks.length,screenshots,errors},null,2));
} finally {await browser.close();for(const client of clients)client.destroy();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
