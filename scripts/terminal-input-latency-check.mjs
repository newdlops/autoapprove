// Real browser keyboard -> production Swift HTTP -> authoritative editing
// adapter or actual private PTY -> browser text/cursor render opportunity.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=name=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/release'),out=path.resolve(option('output')||'dist/qa/terminal-input-latency');
const browserName=process.argv.includes('--webkit')?'webkit':'chromium';
const inputRoute=/\/api\/pty\/input(?:\?.*)?$/;
const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const summary=values=>{const sorted=values.toSorted((a,b)=>a-b);return {min:sorted[0],median:sorted[Math.floor(sorted.length/2)],p95:sorted[Math.ceil(sorted.length*.95)-1],max:sorted.at(-1)};};
await mkdir(out,{recursive:true});
const root=await mkdtemp('/private/tmp/aa-input-latency-'),binary=path.join(root,'InputLatency');
const cache=path.resolve('.build/cache/InputLatency');await mkdir(cache,{recursive:true});
let browser,fixture,page,stage='startup';const descriptors=[],reports=[],errors=[];
try {
  const objects=(await readdir(build+'/AutoApproveCore.build')).filter(v=>v.endsWith('.swift.o')).map(v=>build+'/AutoApproveCore.build/'+v);
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/terminal-input-latency.swift','-o',binary],{stdio:'inherit',timeout:300000});
  browser=await playwright[browserName].launch({headless:true,...(browserName==='chromium'?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined}:{})});
  const variants=option('baseline')?[{name:'baseline',ref:option('baseline')},{name:'candidate'}]:[{name:'candidate'}];
  for(const variant of variants){
    const directory=path.join(root,variant.name);await mkdir(directory);
    await writeFile(directory+'/.zshrc',"PROMPT='QA> '\n");
    execFileSync('/usr/bin/cc',['Tests/fixtures/pty-agent.c','-o',directory+'/codex']);
    execFileSync('/usr/bin/cc',['Tests/fixtures/terminal-input-echo.c','-o',directory+'/byte-echo']);
    fixture=spawn(binary,[directory],{stdio:['ignore','pipe','pipe']});let stderr='';fixture.stderr.on('data',data=>stderr+=data);
    const base=await new Promise((resolve,reject)=>{let text='';const timer=setTimeout(()=>reject(Error('Latency fixture startup: '+stderr)),20000);fixture.stdout.on('data',data=>{text+=data;for(const line of text.split('\n'))try{const info=JSON.parse(line);if(info.url){clearTimeout(timer);resolve(info.url);}}catch{}});fixture.once('exit',code=>{clearTimeout(timer);reject(Error('Fixture exited '+code+': '+stderr));});});
    stage=variant.name+' original';page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(15000);
    page.on('pageerror',error=>errors.push(error.message));
    for(const file of ['app.js','pty.js']){
      const body=variant.ref?execFileSync('git',['show',variant.ref+':Sources/AutoApproveCore/Resources/RemoteWeb/'+file],{encoding:'utf8'}):await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/'+file,'utf8');
      await page.route('**/'+file,route=>route.fulfill({contentType:'text/javascript',body}));
    }
    await page.goto(base);await page.locator('.session-row').first().click();
    await page.waitForFunction(()=>latestFrame?.streamID&&!$('terminal-keyboard').disabled);
    await page.locator('#terminal-screen').click();
    await page.evaluate(()=>{
      window.qaFetches=[];window.qaSamples=[];window.qaPending=null;window.qaRendered=0;
      const originalFetch=window.fetch;
      window.fetch=function(url,options){
        const pathname=new URL(url,location.href).pathname;
        if(['/api/input','/api/pty/input'].includes(pathname)){
          qaFetches.push({path:pathname,at:performance.now(),body:JSON.parse(options.body),bytes:new TextEncoder().encode(options.body).length});
          if(qaPending?.started!=null&&qaPending.dispatched==null)qaPending.dispatched=performance.now();
        }
        return originalFetch.call(this,url,options);
      };
      const start=()=>{if(qaPending&&qaPending.started==null){qaPending.started=performance.now();qaPending.renderBefore=qaRendered;}};
      document.addEventListener('keydown',start,true);document.addEventListener('beforeinput',start,true);
      window.qaText=()=>{
        if(!ptyClient)return $('terminal-screen').textContent;
        const buffer=ptyClient.term.buffer.active;return Array.from({length:buffer.length},(_,i)=>buffer.getLine(i)?.translateToString(true)||'').join('\n');
      };
      const observe=()=>{
        const pending=qaPending;
        if(pending?.started!=null){
          const correct=qaText().includes(pending.text);
          const cursor=ptyClient?qaRendered>pending.renderBefore&&ptyClient.term.buffer.active.cursorX===pending.column:
            !$('terminal-cursor').hidden&&Number($('terminal-cursor').dataset.offset)===pending.column&&latestFrame?.cursor?.offset===pending.column;
          if(correct&&cursor&&pending.dispatched!=null){
            // Force style/layout resolution, then record this browser animation
            // frame. Physical display/OS compositor timing is outside this test.
            (ptyClient?ptyClient.term.element:$('terminal-cursor')).getBoundingClientRect();
            qaSamples.push({kind:pending.kind,dispatch:pending.dispatched-pending.started,render:performance.now()-pending.started});qaPending=null;
          }
        }
        requestAnimationFrame(observe);
      };requestAnimationFrame(observe);
    });
    const binding=await page.evaluate(()=>({session:latestFrame.sessionID,stream:latestFrame.streamID,pid:selectedItem.session.pid,tty:selectedItem.session.tty}));
    let originalText=await page.locator('#terminal-screen').textContent();
    async function sample(kind,value,text,column){
      const count=await page.evaluate(()=>qaSamples.length);
      await page.evaluate(pending=>{qaPending=pending;},{kind,text,column});
      if(kind==='text')await page.keyboard.insertText(value);else await page.keyboard.press(value);
      await page.waitForFunction(count=>qaSamples.length>count,count);
      await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length&&!ptyClient?.sending&&!ptyClient?.queue.length);
    }
    for(let i=0;i<12;i++){const value=String.fromCharCode(97+i);originalText+=value;await sample('text',value,originalText,originalText.length);}
    for(let i=0;i<6;i++)await sample('cursor','ArrowLeft',originalText,originalText.length-i-1);
    for(let i=0;i<6;i++)await sample('cursor','ArrowRight',originalText,originalText.length-5+i);
    const originalSamples=await page.evaluate(()=>qaSamples.splice(0));
    // Continuous keyboard events must dispatch before typing ends. Measure both
    // versions, assert the bounded leading window only for the candidate.
    const before=await page.evaluate(()=>({at:performance.now(),requests:qaFetches.length}));
    const continuous='CONTINUOUS012345678901234567890123456789';
    await page.keyboard.type(continuous,{delay:3});const typingEnded=await page.evaluate(()=>performance.now());
    originalText+=continuous;
    await page.waitForFunction(value=>$('terminal-screen').textContent===value&&!directQueue.length&&!directSending,originalText);
    const continued=await page.evaluate(({at,requests,typingEnded})=>({firstDispatch:qaFetches[requests].at-at,typingDuration:typingEnded-at,requests:qaFetches.length-requests}),{...before,typingEnded});
    if(!variant.ref)assert.ok(continued.firstDispatch<continued.typingDuration,'Continuous typing must not postpone the first POST until idle');
    // IME is committed once; intermediate composition stays local and keeps the
    // native insertion point. These are DOM composition events, not physical IME.
    const imeBefore=await page.evaluate(()=>qaFetches.length);
    await page.evaluate(()=>{const input=$('terminal-keyboard');input.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true,data:''}));input.value=keyboardMarker+'하';input.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertCompositionText',data:'하',isComposing:true}));});
    await page.waitForTimeout(100);assert.equal(await page.evaluate(()=>qaFetches.length),imeBefore);
    await page.evaluate(()=>{const input=$('terminal-keyboard');input.value=keyboardMarker+'한글😀';input.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:'한글😀'}));input.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:'한글😀'}));});
    originalText+='한글😀';await page.waitForFunction(value=>$('terminal-screen').textContent===value&&!directQueue.length&&!directSending,originalText);
    const inputs=JSON.parse(await readFile(directory+'/inputs.json','utf8')).inputs;
    assert.equal(inputs.join(''),'abcdefghijkl'+'\x1b[D'.repeat(6)+'\x1b[C'.repeat(6)+continuous+'한글😀');
    assert.deepEqual(await page.evaluate(()=>({session:latestFrame.sessionID,stream:latestFrame.streamID,pid:selectedItem.session.pid,tty:selectedItem.session.tty})),binding);
    for(const [size,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
      await page.setViewportSize({width,height});await page.waitForTimeout(100);
      assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
      assert.equal(await page.locator('#terminal-cursor').isVisible(),true);
      await page.screenshot({path:path.join(out,variant.name+'-original-'+size+'.png')});
    }
    // Real zsh line editing verifies authoritative cursor and UTF-8 input. A
    // private PTY is created only by the explicit New PTY UI action.
    stage=variant.name+' PTY';await page.locator('#terminal-back').click();
    await page.locator('#new-pty').click();await page.locator('#pty-directory').fill(directory);await page.locator('#pty-program').selectOption('shell');
    await page.locator('#pty-automatic').uncheck();await page.locator('#start-pty').click();await page.waitForFunction(()=>ptyClient?.ready);
    const descriptor=await page.evaluate(()=>ptyClient.descriptor);descriptors.push({base,descriptor});
    await page.evaluate(()=>{ptyClient.term.onRender(()=>qaRendered++);});
    await page.locator('#terminal-keyboard-toggle').click();
    await page.waitForFunction(()=>qaText().includes('QA> '));
    const prefix=await page.evaluate(()=>ptyClient.term.buffer.active.cursorX);let line='';
    for(let i=0;i<12;i++){const value=String.fromCharCode(97+i);line+=value;await sample('text',value,'QA> '+line,prefix+line.length);}
    for(let i=0;i<6;i++)await sample('cursor','ArrowLeft','QA> '+line,prefix+line.length-i-1);
    for(let i=0;i<6;i++)await sample('cursor','ArrowRight','QA> '+line,prefix+line.length-5+i);
    const ptySamples=await page.evaluate(()=>qaSamples.splice(0));
    await page.keyboard.press('Control+c');await page.waitForFunction(()=>!ptyClient.sending&&!ptyClient.queue.length);
    // Delay only the acknowledgement of the first genuine input. Subsequent
    // unsent xterm bytes must coalesce, in order, into bounded serial requests.
    stage=variant.name+' delayed ACK';let delayed=true;const routed=[];
    await page.route(inputRoute,async route=>{
      try{const response=await route.fetch();if(delayed){delayed=false;await wait(120);}await route.fulfill({response});}
      catch(error){if(!page.isClosed())routed.push(error.message);}
    });
    const burstBefore=await page.evaluate(()=>qaFetches.length);
    await page.keyboard.insertText('p');await page.waitForFunction(before=>qaFetches.length>before,burstBefore);
    await page.keyboard.type("rintf 'BATCH=한글😀\\n'",{delay:0});await page.keyboard.press('Enter');
    await page.waitForFunction(()=>/\nBATCH=한글😀[ \t]*(?:\n|$)/.test(qaText())&&!ptyClient.sending&&!ptyClient.queue.length);
    await page.waitForTimeout(150);assert.deepEqual(routed,[]);await page.unroute(inputRoute);
    assert.equal(delayed,false,'The delayed acknowledgement must actually be intercepted');
    const burst=await page.evaluate(before=>qaFetches.slice(before).filter(value=>value.path==='/api/pty/input'),burstBefore);
    const delivered=Buffer.concat(burst.map(value=>Buffer.from(value.body.data,'base64'))).toString();
    assert.equal(delivered,"printf 'BATCH=한글😀\\n'\r");
    assert.ok(burst.every(value=>Buffer.from(value.body.data,'base64').length<=16000));
    if(!variant.ref)assert.ok(burst.length<=4,'In-flight bytes should coalesce rather than create one POST per key');
    // Cross the 16KB boundary inside multi-byte Unicode. Compare all bytes
    // recorded by the actual native process, not just request reconstruction.
    stage=variant.name+' large UTF-8';
    const quoted=value=>"'"+value.replaceAll("'","'\\''")+"'";
    await page.keyboard.insertText('exec '+quoted(directory+'/byte-echo')+' '+quoted(directory+'/bytes.bin'));
    await page.keyboard.press('Enter');await page.waitForFunction(()=>qaText().includes('BYTE-ECHO-READY'));
    await page.waitForFunction(()=>!ptyClient.sending&&!ptyClient.queue.length);
    const large='abc'+'한😀x'.repeat(7000),largeBefore=await page.evaluate(()=>qaFetches.length);
    await page.keyboard.insertText(large);await page.waitForFunction(()=>!ptyClient.sending&&!ptyClient.queue.length);
    const deadline=performance.now()+15000;let recorded;
    do{recorded=await readFile(directory+'/bytes.bin');if(recorded.length>=Buffer.byteLength(large))break;await wait(20);}while(performance.now()<deadline);
    assert.ok(recorded.equals(Buffer.from(large)),`Native PTY must receive UTF-8 in order, once (${recorded.length}/${Buffer.byteLength(large)} bytes)`);
    const largeRequests=await page.evaluate(before=>qaFetches.slice(before),largeBefore);
    assert.ok(largeRequests.every(value=>Buffer.from(value.body.data,'base64').length<=16000));
    // Ambiguous POST: the native writer accepted it, but the browser loses its
    // receipt. Retain only unsent input and never resend the uncertain bytes.
    stage=variant.name+' ambiguous ACK';let drop=true,releaseAmbiguous;
    await page.route(inputRoute,async route=>{
      try{if(drop){drop=false;const response=await route.fetch();assert.equal(response.status(),200);await new Promise(resolve=>{releaseAmbiguous=resolve;});await route.abort('connectionreset');}else await route.continue();}
      catch(error){if(!page.isClosed())routed.push(error.message);}
    });
    const ambiguousBefore=await page.evaluate(()=>qaFetches.length);
    await page.keyboard.insertText('UNCERTAIN');const acceptedDeadline=performance.now()+10000;
    while(!releaseAmbiguous&&performance.now()<acceptedDeadline)await wait(10);
    assert.ok(releaseAmbiguous,'The native write must succeed before its receipt is lost');
    await page.keyboard.insertText('PRESERVE');await page.waitForFunction(()=>ptyClient.queue.reduce((sum,bytes)=>sum+bytes.length,0)===8);
    releaseAmbiguous();await page.waitForFunction(()=>ptyClient.blocked);
    await page.waitForTimeout(300);assert.equal(await page.evaluate(before=>qaFetches.length-before,ambiguousBefore),1);
    assert.equal(await page.evaluate(()=>ptyClient.unsent),'PRESERVE');
    assert.equal((await readFile(directory+'/bytes.bin')).toString(),large+'UNCERTAIN','Accepted ambiguous bytes must reach the native process exactly once; queued bytes stay unsent');
    assert.equal(drop,false,'The ambiguous acknowledgement must actually be intercepted');
    await page.unroute(inputRoute);
    const group=samples=>Object.fromEntries(['text','cursor'].map(kind=>[kind,{count:samples.filter(v=>v.kind===kind).length,dispatchMS:summary(samples.filter(v=>v.kind===kind).map(v=>v.dispatch)),renderMS:summary(samples.filter(v=>v.kind===kind).map(v=>v.render))}]));
    reports.push({variant:variant.name,original:group(originalSamples),pty:group(ptySamples),continuous:continued,delayedAck:{requests:burst.length,bodyBytes:burst.reduce((sum,v)=>sum+v.bytes,0)},largeUTF8:{bytes:recorded.length,requests:largeRequests.length},checks:['single original delivery and exact PID/TTY/stream','continuous typing dispatch','authoritative cursor arrows','IME intermediate bytes stay local and commit once','real zsh editing','bounded serial coalescing after delayed ACK','56,003 native UTF-8 bytes including split codepoints across 16KB boundaries','ambiguous accepted POST is never replayed; queued bytes preserved'],originalSamples,ptySamples});
    await writeFile(out+'/'+variant.name+'-report.json',JSON.stringify(reports.at(-1),null,2)+'\n');
    const closed=await fetch(base+'/api/pty/close',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({requestID:crypto.randomUUID(),ptyID:descriptor.ptyID,streamID:descriptor.streamID})});assert.equal(closed.status,200);descriptors.pop();
    await page.close();fixture.kill();await new Promise(resolve=>fixture.once('exit',resolve));fixture=null;
  }
  assert.deepEqual(errors,[]);const report={result:'PASS',browser:browserName,reports,errors,scope:'Loopback production Core with synthetic original editing and actual private zsh PTY; browser animation-frame readiness, not physical display/phone/network latency.'};
  await writeFile(out+'/report.json',JSON.stringify(report,null,2)+'\n');
  await Promise.all(['failure.json','failure.png'].map(name=>rm(out+'/'+name,{force:true})));console.log(JSON.stringify(report));
}catch(error){
  await page?.screenshot({path:out+'/failure.png'}).catch(()=>{});
  const state=await page?.evaluate(()=>({directMode,inputFailure,queue:directQueue.length,frame:latestFrame?.screen?.slice(-1000),pty:ptyClient&&{ready:ptyClient.ready,error:ptyClient.error,queue:ptyClient.queue.length,sending:ptyClient.sending},samples:window.qaSamples,pending:window.qaPending})).catch(()=>null);
  await writeFile(out+'/failure.json',JSON.stringify({stage,error:error.message,state},null,2));throw error;
}finally{
  for(const {base,descriptor}of descriptors)await fetch(base+'/api/pty/close',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({requestID:crypto.randomUUID(),ptyID:descriptor.ptyID,streamID:descriptor.streamID})}).catch(()=>{});
  await browser?.close();if(fixture&&fixture.exitCode===null){fixture.kill();await new Promise(resolve=>fixture.once('exit',resolve));}
  await rm(root,{recursive:true,force:true});
}
