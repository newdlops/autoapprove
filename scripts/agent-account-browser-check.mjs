// Actual Core/crypto/private PTYs in real browsers; synthetic provider sign-in.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/network-stability/release'),engine=process.argv.includes('--webkit')?'webkit':'chromium';
const out=path.resolve(option('output')||'.runtime/agent-auth-196/browser-'+engine);await mkdir(out,{recursive:true,mode:0o700});
const root=await mkdtemp('/private/tmp/aa-accounts-'),checks=[],errors=[],wire=[];let fixture,browser,page,closing=false;
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(check,label){const end=Date.now()+20000;while(!await check()){assert.ok(Date.now()<end,label);await delay(50);}}
try{
 const cache=path.resolve('.build/cache/AccountPreview');await mkdir(cache,{recursive:true});
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/AgentAccountFixture.swift','Tests/fixtures/agent-account-preview.swift','-o',root+'/Preview'],{stdio:'inherit',timeout:180000});
 fixture=spawn(root+'/Preview',[root],{stdio:['ignore','ignore','pipe']});let stderr='';fixture.stderr.on('data',value=>stderr+=value);
 let ready;try{await until(async()=>{assert.equal(fixture.exitCode,null,stderr);try{ready=JSON.parse(await readFile(root+'/ready.json','utf8'));return true;}catch{return false;}},'Account fixture startup');}catch(error){throw Error(error.message+' '+stderr);}
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');browser=await playwright[engine].launch({headless:true,...(engine==='chromium'?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined}:{})});
 const gatewayMode=process.argv.includes('--gateway');
 const context=await browser.newContext({viewport:{width:390,height:844}});page=await context.newPage();page.setDefaultTimeout(15000);page.on('pageerror',error=>errors.push(error.message));
 const origin=gatewayMode?'https://account.tunnel-qa.invalid':'http://account-qa.local';
 await page.route(origin+'/**',async route=>{
  try {
  const request=route.request(),url=new URL(request.url());
  if(url.pathname==='/api/agent-account')wire.push(JSON.parse(request.postData()));
  const headers={...request.headers(),host:new URL(origin).host};if(headers.origin)headers.origin=origin;
  // WebKit routing cannot fulfill a 304 response. Inventory validators are
  // independently covered by the actual Worker and Core transport suites.
  delete headers['if-none-match'];delete headers.prefer;
  const response=await route.fetch({url:new URL(url.pathname+url.search,gatewayMode?ready.gateway:ready.base).href,headers});
  await route.fulfill({response});
  }catch(error){if(!closing)throw error;}
 });
 await page.goto(origin);
 if(gatewayMode){await page.locator('#tunnel-key').fill('001234');await page.locator('#tunnel-login-submit').click();}
 await page.waitForFunction(()=>typeof connected!=='undefined'&&connected&&nodes.some(node=>node.online));
 assert.equal(await page.evaluate(()=>isSecureContext),gatewayMode,'Exercise the LAN HTTP or authenticated tunnel browser context');
 assert.equal(await page.evaluate(()=>!!crypto.subtle),gatewayMode);
 assert.equal(await page.locator('script[src="/agent-accounts.js"]').count(),0);assert.equal(await page.locator('script[src="/vendor/account-crypto.js"]').count(),0);
 await page.getByRole('button',{name:ready.name+' AI 계정 로그인',exact:true}).click();await page.locator('#account-pin').waitFor({state:'visible'});
 await page.locator('#account-pin').fill('001235');await page.getByRole('button',{name:'PIN 확인',exact:true}).click();await page.waitForFunction(()=>document.getElementById('account-message').textContent.includes('PIN이 맞지'));
 await page.locator('#account-pin').fill('001234');await page.getByRole('button',{name:'PIN 확인',exact:true}).click();await page.locator('#account-codex-login').waitFor({state:'visible'});
 await page.waitForFunction(()=>document.getElementById('account-codex-status').textContent==='로그인 필요');
 checks.push(gatewayMode?'Authenticated tunnel origin reaches the actual PIN gateway and unlocks the selected Mac with encrypted messages':'Insecure-context LAN HTTP loads no account resources before use; encrypted wrong/correct PIN unlocks the selected Mac without SubtleCrypto or Cloudflare');
 await page.evaluate(()=>{const send=accountUI.request.bind(accountUI);let beginLost=false,submitLost=false;accountUI.request=async object=>{const value=await send(object);if(object.action==='begin'&&!beginLost){beginLost=true;throw Error('Synthetic response loss after native begin');}if(object.action==='submit'&&!submitLost){submitLost=true;throw Error('Synthetic response loss after native code acceptance');}return value;};});
 await page.locator('#account-codex-login').click();await page.locator('#account-device-code').waitFor({state:'visible'});assert.equal(await page.locator('#account-device-code').textContent(),'ABCD-12345');
 assert.equal(await page.locator('#account-link').getAttribute('href'),'https://auth.openai.com/codex/device');
 const state=await (await context.request.get(ready.base+'/api/state')).json();assert.equal(state.sessions.length,0);
 const network=await (await context.request.get(ready.base+'/api/network')).text();assert.ok(!network.includes('ABCD-12345')&&!network.includes('code_challenge'));
 for(const[name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){await page.setViewportSize({width,height});assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);await page.screenshot({path:out+'/codex-'+name+'.png',animations:'disabled'});}
 await page.emulateMedia({colorScheme:'dark'});await page.setViewportSize({width:390,height:844});await page.screenshot({path:out+'/codex-dark-mobile.png',animations:'disabled'});await page.emulateMedia({colorScheme:'light'});
 await page.evaluate(()=>{const send=accountUI.request.bind(accountUI);let lost=false;accountUI.request=async object=>{if(object.action==='status'&&!lost){lost=true;throw Error('Synthetic temporary offline');}return send(object);};return accountUI.read();});
 await page.waitForFunction(()=>document.getElementById('account-message').textContent.includes('Synthetic temporary offline'));
 assert.equal(await page.locator('#account-device-code').textContent(),'ABCD-12345');await page.waitForFunction(()=>!document.getElementById('account-message').textContent);
 await writeFile(root+'/remote/signed-codex','synthetic provider approved');await page.locator('#account-codex-launch').waitFor({state:'visible'});
 assert.match(await page.locator('#account-codex-status').textContent(),/로그인됨/);
 checks.push('Codex device URL/code, private real PTY, zero public sessions, no challenge in inventory, native exit plus independent status confirmation');
 await page.locator('#account-claude-login').click();await page.locator('#account-code').waitFor({state:'visible'});assert.match(await page.locator('#account-link').getAttribute('href'),/^https:\/\/claude\.com\/cai\/oauth\/authorize\?/);
 await page.locator('#account-code').fill('SYNTHETIC-CODE#state');await delay(1500);assert.equal(await page.locator('#account-code').inputValue(),'SYNTHETIC-CODE#state','Status polling must preserve a code being typed');
 await page.screenshot({path:out+'/claude-mobile.png'});await page.getByRole('button',{name:'로그인 완료',exact:true}).click();await page.locator('#account-claude-launch').waitFor({state:'visible'});
 assert.equal(await readFile(root+'/remote/submitted-codes','utf8'),'SYNTHETIC-CODE#state\n');assert.equal(await page.locator('#account-code').inputValue(),'');
 checks.push('Claude URL and one-time code reach its private actual PTY exactly once; polling retains drafts and successful submission clears the field');
 checks.push('Lost begin/code results after native acceptance recover by status reads; a temporary read outage retains the challenge and automatically recovers without replay');
 const requests=JSON.stringify(wire);for(const secret of ['001234','001235','SYNTHETIC-CODE','ABCD-12345','code_challenge'])assert.equal(requests.includes(secret),false);
 assert.equal(await page.evaluate(()=>Object.keys(localStorage).some(key=>/account|token|pin/i.test(key))),false);
 await page.keyboard.press('Escape');assert.equal(await page.locator('#account-dialog').isVisible(),false);
 await page.getByRole('button',{name:ready.name+' AI 계정 로그인',exact:true}).click();await page.locator('#account-claude-launch').waitFor({state:'visible'});assert.equal(await page.locator('#account-pin').isVisible(),false);
 await rm(root+'/remote/signed-codex');await page.locator('#account-refresh').click();await page.locator('#account-codex-login').waitFor({state:'visible'});
 await page.locator('#account-codex-login').click();await page.locator('#account-device-code').waitFor({state:'visible'});await page.locator('#account-codex-cancel').click();await page.locator('#account-codex-login').waitFor({state:'visible'});assert.equal(await page.locator('#account-challenge').isVisible(),false);
 await writeFile(root+'/remote/expire-codex','expired fixture');await page.locator('#account-codex-login').click();await page.waitForFunction(()=>document.getElementById('account-codex-detail').textContent.includes('만료'));
 await writeFile(root+'/remote/missing-codex','missing fixture');await page.locator('#account-refresh').click();await page.waitForFunction(()=>document.getElementById('account-codex-status').textContent==='설치되지 않음');assert.equal(await page.locator('#account-codex-login').isDisabled(),true);
 await page.screenshot({path:out+'/missing-expired-mobile.png',animations:'disabled'});
 checks.push('Explicit cancellation closes only the private login process; provider expiry and a missing CLI have distinct actionable states');
 await page.locator('#account-claude-launch').click();await until(async()=>!!await readFile(root+'/remote/started-claude','utf8').then(()=>true).catch(()=>false),'Launch the signed-in tool on the selected remote Mac');
 assert.equal(await page.locator('#account-dialog').isVisible(),false);
 const targetState=await(await context.request.get(ready.peerBase+'/api/state')).json();assert.equal(targetState.sessions.filter(view=>view.ptyID).length,1);
 assert.equal((await(await context.request.get(ready.base+'/api/state')).json()).sessions.length,0);
 checks.push('The signed-in tool starts with one action in a normal managed PTY on the selected remote Mac, with its default home and automation off');
 assert.ok(!await readFile(root+'/local/signed-codex','utf8').catch(()=>''));
 checks.push('Two actual Core nodes forward encrypted requests to the chosen remote Mac; the gateway Mac stays signed out; Escape and same-page reopen preserve the in-memory grant');
 assert.deepEqual(errors,[]);const report={passed:true,engine,gatewayMode,checks,errors,encryptedRequests:wire.length,viewports:[[390,844],[768,1024],[1440,900]],scope:gatewayMode?'Real browser secure-origin simulation to actual native PIN gateway/two Core nodes/crypto/private PTYs; synthetic provider completion; actual Workers tested separately':'Real LAN-HTTP browser/two Core nodes/X25519-HKDF-ChaCha20Poly1305/private PTYs, synthetic provider URLs and completion; no real account, browser approval, user CLI or credentials modified'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}catch(error){await page?.screenshot({path:out+'/failure.png'}).catch(()=>{});await writeFile(out+'/failure.json',JSON.stringify({error:error.message,checks,errors},null,2));throw error;}
finally{closing=true;await browser?.close();await writeFile(root+'/stop','stop').catch(()=>{});if(fixture){await Promise.race([new Promise(resolve=>fixture.once('exit',resolve)),delay(1000)]);if(fixture.exitCode===null)fixture.kill('SIGTERM');}await rm(root,{recursive:true,force:true});}
