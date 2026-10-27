// Production UI under controlled inventory failures; all Macs/data are synthetic.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import {mkdir,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3),engine=process.argv.includes('--webkit')?'webkit':'chromium',baseline=process.argv.includes('--baseline');
const out=path.resolve(option('output')||'.runtime/lan-reliability-199/browser-'+engine),web=path.resolve(option('web-root')||'Sources/AutoApproveCore/Resources/RemoteWeb');await mkdir(out,{recursive:true});
const release=JSON.parse(await readFile(web+'/web-version.json','utf8')),rows=[],held=new Set(),sockets=new Set(),faults=[],checks=[],errors=[];let mode='healthy',paused=false,writes=0;
const wait=ms=>new Promise(r=>setTimeout(r,ms));async function until(test,label,ms=5000){const end=Date.now()+ms;while(!await test()){assert.ok(Date.now()<end,label);await wait(10);}}
function inventory(){return {gatewayID:mode==='wrong-gateway'?'other':'gateway',gatewayRelease:release,updatedAt:new Date().toISOString(),terminalWireVersion:3,networkWaitVersion:1,nodes:['gateway','peer'].map((id,i)=>({id,name:'Synthetic Mac '+i,local:i===0,online:true,state:{id,name:'Synthetic Mac '+i,release,snapshot:{paused,events:[]},sessions:[],questionForms:[],screenShares:[]}}))};}
const server=createServer(async(req,res)=>{
 const u=new URL(req.url,'http://localhost');if(req.method!=='GET'){writes++;res.writeHead(405);res.end();return;}
 if(u.pathname==='/api/network'){
  const row={at:performance.now(),watch:!!req.headers.prefer,tag:req.headers['if-none-match'],initial:u.searchParams.get('initial')==='1',expected:req.headers['x-autoapprove-node']};rows.push(row);
  const send=()=>{
   if(res.destroyed)return;
   const json=(value,status=200)=>{const body=JSON.stringify(value);res.writeHead(status,{'Content-Type':'application/json','Content-Length':Buffer.byteLength(body),'Cache-Control':'no-store'});res.end(body);};
   if(row.watch&&['once-503','once-drop','identity','protocol','wrong-fresh'].includes(mode)){
    const fault=mode;faults.push({index:rows.indexOf(row),fault,at:performance.now()});paused=!paused;mode=fault==='wrong-fresh'?'wrong-gateway':'healthy';
    if(fault==='once-drop'){req.socket.destroy();return;}
    if(fault==='identity'){json({error:'Synthetic identity mismatch',diagnostics:{failureKind:'identity'}},502);return;}
    if(fault==='protocol'){res.writeHead(200,{'Content-Type':'application/json','Content-Length':1});res.end('{');return;}
    json({error:'Synthetic held read unavailable'},503);return;
   }
   if(row.watch&&mode==='stall-watch'){held.add(res);res.once('close',()=>held.delete(res));faults.push({index:rows.indexOf(row),fault:mode,at:performance.now()});paused=true;return;}
   if(mode==='outage'){json({error:'Synthetic gateway outage'},503);return;}
   const value=inventory(),tag='W/"'+createHash('sha256').update(JSON.stringify({...value,updatedAt:undefined})).digest('hex')+'"',same=row.tag===tag;
   row.status=same?304:200;res.writeHead(row.status,{'Content-Type':'application/json','Cache-Control':'no-store',ETag:tag,'X-AutoApprove-Observed-At':new Date().toISOString(),...(row.watch?{'Preference-Applied':'wait'}:{})});res.end(same?undefined:JSON.stringify(value));
  };
  if(row.watch){const timer=setTimeout(send,150);res.once('close',()=>clearTimeout(timer));}else send();return;
 }
 if(u.pathname.startsWith('/api/')){res.writeHead(200,{'Content-Type':'application/json'});res.end('{}');return;}
 const file=u.pathname==='/'?'index.html':u.pathname.slice(1),target=path.resolve(web,file);if(!target.startsWith(web+'/')){res.writeHead(404);res.end();return;}
 try{const body=await readFile(target);res.writeHead(200,{'Content-Type':file.endsWith('.html')?'text/html':file.endsWith('.css')?'text/css':file.endsWith('.json')?'application/json':'text/javascript'});res.end(body);}catch{res.writeHead(404);res.end();}
});
server.on('connection',s=>{sockets.add(s);s.once('close',()=>sockets.delete(s));});await new Promise(r=>server.listen(0,'127.0.0.1',r));let browser,page;
try{
 const pw=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await pw[engine].launch({headless:true,...(engine==='chromium'?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined}:{})});page=await browser.newPage({viewport:{width:390,height:844}});page.on('pageerror',e=>errors.push(e.message));
 await page.goto('http://127.0.0.1:'+server.address().port);await page.waitForFunction(()=>connected&&nodes.length===2);await until(()=>rows.some(r=>r.watch),'Established conditional wait');
 await page.evaluate(()=>{window.transitions=[];new MutationObserver(()=>transitions.push({connected,label:document.getElementById('connection').textContent,at:performance.now()})).observe(document.getElementById('connection'),{childList:true,subtree:true,characterData:true});});
 async function fresh(){mode='healthy';const before=rows.length;await page.evaluate(()=>{transitions.length=0;void refreshNetwork(false,true);});await until(()=>rows.slice(before).some(r=>r.watch),'Next held read');await page.waitForFunction(()=>connected&&nodes.length===2);}
 const old=paused;mode='once-503';await until(()=>faults.length>0,'Held read failed');await page.waitForFunction(p=>connected&&nodes[0].state.snapshot.paused!==p,old);let transitions=await page.evaluate(()=>window.transitions);
 if(baseline){assert.ok(transitions.some(s=>!s.connected),'Old UI must show false offline before the next healthy read');const report={baseline:true,reproduced:true,offlineTransitions:transitions.filter(s=>!s.connected).length,initialRecovery:rows.filter(r=>r.initial).length};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));}
 else{
  assert.equal(transitions.filter(s=>!s.connected).length,0);let after=rows[faults[0].index+1];assert.equal(after.watch,false);assert.equal(after.tag,undefined);checks.push('A failed held 503 confirms fresh controls with one unconditional finite read and no offline transition');
  await fresh();const before=faults.length,previous=paused;mode='once-drop';await until(()=>faults.length>before,'Dropped held TCP');await page.waitForFunction(p=>connected&&nodes[0].state.snapshot.paused!==p,previous);assert.ok((await page.evaluate(()=>transitions)).every(s=>s.connected));checks.push('A dropped held TCP read recovers without a false first-connection/partial inventory');
  for(const failure of ['identity','protocol']){
   await fresh();const start=faults.length;mode=failure;await until(()=>faults.length>start,failure+' injected');await page.waitForFunction(()=>!connected);const count=rows.length;await wait(250);assert.equal(rows.length,count,'No immediate confirmation retry for '+failure);checks.push(failure+' failure is surfaced without a transport retry');
  }
  await fresh();mode='wrong-fresh';const start=faults.length;await until(()=>faults.length>start,'Wrong gateway after transient failure');await page.waitForFunction(()=>!connected);assert.equal(await page.evaluate(()=>nodes[0].id),'gateway');assert.match(await page.locator('#network-error').textContent(),/Mac|주소/);checks.push('A finite confirmation from a different gateway cannot replace the pinned Mac');
  await fresh();mode='outage';await page.getByRole('button',{name:'상태 새로고침'}).click();await page.waitForFunction(()=>!connected);const count=rows.length;await wait(1250);assert.ok(rows.length-count<=2);checks.push('A failed confirmation reports an actual outage and subsequent attempts keep bounded backoff');
  await fresh();const countBefore=rows.length;await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true});document.dispatchEvent(new Event('visibilitychange'));});await wait(300);assert.equal(rows.length,countBefore);mode='healthy';await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));});await page.waitForFunction(()=>connected);checks.push('Background cancellation does not start a hidden confirmation or duplicate read');
  paused=false;await fresh();await page.waitForFunction(()=>nodes[0].state.snapshot.paused===false);const began=performance.now();mode='stall-watch';await until(()=>held.size>0,'A real wait is silent');await page.waitForFunction(()=>nodes[0].state.snapshot.paused===true,null,{timeout:21000});const elapsed=performance.now()-began;assert.ok(elapsed>=17000&&elapsed<20500);mode='healthy';assert.ok((await page.evaluate(()=>transitions)).every(s=>s.connected));checks.push('A silent held read reserves finite confirmation time inside the existing 20-second budget ('+Math.round(elapsed)+'ms)');
  for(const[name,width,height]of [['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});await page.screenshot({path:out+'/'+name+'.png'});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);}
  assert.equal(writes,0);assert.deepEqual(errors,[]);const report={passed:true,engine,checks,writes,errors,scope:'Exact production UI and controlled HTTP/TCP failures; synthetic Macs, no user terminal or mutations'};await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
 }
}catch(error){await page?.screenshot({path:out+'/failure.png'}).catch(()=>{});await writeFile(out+'/failure.json',JSON.stringify({error:error.message,checks,errors,rows,faults},null,2));throw error;}
finally{await browser?.close();for(const s of sockets)s.destroy();await new Promise(r=>server.close(r));}
