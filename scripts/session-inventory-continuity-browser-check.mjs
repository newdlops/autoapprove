// Product browser assets with synthetic inventories only. No original terminal or LAN.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {readFile,mkdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
const {chromium,webkit}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const baseline=process.argv.includes('--baseline'),engine=process.argv.includes('--webkit')?'webkit':'chromium';
const assets=path.resolve(process.env.AUTOAPPROVE_QA_ASSETS||'Sources/AutoApproveCore/Resources/RemoteWeb');
const out=path.resolve(process.env.AUTOAPPROVE_QA_OUTPUT||'dist/qa/session-inventory-continuity');
await mkdir(out,{recursive:true});
const release=JSON.parse(await readFile(assets+'/web-version.json'));
const view=(id,extra={})=>({title:'합성 세션 '+id,phaseTitle:extra.phase==='ended'?'종료':'입력 대기',canRead:false,canApprove:false,canReveal:false,keys:[],
 session:{id,agent:'codex',pid:900001,started:'synthetic-'+id,tty:'/dev/fixture-'+id,cwd:'/fixture/'+id,terminal:'iterm',automatic:false,phase:'idle',...extra}});
const error={id:'old-error',kind:'transport',detail:'합성 오류',detectedAt:'2026-10-21T00:00:00Z'};
let peerStatus='online',reverse=false,sequence=0,removed=false,empty=false;
const local=[view('current')],peer=[view('peer'),view('read-ended',{phase:'ended',interruption:{...error,acknowledgedAt:'2026-10-21T00:01:00Z'}}),view('unread-ended',{phase:'ended',interruption:{...error,id:'unread'}})],other=[view('other')];
const node=(id,sessions,status='online')=>({id,name:id==='a'?'현재 합성 Mac':'합성 Mac '+id,local:id==='a',online:status==='online',release,
 ...(status==='online'?{state:{id,name:id,release,snapshot:{paused:false,events:[]},sessions,historyDeferred:true}}:status==='pending'?{loading:true}:{error:'Synthetic inventory timeout'})});
const network=()=>({gatewayID:'a',gatewayRelease:release,updatedAt:new Date().toISOString(),fixtureSequence:sequence,partial:peerStatus==='pending',
 nodes:[node('a',local),...(reverse?[node('c',other),...(!removed?[node('b',empty?[]:peer,peerStatus)]:[])]:[...(!removed?[node('b',empty?[]:peer,peerStatus)]:[]),node('c',other)])]});
