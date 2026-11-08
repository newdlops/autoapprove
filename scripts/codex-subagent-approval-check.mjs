// Production Swift engine and transport against a synthetic Codex Unix server.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {execFileSync,spawn} from 'node:child_process';
import {mkdtemp,mkdir,readdir,rm,writeFile} from 'node:fs/promises';
import http from 'node:http';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';
const require=createRequire(import.meta.url),ws=require(path.join(path.dirname(globalThis.process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||require.resolve('playwright')),'../playwright-core/lib/utilsBundle.js'));
const dir=await mkdtemp('/private/tmp/aa-subagent-'),build=path.resolve('.build/debug');
const root='00000000-0000-4000-8000-000000000001',child='00000000-0000-4000-8000-000000000002',other='00000000-0000-4000-8000-000000000003';
const parent={id:root,cwd:'/fixture',name:'parent',source:'cli',parentThreadId:null,status:{type:'active',activeFlags:[]}};
const worker={id:child,cwd:'/fixture',agentNickname:'worker',source:{subAgent:{}},parentThreadId:root,status:{type:'active',activeFlags:['waitingOnApproval']}};
const server=http.createServer(),wss=new ws.wsServer({noServer:true}),connections=new Set(),responses=[];
let process, acknowledge=true;
const preview=globalThis.process.argv.includes('--ui');
try {
  await mkdir(path.join(dir,'app-server-control'));
  await mkdir('.build/cache/SubagentApprovals',{recursive:true});
  const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(n=>n.endsWith('.swift.o')).map(n=>path.join(build,'AutoApproveCore.build',n));
  const binary=preview?path.join(dir,'SubagentApprovalPreview.app/Contents/MacOS/SubagentApprovalPreview'):path.join(dir,'check');
  if(preview){
    await mkdir(path.dirname(binary),{recursive:true});
    await writeFile(path.join(dir,'SubagentApprovalPreview.app/Contents/Info.plist'),`<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.autoapprove.subagent-preview</string><key>CFBundleName</key><string>SubagentApprovalPreview</string><key>CFBundleExecutable</key><string>SubagentApprovalPreview</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>`);
    console.log('Preview app: '+path.join(dir,'SubagentApprovalPreview.app'));
  }
  execFileSync('/usr/bin/xcrun',['swiftc','-parse-as-library','-module-cache-path',path.resolve('.build/cache/SubagentApprovals'),'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,...(preview?['Sources/AutoApproveApp/CodexApprovalConnectionView.swift','Tests/fixtures/codex-approval-connection-preview.swift']:['Tests/fixtures/codex-subagent-approvals.swift']),'-o',binary],{stdio:'inherit'});
  server.on('upgrade',(req,socket,head)=>wss.handleUpgrade(req,socket,head,c=>wss.emit('connection',c)));
  wss.on('connection',socket=>{
    connections.add(socket);socket.on('close',()=>connections.delete(socket));
    socket.on('message',bytes=>{
      const m=JSON.parse(bytes.toString());
      if(!m.method){
        assert.ok(['hidden-command','hidden-file','hidden-mcp'].includes(m.id),'Only the requested tree and supported approvals can be answered');
        if(m.id==='hidden-mcp')assert.deepEqual(m.result,{action:'accept',content:{},_meta:null});else assert.equal(m.result.decision,'accept');responses.push(m.id);
        if(acknowledge||m.id!=='hidden-command')socket.send(JSON.stringify({method:'serverRequest/resolved',params:{threadId:child,requestId:m.id}}));return;
      }
      const reply=result=>socket.send(JSON.stringify({id:m.id,result}));
      if(m.method==='initialize'){assert.equal(m.params.capabilities.requiredHumanApproval,undefined);reply({userAgent:'fixture'});return;}
      if(m.method==='initialized')return;
      if(m.method==='thread/read'){assert.equal(m.params.includeTurns,false);reply({thread:m.params.threadId===root?parent:m.params.threadId===child?worker:{...worker,id:other,parentThreadId:other}});return;}
      if(m.method==='thread/turns/list'){reply({data:[{items:[{type:'subAgentActivity',agentThreadId:child,agentPath:'/root/worker'},{type:'subAgentActivity',agentThreadId:other,agentPath:'/root/unrelated'}]}],nextCursor:null});return;}
      if(m.method==='thread/loaded/list'){reply({data:[root,child,other],nextCursor:null});return;}
      if(m.method==='thread/list'){
        if(m.params.ancestorThreadId){assert.equal(m.params.ancestorThreadId,root);reply({data:[worker,{...worker,id:other,parentThreadId:other}],nextCursor:null});}
        else reply({data:[parent],nextCursor:null});return;
      }
      if(m.method==='thread/items/read'){reply({data:[{turnId:'turn',item:{id:'file',type:'fileChange',status:'inProgress',changes:[{path:'/fixture/source.swift',kind:{type:'update'},diff:'+updated'}]}}]});return;}
      assert.equal(m.method,'thread/resume');assert.deepEqual(m.params,{threadId:child,excludeTurns:true});reply({thread:worker});
      const command={threadId:child,turnId:'turn',itemId:'command',kind:'command',command:'echo fixture',cwd:'/fixture',availableDecisions:['accept','cancel']};
      for(const [id,params] of [['hidden-command',command],['unrelated',{...command,threadId:other}],['human',{...command,kind:'humanCommand'}],['resolved',command]])
        socket.send(JSON.stringify({id,method:'item/commandExecution/requestApproval',params}));
      socket.send(JSON.stringify({method:'serverRequest/resolved',params:{threadId:child,requestId:'resolved'}}));
      socket.send(JSON.stringify({id:'hidden-file',method:'item/fileChange/requestApproval',params:{threadId:child,turnId:'turn',itemId:'file'}}));
      const consent={threadId:child,turnId:null,serverName:'cua_repl',mode:'form',message:'Allow Computer Use to use "Fixture Lab"?',requestedSchema:{type:'object',properties:{}}};
      socket.send(JSON.stringify({id:'hidden-mcp',method:'mcpServer/elicitation/request',params:consent}));
      socket.send(JSON.stringify({id:'ordinary-question',method:'mcpServer/elicitation/request',params:{...consent,requestedSchema:{type:'object',properties:{answer:{type:'string'}}}}}));
    });
  });
  await new Promise(resolve=>server.listen(path.join(dir,'app-server-control/app-server-control.sock'),resolve));
  async function run(...args){process=spawn(binary,[dir,root,...args],{stdio:'inherit'});const code=await new Promise(resolve=>process.on('exit',resolve));assert.equal(code,0);}
  await run();
  if(!preview)assert.deepEqual(responses.sort(),['hidden-command','hidden-command','hidden-file','hidden-file','hidden-mcp','hidden-mcp'].sort());
  if(!preview){acknowledge=false;const before=responses.length;await run('--uncertain');assert.equal(responses.length,before+3);await run('--uncertain');assert.equal(responses.length,before+3,'Restart cannot replay an uncertain response');}
  console.log('PASS: each hidden approval answered once per independent authorized run; no terminal input or model calls');
} finally { if(process?.exitCode===null)process.kill();for(const s of connections)s.terminate();wss.close();server.close();await rm(dir,{recursive:true,force:true}); }
