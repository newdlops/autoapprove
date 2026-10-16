// Real browser and Core assets/SSE with synthetic inventories and injected delayed-list replies.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,writeFile,readFile} from 'node:fs/promises';
import {createServer,request as upstreamRequest} from 'node:http';
import path from 'node:path';
import {fixtureSuite,json,wait} from './terminal-continuity-fixture.mjs';
const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const out=path.resolve(option('output')||'dist/qa/dashboard-latency-browser'),baseline=process.argv.includes('--baseline-ui');
await mkdir(out,{recursive:true});const suite=await fixtureSuite(path.join(out,'fixture'));
const checks=[],metrics=[],errors=[],screenshots=[],policyViolations=[],nativeControlWarnings=[],frontends=[];
const nativeStyleWarning="Refused to apply a stylesheet because its hash, its nonce, or 'unsafe-inline' does not appear in the style-src directive of the Content Security Policy.";
const selectLines=new Set((await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/index.html','utf8')).split('\n').flatMap((line,index)=>line.includes('<select')?[index+1]:[]));
const oldScript=baseline?execFileSync('git',['show','v0.2.105:Sources/AutoApproveCore/Resources/RemoteWeb/app.js']):null;
try{
 const owner=await suite.start('owner'),state=(await json(owner.url+'/api/state')).value,original=state.sessions[0];
 for(const name of ['chromium','webkit']){
  const browser=await playwright[name].launch({headless:true,...(name==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
  try{
   const context=await browser.newContext({viewport:{width:390,height:844},colorScheme:'light'}),page=await context.newPage();page.setDefaultTimeout(10000);
   await page.addInitScript(()=>{
    window.dashboardPolicyViolations=[];
    document.addEventListener('securitypolicyviolation',event=>window.dashboardPolicyViolations.push({directive:event.effectiveDirective,source:event.sourceFile,line:event.lineNumber,column:event.columnNumber,blocked:event.blockedURI}));
   });
   const nativeWarnings=[];
   page.on('pageerror',e=>errors.push(name+': '+e.message));page.on('console',m=>{if(m.type()==='error'){
    if(name==='webkit'&&m.text()===nativeStyleWarning)nativeWarnings.push(m.text());else errors.push(name+': '+m.text());
   }});
   let mode='arrival',released=false,firstFull;const requests=[];
   const local={id:owner.id,name:'합성 원본 Mac',local:true,online:true,state:state,release:state.release};
   const later={...local,id:'synthetic-delayed',name:'늦게 응답한 Mac',local:false,state:{...state,id:'synthetic-delayed',sessions:Array.from({length:10},(_,i)=>({...original,title:'긴 프로젝트 이름 · 여러 Mac의 작업 상태 확인 '+i,canRead:false,session:{...original.session,id:'synthetic-delayed-'+i,terminalTitle:'긴 프로젝트 이름 '+i}}))}};
   const lateNode=()=>mode==='pending'||!released?{id:later.id,name:later.name,local:false,online:false,loading:true,release:state.release}:later;
   let frontendURL,writeAttempts=0;const sockets=new Set();
   const frontend=createServer((request,response)=>{
    const url=new URL(request.url,'http://fixture');
    if(url.pathname==='/native-control-csp'){
     const count=Number(url.searchParams.get('count'));
     response.writeHead(200,{'Content-Type':'text/html','Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self' 'nonce-native-control'"});
     response.end('<!doctype html><html><head><title>Native control</title></head><body>'+Array.from({length:count},()=>'<select><option>Native option</option></select>').join('\n')+'</body></html>');return;
    }
    if(url.pathname!=='/api/network'){
     if(request.method!=='GET'){writeAttempts++;response.writeHead(405);response.end();return;}
     if(oldScript&&url.pathname==='/app.js'){response.writeHead(200,{'Content-Type':'application/javascript','Content-Length':oldScript.length});response.end(oldScript);return;}
     const headers={...request.headers,host:new URL(owner.url).host};
     if(headers.origin){if(headers.origin!==new URL(frontendURL).origin){response.writeHead(403);response.end();return;}headers.origin=new URL(owner.url).origin;}
     const upstream=upstreamRequest(owner.url+request.url,{method:'GET',headers,agent:false},reply=>{
      response.useChunkedEncodingByDefault=false;response.writeHead(reply.statusCode,reply.headers);reply.on('error',()=>response.destroy());reply.pipe(response);
     });upstream.on('error',()=>response.destroy());response.on('close',()=>upstream.destroy());upstream.end();return;
    }
    const now=performance.now(),initial=url.searchParams.get('initial')==='1';
    if(!initial&&firstFull==null){firstFull=now;setTimeout(()=>{released=true;},100);}
    const partial=mode==='pending'||!released,tag=partial?'W/"partial-dashboard"':'W/"complete-dashboard"';
    const unchanged=!initial&&request.headers['if-none-match']===tag;
    requests.push({at:now,mode,initial,partial,status:unchanged?304:200});
    const headers={'Content-Type':'application/json','X-AutoApprove-Observed-At':new Date().toISOString(),ETag:tag};
    if(unchanged){response.writeHead(304,headers);response.end();return;}
    const body=Buffer.from(JSON.stringify({gatewayID:owner.id,nodes:[local,lateNode()],updatedAt:new Date().toISOString(),gatewayRelease:state.release,...(partial?{partial:true}:{})}));
    response.writeHead(200,{...headers,'Content-Length':body.length});response.end(body);
   });
   frontend.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});frontends.push({frontend,sockets});
   await new Promise(resolve=>frontend.listen(0,'127.0.0.1',resolve));frontendURL='http://127.0.0.1:'+frontend.address().port;
   async function validatePolicy(){
    const events=await page.evaluate(()=>window.dashboardPolicyViolations);policyViolations.push({browser:name,events});
    if(name!=='webkit'){assert.deepEqual(events,[]);return;}
    // This WebKit emits style-src-attr violations from native select internals.
    // Prove the same count in static HTML with no JS and the same strict policy.
    const control=await context.newPage();let count=0;
    control.on('console',m=>{if(m.type()==='error'){assert.equal(m.text(),nativeStyleWarning);count++;}});
    await control.goto(frontendURL+'/native-control-csp?count=0');await wait(50);assert.equal(count,0);
    await control.goto(frontendURL+'/native-control-csp?count=4');await wait(50);assert.ok(count===0||count===4);
    assert.equal(events.length,nativeWarnings.length);assert.ok(events.every(e=>e.directive==='style-src-attr'&&e.source===''&&e.blocked==='inline'&&selectLines.has(e.line)));
    assert.equal(new Set(events.map(e=>e.line)).size,count,'Only native select controls may produce the separately reproduced warnings');
    nativeControlWarnings.push({browser:name,appWarnings:nativeWarnings.length,staticSelectWarnings:count,uniqueSelectLocations:new Set(events.map(e=>e.line)).size,staticDocumentScripts:0});await control.close();
   }
   await page.goto(frontendURL);
   await page.waitForFunction(()=>Array.from(document.querySelectorAll('.machine')).some(row=>row.querySelector('.machine-name')?.textContent==='늦게 응답한 Mac'&&row.querySelector('.machine-status')?.textContent.includes('연결됨')));
   const readyMS=performance.now()-firstFull;metrics.push({browser:name,latePeerVisibleMS:readyMS});
   if(!baseline)assert.ok(readyMS<1500,'A later healthy Mac cannot wait for the ordinary 2.5-second poll');
   checks.push(name+': initial partial inventory completes without manual reload');
   if(baseline){await validatePolicy();await context.close();continue;}
   const escape=text=>text.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');
   await page.getByRole('button',{name:new RegExp(escape(original.title))}).first().click();
   await page.waitForFunction(()=>document.getElementById('terminal-screen').textContent.length>100);
   if(await page.locator('body').evaluate(e=>e.classList.contains('terminal-focus')))await page.locator('#terminal-focus').click();
   if(!await page.locator('#terminal-input').isVisible()){
    if(!await page.locator('#terminal-settings').evaluate(e=>e.open))await page.locator('#terminal-settings summary').click();
    await page.locator('#compose-input').check();
   }
   const input=page.locator('#terminal-input');await input.fill('아직 보내지 않은 합성 초안🙂');await input.press('ArrowLeft');
   mode='pending';const pendingStart=performance.now();await page.getByRole('button',{name:'상태 새로고침'}).click();await input.focus();
   const cursor=await input.evaluate(e=>e.selectionStart);
   await page.waitForFunction(()=>document.getElementById('connection').textContent.includes('갱신'));
   // 150/300/600/1200ms follow-ups then the normal cadence, including 304.
   while(requests.filter(r=>r.mode==='pending').length<6&&performance.now()-pendingStart<8500)await wait(50);
   const pending=requests.filter(r=>r.mode==='pending');assert.ok(pending.length>=6);assert.ok(pending.some(r=>r.status===304));
   const intervals=pending.slice(1).map((r,i)=>r.at-pending[i].at);assert.ok(intervals.at(-1)>2000,'Unchanged partial responses must leave the fast poll');
   assert.ok(pending.length<=8);assert.equal(await input.inputValue(),'아직 보내지 않은 합성 초안🙂');
   assert.equal(await input.evaluate(e=>document.activeElement===e&&e.selectionStart),cursor);assert.equal((await suite.observe(owner)).inputs.length,0);
   checks.push(name+': bounded partial/304 rechecks preserve selected terminal, draft, cursor and focus without input');
   metrics.push({browser:name,pendingRequests:pending.length,intervalsMS:intervals});
   for(const size of [{width:390,height:844},{width:768,height:1024},{width:1440,height:900}]){
    await page.setViewportSize(size);await page.evaluate(()=>window.scrollTo(0,0));
    if(!process.argv.includes('--no-screenshots')){const filename=name+'-'+size.width+'-pending-terminal.png';await page.screenshot({path:path.join(out,filename),fullPage:false});screenshots.push(filename);}
    assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false,'No viewport overflow');
   }
   mode='complete';await page.getByRole('button',{name:'상태 새로고침'}).click();
   await page.waitForFunction(()=>Array.from(document.querySelectorAll('.machine')).some(row=>row.querySelector('.machine-name')?.textContent==='늦게 응답한 Mac'&&row.querySelector('.machine-status')?.textContent.includes('연결됨')));
   assert.equal(await input.inputValue(),'아직 보내지 않은 합성 초안🙂');
   await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>true});document.dispatchEvent(new Event('visibilitychange'));});
   const hiddenCount=requests.length;await wait(500);assert.equal(requests.length,hiddenCount);
   await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,get:()=>false});document.dispatchEvent(new Event('visibilitychange'));});
   await page.waitForFunction(()=>document.getElementById('connection').textContent.includes('갱신'));
   checks.push(name+': dense delayed-list recovery and simulated hidden-page pause retain the original draft');
   assert.equal(writeAttempts,0);await validatePolicy();
   await context.close();
  }finally{await browser.close();}
 }
 const report={result:errors.length?'FAIL':'PASS',baseline,checks,metrics,screenshots,errors,policyViolations,nativeControlWarnings,scope:'Chromium/WebKit Core assets and synthetic original stream through a loopback test proxy with delayed inventory and real HTTP 304. Native WebKit select warnings verified separately without weakening CSP. No physical phone or real user input.'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');assert.deepEqual(errors,[]);console.log(JSON.stringify(report,null,2));
}finally{for(const {sockets}of frontends)for(const socket of sockets)socket.destroy();await Promise.all(frontends.map(({frontend})=>new Promise(resolve=>frontend.close(resolve))));await suite.stop();}
