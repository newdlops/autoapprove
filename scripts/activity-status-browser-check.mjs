// Real production analysis, network inventory and browser; no user terminal.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {mkdir,mkdtemp,readFile,writeFile,readdir,rm} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const option=name=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3);
const build=path.resolve(option('build')||'.build/status-stability/release'),baseline=process.argv.includes('--baseline');
const out=path.resolve(option('output')||'.runtime/status-stability/browser');await mkdir(out,{recursive:true,mode:0o700});
const root=await mkdtemp('/private/tmp/aa-status-'),wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function until(test,label,timeout=12000){const end=performance.now()+timeout;while(!await test()){assert.ok(performance.now()<end,label);await wait(25);}}
let child,browser,info,generation=0;const checks=[],errors=[],screenshots=[];let posts=0;
try{
 const cache=path.resolve('.build/cache/StatusPreview');await mkdir(cache,{recursive:true});
 const objects=(await readdir(build+'/AutoApproveCore.build')).filter(name=>name.endsWith('.swift.o')).map(name=>build+'/AutoApproveCore.build/'+name);
 const binary=root+'/StatusPreview';execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,'Tests/fixtures/activity-status-preview.swift','-o',binary],{stdio:'inherit',timeout:300000});
 child=spawn(binary,[root],{stdio:['ignore','pipe','pipe']});let output='',stderr='';child.stdout.on('data',data=>{output+=data;for(const line of output.split('\n'))try{const value=JSON.parse(line);if(value.url)info=value;}catch{}});child.stderr.on('data',data=>stderr+=data);
 await until(()=>info||child.exitCode!==null||child.signalCode!==null,'Status fixture startup');assert.ok(info,stderr);
 if(process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS!==undefined){const previous=process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS||'';process.env.PORT_MANAGER_PRESERVE_LISTEN_PORTS=[...new Set([...previous.split(',').filter(Boolean),new URL(info.url).port])].join(',');}
 const control=async action=>{await writeFile(info.control,JSON.stringify({action,generation:++generation}));await until(async()=>JSON.parse(await readFile(info.stats,'utf8')).generation===generation,'Control '+action);};
 const phases=async()=>{const response=await fetch(info.url+'/api/state');assert.equal(response.status,200);const value=await response.json();return info.sessions.map(id=>value.sessions.find(view=>view.session.id===id)?.session.phase);};
 const expected=baseline?['unknown','unknown','unknown','unknown']:['idle','input','idle','working'];
 await until(async()=>JSON.stringify(await phases())===JSON.stringify(expected),'Four production phases');checks.push('Production engine states: '+expected.join(', '));
 const playwright=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
 for(const engine of ['chromium','webkit']){
  browser=await playwright[engine].launch({headless:true,...(engine==='chromium'&&process.env.AUTOAPPROVE_CHROMIUM_PATH?{executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH}:{})});
  const page=await browser.newPage({viewport:{width:390,height:844}});page.on('pageerror',error=>errors.push(engine+': '+error.message));page.on('request',request=>{if(request.method()!=='GET')posts++;});
  await page.goto(info.url);await page.waitForFunction(()=>typeof allSessions!=='undefined'&&allSessions.length===4&&connected);
  const rendered=await page.locator('.session-row .phase').allTextContents();
  for(const text of baseline?['상태 미확인']:['대기 중','응답 필요','작업 중'])assert.ok(rendered.includes(text),JSON.stringify(rendered));
  if(!baseline){
   for(const[name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
    await page.setViewportSize({width,height});await page.waitForTimeout(100);assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
    const filename=engine+'-'+name+'.png';await page.screenshot({path:out+'/'+filename});screenshots.push(filename);
   }
   await control('draft');await page.getByRole('button',{name:'상태 새로고침'}).click();
   await page.waitForFunction(id=>allSessions.find(item=>item.session.id===id)?.session.phase==='input',info.sessions[0]);
   await control('ambiguous');await page.getByRole('button',{name:'상태 새로고침'}).click();
   await page.waitForFunction(id=>allSessions.find(item=>item.session.id===id)?.session.phase==='unknown',info.sessions[0]);
   await control('missing');await until(async()=>(await phases()).every(value=>value==='unknown'),'Missing source stays unknown');
   await page.getByRole('button',{name:'상태 새로고침'}).click();await page.waitForFunction(()=>allSessions.every(item=>item.session.phase==='unknown'));
   await control('restore');await until(async()=>JSON.stringify(await phases())===JSON.stringify(expected),'Source recovery');
   await page.getByRole('button',{name:'상태 새로고침'}).click();await page.waitForFunction(id=>allSessions.find(item=>item.session.id===id)?.session.phase==='idle',info.sessions[0]);
   await control('disconnect');await until(async()=>(await phases()).every(value=>value==='unknown'),'Explicit disconnect invalidation');
   await control('restore');await until(async()=>JSON.stringify(await phases())===JSON.stringify(expected),'Explicit reconnect');
   checks.push(engine+': responsive states, draft, ambiguous frame, missing source, recovery and explicit disconnect/reconnect');
  }
  await browser.close();browser=null;
 }
 assert.deepEqual(errors,[]);assert.equal(posts,0);assert.equal(JSON.parse(await readFile(info.stats,'utf8')).inputs,0);
 await control('stop');const report={passed:true,baseline,checks,screenshots,errors,writeRequests:posts,terminalInputs:0,scope:'Production Swift engine and loopback HTTP; four synthetic terminals in Chromium/WebKit; no user terminal, account, permission or network settings changed.'};
 await writeFile(out+'/report.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
}finally{
 await browser?.close();if(child&&child.exitCode===null&&child.signalCode===null){child.kill();await new Promise(resolve=>child.once('exit',resolve));}
 await rm(root,{recursive:true,force:true});
}
