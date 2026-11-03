import assert from'node:assert/strict';import{readFile,writeFile,mkdir}from'node:fs/promises';import path from'node:path';
const {chromium}=await import(process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright');
const info=JSON.parse(await readFile('.runtime/diagnostics-249/network-info.json','utf8')),out='.runtime/diagnostics-249/integrated-browser';await mkdir(out,{recursive:true});const browser=await chromium.launch({headless:true,channel:process.env.AUTOAPPROVE_CHROMIUM_PATH?undefined:'chrome',executablePath:process.env.AUTOAPPROVE_CHROMIUM_PATH||undefined}),errors=[],mutations=[];let page;
try{
 page=await browser.newPage({viewport:{width:1440,height:900}});page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(r.method()==='POST')mutations.push(r.url());});
 if(process.argv.includes('--source-assets'))for(const name of['diagnostics.js','diagnostics.css'])await page.route('**/'+name,async r=>r.fulfill({body:await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/'+name),contentType:name.endsWith('.js')?'text/javascript':'text/css'}));
 await page.goto(info.first.url);await page.waitForFunction(id=>nodes.some(n=>n.id===id&&n.online),info.second.nodeID);
 const index=await page.evaluate(id=>nodes.findIndex(n=>n.id===id),info.second.nodeID),button=page.locator('.machine-diagnostics').nth(index);
 await button.click();await page.waitForFunction(()=>!!diagnosticsUI?.snapshot&&diagnosticsUI.snapshot.node.id===diagnosticsUI.node.id);
 assert.equal(await page.evaluate(()=>diagnosticsUI.snapshot.node.id),info.second.nodeID);
 await page.getByText('현재 상태',{exact:true}).waitFor();await page.locator('#diagnostics-start').waitFor({state:'visible'});
 for(const theme of['light','dark'])for(const [name,width,height]of[['mobile',390,844],['tablet',768,1024],['desktop',1440,900]]){
  await page.emulateMedia({colorScheme:theme});await page.setViewportSize({width,height});
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth),false);
  for(const selector of['#diagnostics-close','#diagnostics-export']){const box=await page.locator(selector).boundingBox();assert.ok(box&&box.y>=0&&box.y+box.height<=height);}
  await page.screenshot({path:out+'/'+theme+'-'+name+'.png'});
 }
 await page.locator('#diagnostics-question').fill('현재 관리형 연결과 과거 실패 기록을 구분해주세요');await page.locator('#diagnostics-start').click();await page.waitForFunction(()=>diagnosticsUI?.job?.phase==='completed');
 assert.equal(await page.evaluate(()=>diagnosticsUI.job.result.findings[0].severity),'info');
 const download=page.waitForEvent('download');await page.locator('#diagnostics-export').click();const artifact=await download,file=out+'/export.json';await artifact.saveAs(file);const exported=JSON.parse(await readFile(file,'utf8'));assert.equal(exported.snapshot.node.id,info.second.nodeID);assert.equal(exported.job.phase,'completed');assert.equal(JSON.stringify(exported).includes('NEVER_EXPORT_GOAL'),false);
 await page.locator('#diagnostics-close').click();assert.equal(await button.evaluate(el=>el===document.activeElement),true);
 assert.ok(mutations.every(url=>/\/api\/diagnostics\/codex/.test(url)));assert.deepEqual(errors,[]);
 const report={verified:true,actualProductionRoute:true,actualTwoNodeHTTP:true,targetNodeExact:true,realSeparateCodex:false,injectedDiagnosticService:true,viewports:['390x844','768x1024','1440x900'],themes:['light','dark'],explicitRunAndExport:true,headerFooterVisible:true,focusRestored:true,errors,realTerminalActions:0};await writeFile(out+'/report.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report));
}finally{await browser.close();}
