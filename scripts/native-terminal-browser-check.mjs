// Real Chromium + synthetic original-window JPEG/SSE fixture. No Mac window or user's CLI is touched.
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdir, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
const {chromium} = await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE || 'playwright');
const output = path.resolve('dist/qa/native-terminal'); await mkdir(output, {recursive:true});
const allKeys = ['text','submit','characters','enter','escape','interrupt','up','down','left','right','backspace','delete','home','end','tab'];
const original = {id:'original-terminal',agent:'codex',pid:4200,started:'unchanged-original-start',tty:'/dev/fixture-original',cwd:'/fixture/original-terminal',terminal:'terminal',hostName:'Terminal.app',phase:'idle',automatic:true,detail:'같은 Mac의 원본 터미널',queuedQuestions:[]};
let nativeDisplay = {state:'permissionRequired',message:'Mac에서 화면 기록 권한을 허용해주세요.'};
let activeKeys = allKeys, revision = 0, online = true, images, page, browser, outputReason, stage = 'selection';
const clients = new Map(), operations = [], requests = {pty:0,connect:0,stream:0,poll:0,screen:0,terminal:0,connectViews:[]};
const checks = [], screenshots = [], errors = [], externalImages = [];
const network = () => ({updatedAt:new Date().toISOString(),nodes:[{id:'native-mac',name:'원래 Mac',local:true,online,state:{release:{version:'0.2.43',build:53,api:1},snapshot:{paused:false,events:[]},sessions:[{session:original,title:'원본 '+original.hostName,phaseTitle:'입력 대기',canRead:true,canApprove:true,canReveal:true,keys:activeKeys}]}}]});
function frame(full=true, screen=false) {
  const display = screen && nativeDisplay ? {...nativeDisplay} : undefined; if (display && !full) delete display.image;
  return {sessionID:original.id,revision:String(revision),streamID:'unchanged-original-stream',observedAt:new Date().toISOString(),keys:activeKeys,outputReason,inputReason:activeKeys.length?undefined:nativeDisplay?.message,nativeDisplay:display,...(full ? {screen:'접근 가능한 원본 텍스트\nSAME PID / TTY\nREADY> ',cursor:{offset:0,padding:0,visible:true,style:'bar',blink:false}} : {})};
}
function push(full=true) {for (const [client,screen] of clients) client.write('event: screen\ndata: ' + JSON.stringify(frame(full,screen)) + '\n\n');}
function change(display, keys=allKeys, full=true) {nativeDisplay=display;activeKeys=keys;if(full)revision++;push(full);}
const server = createServer(async (req,res) => {
  const url = new URL(req.url,'http://localhost');
  const json = (status,value) => {res.writeHead(status,{'Content-Type':'application/json','Cache-Control':'no-store'});res.end(JSON.stringify(value));};
  try {
    if (url.pathname === '/api/network') return json(200,network());
    if (url.pathname === '/api/pty') {requests.pty++;return json(409,{error:'원본 선택에서 CLI를 만들면 안 됩니다.'});}
    if (url.pathname === '/api/terminal/stream') {
      requests.stream++;assert.equal(url.searchParams.get('node'),'native-mac');assert.equal(url.searchParams.get('session'),original.id);
      const screen=url.searchParams.get('view')==='screen';requests[screen?'screen':'terminal']++;
      res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-store','Connection':'keep-alive'});res.flushHeaders();clients.set(res,screen);push();
      const timer=setInterval(()=>push(false),2000);res.on('close',()=>{clearInterval(timer);clients.delete(res);});return;
    }
    if (url.pathname === '/api/terminal') {requests.poll++;return json(200,frame(true,url.searchParams.get('view')==='screen'));}
    if (url.pathname === '/api/terminal/connect' || url.pathname === '/api/input') {
      let raw='';for await(const part of req)raw+=part;const input=JSON.parse(raw);
      assert.equal(url.searchParams.get('node'),'native-mac');assert.equal(input.sessionID,original.id);assert.match(input.requestID,/^[\da-f-]{36}$/i);
      if (url.pathname.endsWith('/connect')) {requests.connect++;requests.connectViews.push(input.view||'terminal');change({state:'live',message:'Mac의 원본 '+original.hostName+' 화면',image:images.a});return json(200,frame(false,input.view==='screen'));}
      assert.ok(activeKeys.includes(input.kind));
      if(['text','submit'].includes(input.kind)){assert.equal(input.relay,undefined);assert.equal(input.revision,String(revision));}
      else {assert.equal(input.streamID,'unchanged-original-stream');assert.equal(input.relay,true);}operations.push(input);
      change(nativeDisplay ? {state:'live',message:'Mac의 원본 '+original.hostName+' 화면',image:operations.length%2?images.b:images.a} : undefined);return json(200,{message:'원본 터미널에 전달했습니다.'});
    }
    if(url.pathname === '/api/action')return json(200,{message:'변경했습니다.'});
    const name=url.pathname==='/'?'index.html':url.pathname.slice(1);
    if(!['index.html','app.js','app.css','pty.js','vendor/xterm.js','vendor/xterm-fit.js','vendor/xterm.css','favicon.svg'].includes(name))return json(404,{error:'not found'});
    let file=await readFile(path.join('Sources/AutoApproveCore/Resources/RemoteWeb',name));if(name==='index.html')file=file.toString().replaceAll('__AUTOAPPROVE_STYLE_NONCE__','nativefixture50');
    res.writeHead(200,{'Content-Type':name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':name.endsWith('.svg')?'image/svg+xml':'text/javascript','Content-Security-Policy':"default-src 'self'; script-src 'self'; style-src 'self' 'nonce-nativefixture50'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"});res.end(file);
  }catch(error){json(500,{error:error.message});}
});
try {
  browser=await chromium.launch({headless:true,executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined});
  page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true});page.setDefaultTimeout(30000);page.setDefaultNavigationTimeout(60000);
  images=await page.evaluate(()=>{
    const make=label=>{const canvas=document.createElement('canvas');canvas.width=1024;canvas.height=640;const c=canvas.getContext('2d');
      c.fillStyle='#161a22';c.fillRect(0,0,1024,640);c.fillStyle='#353a45';c.fillRect(0,0,1024,46);c.fillStyle='#efefef';c.font='18px monospace';c.fillText('Terminal.app · SYNTHETIC TEST WINDOW · same PID / TTY',24,30);
      c.fillStyle='#ff2345';c.fillRect(40,120,180,60);c.fillStyle='#42d46a';c.fillRect(250,120,180,60);c.fillStyle='#3b82f8';c.fillRect(460,120,180,60);
      c.fillStyle='#8cddff';c.font='28px monospace';c.fillText('ORIGINAL TERMINAL  '+label,32,92);c.fillStyle='#edeeee';c.fillText('codex > same-running-process',32,240);c.fillText('Actual window colors and cursor pixels',32,290);c.fillStyle='#f7ca57';c.fillRect(32,320,14,30);
      return {data:canvas.toDataURL('image/jpeg',.86).split(',')[1],width:1024,height:640};};
    const a=make('A'),b=make('B');const large=document.createElement('canvas');large.width=2048;large.height=2048;const c=large.getContext('2d');c.fillStyle='#161a22';c.fillRect(0,0,2048,2048);c.fillStyle='#edeeee';c.font='32px monospace';for(let row=0;row<48;row++)c.fillText('LARGE ORIGINAL WINDOW · '+row,24,60+row*40);
    return {a,b,large:{data:large.toDataURL('image/jpeg',.86).split(',')[1],width:2048,height:2048}};
  });
  page.on('pageerror',error=>errors.push(error.message));page.on('console',message=>{if(message.type()==='error')errors.push(message.text());});page.on('request',request=>{if(request.resourceType()==='image'&&!request.url().startsWith('data:')&&!request.url().includes('/favicon.svg'))externalImages.push(request.url());});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));const url='http://127.0.0.1:'+server.address().port;
  async function loaded(){await page.waitForFunction(()=>latestFrame?.sessionID==='original-terminal');}
  async function live(){await page.waitForFunction(()=>latestFrame?.nativeDisplay?.state==='live'&&$('native-image').complete&&$('native-image').naturalWidth===1024);}
  async function capture(name){await page.locator('#feedback').waitFor({state:'hidden',timeout:15000});await page.screenshot({path:path.join(output,name+'.png')});screenshots.push(name);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);}
  await page.goto(url);console.log('Native browser fixture loaded.');await page.locator('.session-row').click();await loaded();console.log('Original permission frame selected.');
  assert.equal(await page.locator('#input-editor').isVisible(),false,'Default original terminal has no forced compose textbox');
  assert.equal(requests.connect,0,'Selecting must not ask for Mac permissions or activate its tab');assert.equal(requests.pty,0);assert.equal(requests.screen,0);assert.equal(await page.locator('#native-view').isChecked(),false);assert.equal(await page.locator('#terminal-screen').isVisible(),true);assert.equal(await page.locator('#native-screen').isVisible(),false);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),false);assert.equal(await page.evaluate(()=>latestFrame.nativeDisplay),undefined);
  await page.locator('#terminal-screen').click();await page.keyboard.type('SSH');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.equal(operations.map(input=>input.text).join(''),'SSH');assert.equal(requests.screen,0);await capture('mobile-default-terminal');
  checks.push('default SSH-style terminal and original direct input require no image, screen permission or screen requests');
  stage='original-input-setup';change(undefined,['text','submit','enter']);
  await page.waitForFunction(()=>inputKeys().includes('submit')&&!inputKeys().includes('characters'));
  assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),true);
  assert.match(await page.locator('#direct-input-help').innerText(),/직접 입력 연결/);
  assert.match(await page.locator('#direct-input-help').innerText(),/관리자/);
  assert.doesNotMatch(await page.locator('#direct-input-help').innerText(),/손쉬운/);
  assert.equal(requests.connect,0);assert.equal(requests.screen,0);assert.equal(requests.pty,0);
  await capture('mobile-input-setup');change(undefined);await loaded();
  checks.push('missing original TTY service shows Mac administrator setup without Accessibility prompts, images or PTY creation');
  operations.length=0;nativeDisplay={state:'permissionRequired',message:'Mac에서 화면 녹음 권한을 허용해주세요.'};
  async function preview(enabled){await page.locator('#terminal-settings summary').click();await page.locator('#native-view').setChecked(enabled);}
  await preview(true);await page.waitForFunction(()=>latestFrame?.nativeDisplay?.state==='permissionRequired');assert.equal(await page.locator('#input-editor').isVisible(),false);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),false);assert.equal(requests.connect,0);await capture('mobile-permission');
  checks.push('only explicit Mac window view starts screen delivery; missing screen permission leaves original direct input usable');
  await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').check();assert.equal(await page.locator('#input-editor').isVisible(),true);await page.locator('#terminal-input').fill('manual draft');await page.locator('#terminal-input').fill('');await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').uncheck();assert.equal(await page.locator('#input-editor').isVisible(),false);
  checks.push('compose remains optional and deliberately selected when native direct input is unavailable');
  await page.locator('#native-connect').click();await live();assert.equal(requests.connect,1);assert.equal(requests.pty,0);assert.equal(await page.locator('#terminal-cursor').isVisible(),false);assert.equal(await page.locator('#input-editor').isVisible(),false);
  const identity=await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty,count:allSessions.length}));assert.deepEqual(identity,{id:original.id,pid:4200,tty:original.tty,count:1});
  const rgb=await page.evaluate(()=>{const image=$('native-image'),c=document.createElement('canvas');c.width=image.naturalWidth;c.height=image.naturalHeight;const context=c.getContext('2d');context.drawImage(image,0,0);return [...context.getImageData(80,150,1,1).data].slice(0,3);});assert.ok(rgb[0]>220&&rgb[1]<65&&rgb[2]<110);
  const firstSrc=await page.locator('#native-image').getAttribute('src');nativeDisplay={...nativeDisplay,message:'색상·커서가 포함된 Mac의 실제 창 화면'};push(false);await page.waitForFunction(()=>latestFrame?.nativeDisplay?.message.includes('색상'));assert.equal(await page.locator('#native-image').getAttribute('src'),firstSrc);
  change({state:'live',message:'Mac에서 변경한 같은 화면',image:images.b});await page.waitForFunction(data=>$('native-image').getAttribute('src')==='data:image/jpeg;base64,'+data,images.b.data);
  const screenBeforeReload=requests.screen;await page.reload();await loaded();assert.equal(await page.locator('#native-view').isChecked(),false);assert.equal(await page.locator('#native-screen').isVisible(),false);assert.equal(requests.screen,screenBeforeReload);assert.equal(await page.evaluate(()=>latestFrame.streamID),'unchanged-original-stream');await preview(true);await live();assert.equal(requests.connect,1);assert.equal(requests.pty,0);assert.deepEqual(await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty,count:allSessions.length})),identity);
  checks.push('real JPEG colors/cursor pixels render, compact frames retain image, pushes and reload preserve original PID/TTY');
  stage='direct-input';await page.locator('#native-screen').click();await page.keyboard.type('SAME');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.equal(operations.map(input=>input.text).join(''),'SAME');assert.ok(operations.every(input=>input.sessionID===original.id&&input.kind==='characters'&&input.relay===true));
  const beforeArrow=operations.length;await page.keyboard.press('ArrowLeft');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.deepEqual(operations.slice(beforeArrow).map(input=>[input.sessionID,input.kind]),[[original.id,'left']]);assert.equal(await page.locator('#automatic').isChecked(),true);
  checks.push('image tap and arrows use existing original relay while automatic approval stays ON');
  await page.locator('#native-zoom-in').click();assert.ok(await page.evaluate(()=>$('native-screen').scrollWidth>$('native-screen').clientWidth));await page.locator('#native-screen').evaluate(element=>{element.scrollLeft=120;});assert.ok(await page.locator('#native-screen').evaluate(element=>element.scrollLeft>0));await page.locator('#native-fit').click();assert.equal(await page.locator('#native-screen').evaluate(element=>element.scrollLeft),0);
  const beforeOff=requests.screen;await preview(false);await page.waitForFunction(()=>latestFrame&&!latestFrame.nativeDisplay);assert.equal(await page.locator('#native-screen').isVisible(),false);assert.equal(await page.locator('#native-image').getAttribute('src'),null);await page.locator('#terminal-screen').click();await page.keyboard.type('OFF');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.equal(requests.screen,beforeOff);assert.equal(await page.evaluate(()=>latestFrame.streamID),'unchanged-original-stream');await preview(true);await live();
  checks.push('fit/zoom/pan is contained; view OFF stops image requests and keeps the same original input and stream');
  for(const [name,width,height]of[['mobile',390,844],['mobile-keyboard',390,500],['tablet',768,1024],['desktop',1440,900]]){
    stage=name;await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);await page.setViewportSize({width,height});await page.evaluate(enabled=>terminalFocus(enabled),width<760);await page.waitForTimeout(150);
    const before=operations.length;await page.locator('#native-screen').click();await page.keyboard.type('V'+name);await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);await live();assert.ok(operations.slice(before).every(input=>input.sessionID===original.id&&input.kind==='characters'&&input.relay===true));assert.equal(operations.slice(before).map(input=>input.text).join(''),'V'+name);assert.equal(await page.locator('#automatic').isChecked(),true);assert.ok(await page.locator('#native-screen').evaluate(element=>element.clientHeight>=60));await capture(name+'-native');
    if(width>=760){await page.evaluate(()=>terminalFocus(true));await page.waitForTimeout(150);assert.ok(await page.locator('#send-input').evaluate(button=>button.getBoundingClientRect().bottom<=innerHeight));await capture(name+'-focus-native');await page.evaluate(()=>terminalFocus(false));}
  }
  checks.push('direct original input and image fit work at mobile/keyboard/tablet/desktop sizes without document overflow');
  stage='large-image';await page.setViewportSize({width:390,height:500});await page.evaluate(()=>terminalFocus(true));change({state:'live',image:images.large});await page.waitForFunction(()=>$('native-image').complete&&$('native-image').naturalWidth===2048);
  for(let step=0;step<12&&!await page.locator('#native-zoom-in').isDisabled();step++)await page.locator('#native-zoom-in').click();
  assert.ok(await page.locator('#native-image').evaluate(image=>parseFloat(image.style.width)>=2048));const beforePan=operations.length,box=await page.locator('#native-screen').boundingBox();await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.mouse.move(box.x+box.width/2-70,box.y+box.height/2-50,{steps:5});await page.mouse.up();assert.ok(await page.locator('#native-screen').evaluate(viewport=>viewport.scrollLeft>0&&viewport.scrollTop>0));assert.equal(operations.length,beforePan);await capture('mobile-large-zoom');
  await page.locator('#native-fit').click();change({state:'live',image:images.a});await live();checks.push('2048px original image reaches intrinsic pixel size and panning sends no CLI input');
  stage='nonlive';await page.setViewportSize({width:390,height:844});await page.evaluate(()=>terminalFocus(true));change({state:'inactive',message:'원본 탭이 비활성 상태입니다. 같은 탭을 연결해주세요.'},allKeys,false);await page.waitForFunction(()=>latestFrame?.nativeDisplay?.state==='inactive');assert.equal(await page.locator('#native-image').getAttribute('src'),null);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),false);assert.equal(await page.evaluate(()=>latestFrame.nativeDisplay.image),undefined);await capture('mobile-inactive');
  change({state:'permissionRequired',message:'Mac에서 화면 녹음과 손쉬운 사용 권한을 허용해주세요.'},['text','submit','enter'],false);await page.waitForFunction(()=>latestFrame?.nativeDisplay?.state==='permissionRequired');assert.equal(await page.locator('#input-editor').isVisible(),false);assert.equal(await page.locator('#compose-input').isDisabled(),false);
  checks.push('compact preview failures clear only the image; input remains governed by original key capability');
  change({state:'live',message:'연결됨',image:images.a});await live();
  for(const invalid of [{...images.a,width:4096},{...images.a,width:1023},{...images.a,data:'https://example.com/arbitrary.jpg'},{...images.a,data:'A'.repeat(1000004)}]){
    const streamCount=requests.stream;change({state:'live',message:'bad image',image:invalid});await page.waitForFunction(()=>latestFrame?.nativeDisplay?.state==='unavailable');assert.equal(await page.locator('#native-image').getAttribute('src'),null);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),false);assert.equal(await page.evaluate(()=>latestFrame.streamID),'unchanged-original-stream');assert.equal(requests.stream,streamCount);change({state:'live',image:images.a});await live();
  }
  await page.locator('#native-image').evaluate(image=>image.dispatchEvent(new Event('error')));await page.waitForFunction(()=>latestFrame?.nativeDisplay?.state==='unavailable');assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),false);await page.locator('#native-screen').click();const afterDecode=operations.length;await page.keyboard.type('DECODE');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.equal(operations.slice(afterDecode).map(input=>input.text).join(''),'DECODE');await live();
  assert.equal(externalImages.length,0);assert.equal(requests.pty,0);checks.push('JPEG size/base64/SOF and decode failures clear only preview; same original stream and direct input stay usable');
  stage='all-hosts';
  for(const [terminal,hostName] of [['iterm','iTerm2'],['vscode','VS Code'],['unknown','Other Terminal']]){
    original.terminal=terminal;original.hostName=hostName;await page.evaluate(()=>refreshNetwork());change({state:'live',message:hostName+'의 같은 원본 창',image:images.b});await live();
    assert.equal(await page.locator('#native-screen').isVisible(),true,'A supplied native display must render for '+hostName);assert.match(await page.locator('#native-image').getAttribute('alt'),new RegExp(hostName));
    assert.equal(await page.locator('#native-connect').isVisible(),true);await page.locator('#native-screen').click();await page.keyboard.type('HOST');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.equal(operations.at(-1).sessionID,original.id);assert.equal(requests.pty,0);
  }
  original.terminal='vscode';original.hostName='VS Code';await page.evaluate(()=>refreshNetwork());outputReason='이전 명령의 ANSI 출력은 연결 전이므로 읽을 수 없습니다. 같은 원본 입력은 사용할 수 있습니다.';await preview(false);change(undefined);await page.waitForFunction(()=>latestFrame?.outputReason&&!latestFrame.nativeDisplay);
  assert.equal(await page.locator('#native-screen').isVisible(),false);assert.equal(await page.locator('#terminal-screen').isVisible(),true);assert.equal(await page.locator('#native-connect').isVisible(),true);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),false);assert.equal(await page.locator('#input-editor').isVisible(),false);
  await page.locator('#terminal-screen').click();await page.keyboard.type('RAW');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.equal(operations.at(-1).sessionID,original.id);assert.equal(requests.connect,1);assert.equal(requests.pty,0);
  const beforeDefaultConnect=requests.screen;await page.locator('#native-connect').click();await loaded();assert.equal(requests.connectViews.at(-1),'terminal');assert.equal(requests.screen,beforeDefaultConnect);assert.equal(await page.evaluate(()=>latestFrame.nativeDisplay),undefined);await preview(true);await live();outputReason=undefined;assert.equal(requests.connect,2);assert.equal(requests.pty,0);assert.deepEqual(await page.evaluate(()=>({id:selectedItem.session.id,pid:selectedItem.session.pid,tty:selectedItem.session.tty,count:allSessions.length})),identity);
  checks.push('native displays and same-original keys support every supplied host while VS Code without an image retains its existing direct text route');
  stage='native-compose';change({state:'live',message:'이 원본 연결은 직접 키 입력만 지원합니다.',image:images.a},allKeys.filter(key=>!['text','submit'].includes(key)));await page.waitForFunction(()=>latestFrame?.nativeDisplay?.state==='live'&&!inputKeys().includes('text'));
  await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').check();await page.locator('#terminal-input').fill('manual draft only');
  assert.equal(await page.locator('#send-input').isDisabled(),true,'A native-only relay cannot silently accept unsupported composed submission');assert.equal(await page.locator('[data-key="up"]').isDisabled(),true);assert.match(await page.locator('#direct-input-help').innerText(),/직접.*지원/);
  await page.locator('#terminal-input').fill('');await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').uncheck();await page.locator('#native-screen').click();await page.keyboard.press('ArrowLeft');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.equal(operations.at(-1).relay,true);
  change({state:'live',message:'직접 키 입력에는 손쉬운 사용 권한이 필요합니다. 작성 전송은 사용할 수 있습니다.',image:images.a},['text','submit','enter']);await page.waitForFunction(()=>inputKeys().includes('submit')&&!inputKeys().includes('characters'));
  assert.equal(await page.locator('#input-editor').isVisible(),false);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),true);await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').check();await page.locator('#terminal-input').fill('safe original compose');assert.equal(await page.locator('#send-input').isDisabled(),false);await page.locator('#send-input').click();await page.waitForFunction(()=>!inputInFlight);assert.equal(operations.at(-1).kind,'submit');assert.equal(operations.at(-1).sessionID,original.id);assert.equal(operations.at(-1).relay,undefined);
  await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').uncheck();assert.equal(requests.pty,0);checks.push('native relay-only compose stays draft-only while explicitly supported basic composed input still targets the same original');
  stage='orca-relay-compose';original.terminal='orca';original.hostName='Orca';await page.evaluate(()=>refreshNetwork());await preview(false);change(undefined,allKeys.filter(key=>!['text','submit'].includes(key)));await page.waitForFunction(()=>latestFrame&&!latestFrame.nativeDisplay&&inputKeys().includes('characters')&&!inputKeys().includes('submit'));
  await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').check();await page.locator('#terminal-input').fill('Orca draft only');
  assert.equal(await page.locator('#send-input').isDisabled(),true,'Original ANSI relay-only Orca must disable unsupported composed submission');assert.equal(await page.locator('[data-key="up"]').isDisabled(),true);assert.match(await page.locator('#input-help').innerText(),/초안/);await capture('mobile-orca-draft');
  await page.locator('#terminal-input').fill('');await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').uncheck();await page.locator('#terminal-screen').click();await page.keyboard.type('ORCA');await page.waitForFunction(()=>!inputInFlight&&!directSending&&!directQueue.length);assert.equal(operations.at(-1).relay,true);assert.equal(operations.at(-1).sessionID,original.id);assert.equal(requests.pty,0);checks.push('Orca original ANSI relay supports direct input while unsupported compose remains a readable draft');
  stage='long-permission';await page.setViewportSize({width:390,height:500});await page.evaluate(()=>terminalFocus(true));change({state:'permissionRequired',message:'Mac 권한을 확인해주세요. '+('긴 원본 창 연결 경로 /fixture/permission/ '.repeat(80))},[]);await preview(true);await page.waitForFunction(()=>latestFrame?.nativeDisplay?.state==='permissionRequired');
  assert.equal(await page.locator('#input-editor').isVisible(),false);await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').check();await page.locator('#terminal-input').fill('optional draft');assert.equal(await page.locator('#send-input').isDisabled(),true);assert.match(await page.locator('#direct-input-help').innerText(),/권한/);
  assert.ok(await page.locator('#send-input').evaluate(button=>button.getBoundingClientRect().bottom<=innerHeight));await capture('mobile-long-permission');await page.locator('#terminal-input').fill('');await page.locator('#terminal-settings summary').click();await page.locator('#compose-input').uncheck();checks.push('long permission reasons stay scrollable within keyboard-sized viewports and optional drafts never enable unsupported input');
  change({state:'live',message:'연결됨',image:images.a});await live();
  online=false;await page.evaluate(()=>refreshNetwork());await page.waitForFunction(()=>!latestFrame);assert.equal(await page.locator('#native-image').getAttribute('src'),null);assert.equal(await page.locator('#terminal-keyboard-toggle').isDisabled(),true);await capture('mobile-disconnected');assert.equal(requests.pty,0);
  checks.push('disconnect clears native view and stops original input without CLI creation or replay');
  assert.deepEqual(errors,[]);const report={checks,screenshots,errors,requests,original:identity,inputOperations:operations.length,jpegBytes:Buffer.from(images.a.data,'base64').length,contentSecurityPolicy:'Exact app policy with fixture style nonce',scope:'Chromium synthetic native JPEG/SSE fixture; no physical iPhone Safari or real Mac permissions/window capture'};await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');await Promise.all(['failure.png','failure.json'].map(name=>rm(path.join(output,name),{force:true})));console.log(JSON.stringify({result:'PASS',...report}));
}catch(error){
  const detail=await page?.evaluate(()=>({key:selectedKey,frame:latestFrame&&{...latestFrame,nativeDisplay:latestFrame.nativeDisplay&&{...latestFrame.nativeDisplay,image:latestFrame.nativeDisplay.image&&{width:latestFrame.nativeDisplay.image.width,height:latestFrame.nativeDisplay.image.height}}},composeMode,directMode,inputFailure,focused:document.activeElement?.id})).catch(()=>null);
  await page?.screenshot({path:path.join(output,'failure.png')}).catch(()=>{});await writeFile(path.join(output,'failure.json'),JSON.stringify({stage,error:error.message,requests,operations,detail},null,2));throw error;
}finally{await browser?.close();for(const client of clients.keys())client.end();if(server.listening)await new Promise(resolve=>server.close(resolve));}