const errors=[],checks=[],views=[],shifts=[],requests={network:0,notModified:0,posts:0};
const server=createServer(async(req,res)=>{
 try {
  const url=new URL(req.url,'http://localhost');
  const json=value=>{res.writeHead(200,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
  if(url.pathname==='/api/network') {
   requests.network++;const value=network(),tag='W/"'+sequence+'"',same=req.headers['if-none-match']===tag;if(same)requests.notModified++;
   res.writeHead(same?304:200,{'Content-Type':'application/json','Cache-Control':'no-store',ETag:tag,'X-AutoApprove-Observed-At':new Date().toISOString()});res.end(same?'':JSON.stringify(value));return;
  }
  if(req.method==='POST'){requests.posts++;throw new Error('No input or mutation is permitted');}
  if(url.pathname.startsWith('/api/'))return json([]);
  const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
  if(!['index.html','app.js','app.css','favicon.svg'].includes(name)){res.writeHead(404);res.end();return;}
  res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript'});res.end(await readFile(assets+'/'+name));
 }catch(error){errors.push(error.message);res.writeHead(500);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
let browser,page;
const snapshot=()=>page.evaluate(()=>({keys:[...$('session-list').children].map(row=>[...rows].find(([,value])=>row===value)?.[0]),
 positions:[...$('session-list').children].map(row=>row.getBoundingClientRect().top-$('session-list').getBoundingClientRect().top),
 warnings:interruptionRows.size,online:currentNode()?.online,overflow:document.documentElement.scrollWidth>innerWidth}));
async function refresh(unchanged=false){if(!unchanged)sequence++;await page.evaluate(async()=>{clearTimeout(networkTimer);await refreshNetwork();clearTimeout(networkTimer);});}
async function capture(name){
 await page.evaluate(()=>{scrollTo(0,0);return new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));});
 await page.screenshot({path:path.join(out,engine+'-'+name+'.png'),fullPage:true});views.push(name);
}
try {
 browser=await(engine==='webkit'?webkit:chromium).launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
 for(const [label,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]) {
  peerStatus='online';reverse=false;removed=false;empty=false;sequence++;
  page=await browser.newPage({viewport:{width,height},hasTouch:width<1000});page.setDefaultTimeout(12000);
  page.on('pageerror',error=>errors.push(error.message));
  await page.goto('http://127.0.0.1:'+server.address().port);await page.waitForFunction(()=>connected&&!loadingNetwork);await page.evaluate(()=>clearTimeout(networkTimer));
  const before=await snapshot();await capture(label+'-online');
  const peerRow=page.locator('#session-list .session-row').filter({hasText:'합성 세션 peer'}),handle=await peerRow.elementHandle();await peerRow.focus();
  peerStatus='offline';await refresh();const failed=await snapshot();
  if(baseline) {
   assert.ok(!failed.keys.includes('b/peer'),'Expected an inventory failure to remove an existing session');
   assert.equal(await handle.evaluate(el=>el.isConnected),false);
   await capture(label+'-reproduced-removal');
  }else{
   assert.deepEqual(failed.keys,before.keys);assert.ok(await handle.evaluate(el=>el.isConnected&&document.activeElement===el));
   assert.match(await peerRow.locator('.phase').textContent(),/연결/);
   assert.equal(await page.locator('#session-list').getByText('합성 세션 read-ended',{exact:true}).count(),0);
   await capture(label+'-unavailable');
  }
  peerStatus='pending';await refresh();
  if(!baseline)assert.deepEqual((await snapshot()).keys,before.keys);
  peerStatus='online';await refresh();
  if(!baseline)assert.ok(await handle.evaluate(el=>el.isConnected&&document.activeElement===el));
  const recovered=await snapshot();reverse=true;await refresh();const reordered=await snapshot();
  const shift=Math.max(...recovered.positions.map((y,i)=>Math.abs(y-(reordered.positions[reordered.keys.indexOf(recovered.keys[i])]??y))));shifts.push(shift);
  if(baseline){assert.ok(shift>1,'Expected transport node order to move existing session rows');await capture(label+'-reproduced-reorder');}
  else{
   assert.deepEqual(reordered.keys,recovered.keys);assert.ok(shift<1,label+' rows shifted '+shift+'px');
   for(let i=0;i<4;i++){peerStatus=i%2?'pending':'offline';await refresh();assert.deepEqual((await snapshot()).keys,recovered.keys);assert.ok(await handle.evaluate(el=>el.isConnected));}
   peerStatus='offline';await refresh();await refresh(true);assert.ok(requests.notModified>0);
   await peerRow.click();assert.equal(await page.locator('#automatic').isDisabled(),true);assert.equal(await page.locator('#send-input').isDisabled(),true);
   if(width<760)await page.locator('#terminal-back').click();
   peerStatus='online';empty=true;await refresh();assert.equal(await page.locator('#session-list').getByText('합성 세션 peer',{exact:true}).count(),0);
   peerStatus='offline';await refresh();assert.equal(await peerRow.count(),0);
   empty=false;peerStatus='online';await refresh();assert.equal(await peerRow.count(),1);
   peer.reverse();await refresh();assert.deepEqual((await snapshot()).keys.filter(key=>key.startsWith('b/')),['b/unread-ended','b/peer']);peer.reverse();await refresh();
   peerStatus='offline';await refresh();await page.locator('#list-cleanup>summary').click();await page.locator('#clean-offline-macs').click();await page.waitForFunction(()=>!loadingNetwork&&!nodes.some(n=>n.id==='b'));await page.evaluate(()=>clearTimeout(networkTimer));assert.equal(await peerRow.count(),0);
   await page.locator('#restore-cleanup').click();await page.waitForFunction(()=>!loadingNetwork&&nodes.some(n=>n.id==='b'));await page.evaluate(()=>clearTimeout(networkTimer));assert.equal(await peerRow.count(),0);
   peerStatus='online';await refresh();assert.equal(await peerRow.count(),1);
   removed=true;await refresh();assert.equal(await peerRow.count(),0);
   await page.emulateMedia({colorScheme:'dark',reducedMotion:'reduce'});await capture(label+'-removed-dark');
  }
  assert.equal((await snapshot()).overflow,false);await page.close();
 }
 checks.push(baseline?'Reproduced session removal on failed reads and row movement on transport reordering at three viewports':'Failed, pending and 304 inventories preserve existing rows, focus and session order; saved ended records stay hidden');
 if(!baseline)checks.push('Offline rows show connection status and disable input/automation; a successful empty inventory, cleanup, restore and source removal follow current truth');
 assert.equal(requests.posts,0);assert.deepEqual(errors,[]);
 const report={passed:true,baseline,engine,checks,views,shifts,requests,errors,sourceSHA256:createHash('sha256').update(await readFile(assets+'/app.js')).digest('hex'),scope:'Synthetic inventories and exact product web assets. No real terminal input or system changes. Row shifts are relative to the session list, not the Mac header.'};
 await writeFile(path.join(out,engine+'-report.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}catch(error){await writeFile(path.join(out,engine+'-failure.json'),JSON.stringify({error:error.message,errors,checks,views,shifts,state:page?await snapshot().catch(()=>null):null},null,2)+'\n');throw error;}
finally{await browser?.close();server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
