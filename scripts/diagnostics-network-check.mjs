import assert from'node:assert/strict';import{execFileSync,spawn}from'node:child_process';import{mkdtemp,readFile,writeFile,rm,mkdir}from'node:fs/promises';import path from'node:path';import{randomUUID}from'node:crypto';import{coreLinkArguments,coreSwiftObjects}from'./swift-core-link.mjs';
const root=await mkdtemp('/private/tmp/aa-diagnostics-net-'),build=path.resolve(process.env.AUTOAPPROVE_CHECK_BUILD??'.build/debug');let child;
try{
 execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/DiagnosticsNetwork'),'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...await coreSwiftObjects(build),'Tests/fixtures/diagnostics-network-preview.swift','-o',root+'/server'],{stdio:'inherit',timeout:120000});
 child=spawn(root+'/server',[root],{stdio:['ignore','pipe','inherit']});
 let info;const end=Date.now()+15000;while(Date.now()<end){try{info=JSON.parse(await readFile(root+'/info.json','utf8'));break;}catch{}await new Promise(r=>setTimeout(r,50));}assert.ok(info);
 async function call(origin,route,body,headers={}){const r=await fetch(origin+route,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json',Origin:origin,...headers}:headers,body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});return{status:r.status,body:await r.json()};}
 const a=info.first,b=info.second;
 const link=await call(a.url,'/api/peers',{address:b.url});assert.equal(link.status,200);assert.equal(link.body.id,b.nodeID);
 const query='?node='+b.nodeID,report=await call(a.url,'/api/diagnostics'+query);assert.equal(report.status,200);assert.equal(report.body.node.id,b.nodeID);assert.equal(report.body.summary.managedSessions,1);assert.equal(report.body.summary.historicalRecords,1);assert.equal(report.body.attachments[0].current,false);assert.equal(JSON.stringify(report.body).includes('NEVER_EXPORT_GOAL'),false);
 const appJS=await fetch(a.url+'/diagnostics.js'),style=await fetch(a.url+'/diagnostics.css');assert.equal(appJS.status,200);assert.equal(style.status,200);
 const cli=JSON.parse(execFileSync(build+'/autoapprove',['diagnostics'],{encoding:'utf8',env:{...process.env,AUTOAPPROVE_HOME:a.directory},timeout:25000}));assert.equal(cli.schemaVersion,1);assert.equal(cli.node.id,a.nodeID);
 const frames=[{jsonrpc:'2.0',id:1,method:'initialize',params:{protocolVersion:'2025-11-25'}},{jsonrpc:'2.0',id:2,method:'tools/list'},{jsonrpc:'2.0',id:3,method:'tools/call',params:{name:'get_diagnostics',arguments:{}}}];
 const mcp=execFileSync(build+'/autoapprove',['mcp'],{encoding:'utf8',input:frames.map(x=>JSON.stringify(x)).join('\n')+'\n',env:{...process.env,AUTOAPPROVE_HOME:a.directory},timeout:25000}).trim().split('\n').map(x=>JSON.parse(x));
 assert.equal(mcp.find(x=>x.id===2).result.tools.find(x=>x.name==='get_diagnostics').annotations.readOnlyHint,true);assert.equal(mcp.find(x=>x.id===3).result.structuredContent.node.id,a.nodeID);

 const id=randomUUID(),start={action:'start',requestID:id,question:'원격 연결을 진단해주세요'};
 const first=await call(a.url,'/api/diagnostics/codex'+query,start);assert.equal(first.status,200);assert.equal(first.body.job.id,id);assert.equal(first.body.job.phase,'running');
 const duplicate=await call(a.url,'/api/diagnostics/codex'+query,start);assert.equal(duplicate.status,200);assert.equal(duplicate.body.job.id,id);
 assert.equal((await call(a.url,'/api/diagnostics/codex'+query,{...start,question:'Different'})).status,409);
 let job;const done=Date.now()+10000;while(Date.now()<done){job=(await call(a.url,'/api/diagnostics/codex'+query+'&request='+id)).body.job;if(job.phase!=='running')break;await new Promise(r=>setTimeout(r,50));}assert.equal(job.phase,'completed');assert.match(job.result.findings[0].evidence,/관리형 연결 1개/);assert.equal((await readFile(b.directory+'/runs.txt','utf8')).trim(),'1');
 assert.equal((await call(a.url,'/api/diagnostics/codex',undefined)).body.job,null,'Remote diagnosis must not run on gateway');
 assert.notEqual((await call(a.url,'/api/diagnostics/codex'+query,{action:'start',requestID:randomUUID(),question:'Cross origin'},{Origin:'https://untrusted.invalid'})).status,200);
 await writeFile(b.directory+'/hold','');const cancelID=randomUUID();await call(a.url,'/api/diagnostics/codex'+query,{action:'start',requestID:cancelID,question:'Cancel'});const cancelled=await call(a.url,'/api/diagnostics/codex'+query,{action:'cancel',requestID:cancelID});assert.equal(cancelled.body.job.phase,'cancelled');await rm(b.directory+'/hold');
 const result={verified:true,readOnlySnapshot:true,remoteNodeExact:true,historicalNoticeCleared:true,cliAndAssets:true,mcpReadOnly:true,diagnosisOnTarget:true,duplicateRuns:0,changedRequestRejected:true,crossOriginRejected:true,cancelled:true,realTerminalActions:0};
 await mkdir('.runtime/diagnostics-249',{recursive:true});await writeFile('.runtime/diagnostics-249/network-report.json',JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));
 if(process.argv.includes('--serve')){await writeFile('.runtime/diagnostics-249/network-info.json',JSON.stringify({...info,driverPID:process.pid},null,2)+'\n');console.log(JSON.stringify({serve:true,info:'.runtime/diagnostics-249/network-info.json'}));await new Promise(resolve=>{process.once('SIGTERM',resolve);process.once('SIGINT',resolve);});}
}finally{if(child){child.kill('SIGTERM');await new Promise(r=>child.once('close',r));}await rm(root,{recursive:true,force:true});}
