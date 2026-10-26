// Compiled release Core and owned synthetic loopback only. No original
// terminal,input,power,permissions or user browser profile is accessed.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import {createServer,request} from 'node:http';
import net from 'node:net';
import {createGunzip} from 'node:zlib';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const build=path.resolve(option('build','.build/release')),sourceRoot=path.resolve(option('source-root','.')),cache=path.resolve(option('cache','.build/module-cache'));
const parent=path.resolve(".runtime/peer-stream-batch-check");fs.mkdirSync(parent,{recursive:true,mode:0o700});const root=fs.mkdtempSync(parent+'/run-');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms)),sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fixture=path.resolve('Tests/fixtures/stream-send-watchdog-check.swift'),driver=import.meta.filename;
const objects=await coreSwiftObjects(build);
const links=await coreLinkArguments(build),inputs=Object.fromEntries([fixture,driver,path.join(path.dirname(import.meta.filename),'swift-core-link.mjs'),build+'/AutoApproveCore.build/output-file-map.json',sourceRoot+'/Sources/AutoApproveCore/RemotePTYStream.swift',sourceRoot+'/Sources/AutoApproveCore/RemoteHTTP.swift',build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))].map(file=>[file,sha(file)]));
function verify(){for(const[file,digest]of Object.entries(inputs))assert.equal(sha(file),digest,file);}
const binary=root+'/send-worker';verify();execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,fixture,'-o',binary],{stdio:'inherit',timeout:300000});verify();
const binding={binaries:{candidate:{path:binary,sha256:sha(binary)}}},owner='11111111-1111-4111-8111-111111111111',gateway='22222222-2222-4222-8222-222222222222';
const plan={performance:{specs:{"small":{"size":32,"count":32768},"medium":{"size":256,"count":4096},"screen":{"size":4096,"count":256},"single":{"size":4096,"count":1},"gzip-small":{"size":32,"count":32768,"gzip":true},"gzip-screen":{"size":4096,"count":256,"gzip":true}}}};
const frame=(size,index=0)=>Buffer.from(': '+String(index).padStart(Math.min(8,size-5),'0')+'x'.repeat(size-4-Math.min(8,size-5))+'\n\n');
const entries={};for(const[mode,spec]of Object.entries(plan.performance.specs))entries[mode]={...spec,body:Buffer.concat(Array.from({length:spec.count},(_,index)=>frame(spec.size,index)))};
entries.warm={size:32,count:256,body:Buffer.concat(Array.from({length:256},(_,i)=>frame(32,i)))};
entries.ordering={body:Buffer.concat(Array.from({length:513},(_,i)=>Buffer.from('event: screen\nid: '+i+'\ndata: '+JSON.stringify({screen:'합성🙂 é '+i+'\n',revision:String(i)})+'\n\n')))};
entries.fragmented={body:Buffer.from('event: screen\ndata: '+JSON.stringify({screen:'합성🙂 '+ 'x'.repeat(60000)})+'\n\n'),fragmented:true};
entries.empty={body:Buffer.alloc(0),end:true};entries.eof={body:entries.ordering.body,end:true};
entries.identity={body:frame(32),identity:'wrong'};entries.incomplete={body:Buffer.from(': unfinished'),end:true};
entries.oversized={body:Buffer.alloc(2_000_129,120),end:true};entries.idle={body:frame(32),idle:true};
entries.late={body:frame(32),late:true};
entries['header-gate']={body:frame(32),gate:'headers'};entries['record-gate']={body:Buffer.concat([frame(32,0),frame(32,1)]),gate:'record'};
const gates=new Map(),releases=new Map();
const sockets=new Set(),responses=new Set(),children=new Set(),counts={};
const server=createServer((req,res)=>{
  const mode=new URL(req.url,'http://localhost').searchParams.get('mode'),entry=entries[mode];assert.ok(entry,'Unexpected upstream request '+req.url);assert.equal(req.method,'GET');assert.equal(req.headers['x-autoapprove-node'],owner);
  counts[mode]=(counts[mode]??0)+1;responses.add(res);res.once('close',()=>responses.delete(res));
  res.useChunkedEncodingByDefault=false;res.writeHead(200,{'Content-Type':'text/event-stream','X-AutoApprove-Node':entry.identity??owner,'Connection':'close'});
  if(entry.gate){
    assert.equal(gates.has(mode),false);
    gates.set(mode,()=>{releases.set(mode,(releases.get(mode)??0)+1);res.end(entry.gate==='headers'?entry.body:entry.body.subarray(32));});
    res.once('close',()=>gates.delete(mode));
    if(entry.gate==='headers')res.flushHeaders();else res.write(entry.body.subarray(0,32));
  }else if(entry.fragmented){res.write(entry.body.subarray(0,-1));const timer=setTimeout(()=>res.write(entry.body.subarray(-1)),25);res.once('close',()=>clearTimeout(timer));}
  else if(entry.end)res.end(entry.body);else res.write(entry.body);
  if(entry.idle){const timer=setInterval(()=>res.write(frame(32)),1000);res.once('close',()=>clearInterval(timer));}
  if(entry.late){const timer=setTimeout(()=>{const packet=frame(32768);let left=2048;const write=()=>{while(left-->0){if(!res.write(packet)){res.once('drain',write);return;}}};write();},27000);res.once('close',()=>clearTimeout(timer));}
});
server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
const upstream='http://127.0.0.1:'+server.address().port;
async function worker(name,label){
  const item=binding.binaries[label],out=fs.openSync(root+'/'+name+'.stdout','wx',0o600),err=fs.openSync(root+'/'+name+'.stderr','wx',0o600),start=performance.now();
  const child=spawn(item.path,[upstream,root+'/state-'+name],{stdio:['pipe','pipe',err]});children.add(child);
  let text='',pending,readyResolve,readyReject,doneResolve,closed=false,sequence=0;
  const ready=new Promise((resolve,reject)=>{readyResolve=resolve;readyReject=reject;}),done=new Promise(resolve=>{doneResolve=resolve;});
  fs.writeFileSync(root+'/'+name+'.started.json',JSON.stringify({pid:child.pid,binary:item.path,at:new Date().toISOString(),binarySHA256:item.sha256})+'\n',{flag:'wx',mode:0o600});
  child.stdout.on('data',data=>{text+=data.toString();let end;while((end=text.indexOf('\n'))>=0){const line=text.slice(0,end);text=text.slice(end+1);fs.writeSync(out,line+'\n');const value=JSON.parse(line);if(value.ready){assert.equal(value.actualCoreAcceptAndSend,true);assert.equal(value.originalAcceptorCancelled,true);assert.equal(value.loopbackOnly,true);readyResolve(value);}else{assert.equal(value.id,pending?.id);const active=pending;pending=undefined;active.resolve(value);}}});
  child.stdin.on('error',error=>{readyReject(error);pending?.reject(error);});
  child.once('error',error=>{readyReject(error);pending?.reject(error);});
  child.once('exit',(code,signal)=>{closed=true;children.delete(child);const result={code,signal,seconds:(performance.now()-start)/1000};fs.closeSync(out);fs.closeSync(err);fs.writeFileSync(root+'/'+name+'.job.json',JSON.stringify(result)+'\n',{flag:'wx',mode:0o600});if(code!==0){const error=Error(name+' failed\n'+fs.readFileSync(root+'/'+name+'.stderr','utf8').slice(-3500));readyReject(error);pending?.reject(error);}doneResolve(result);});
  const info=await ready;
  return {url:info.url,async snapshot(){assert.equal(pending,undefined);const id=name+'/'+sequence++;const reply=new Promise((resolve,reject)=>{pending={id,resolve,reject};});child.stdin.write(JSON.stringify({id,command:'snapshot'})+'\n');return reply;},async stop(){if(!closed)child.stdin.end();const result=await done;assert.equal(result.code,0);assert.equal(result.signal,null);}};
}
async function untilSnapshot(target,predicate,limit=5000){const end=performance.now()+limit;do{const row=await target.snapshot();if(predicate(row))return row;await sleep(5);}while(performance.now()<end);throw Error('Owned connection state did not settle');}
async function burst(target,mode,{end=false,gzip=entries[mode].gzip??false,extraHeaders={}}={}){
  const expected=entries[mode].body,started=performance.now();let client,resolved=false,response,inflate;
  const result=await new Promise((resolve,reject)=>{
    let bytes=0,wire=0;const chunks=[];const hash=createHash('sha256');
    const accept=data=>{bytes+=data.length;hash.update(data);if(entries[mode].gate==='record'&&bytes>=32){const permit=gates.get(mode);if(permit){gates.delete(mode);permit();}}if(end)chunks.push(data);if(!end&&bytes>=expected.length){assert.equal(bytes,expected.length);resolved=true;resolve({bytes,wire,trace:hash.digest('hex'),wall:(performance.now()-started)/1000});}};
    client=request(target.url+'/api/terminal/stream?node='+owner+'&session=synthetic&mode='+mode,{headers:{...(gzip?{'Accept-Encoding':'gzip'}:{}),...extraHeaders}},res=>{
      response=res;if(res.statusCode!==200){let body='';res.on('data',d=>body+=d);res.on('end',()=>resolve({status:res.statusCode,body,wall:(performance.now()-started)/1000}));return;}
      if(entries[mode].gate==='headers'){const permit=gates.get(mode);assert.ok(permit,'Upstream body was not held until downstream headers');gates.delete(mode);permit();}
      assert.equal(res.headers['x-autoapprove-node'],gateway);assert.equal(res.headers['content-type'],'text/event-stream; charset=utf-8');assert.equal(res.headers['cache-control'],'no-store');assert.equal(res.headers['content-encoding'],gzip?'gzip':undefined);
      res.on('data',data=>{wire+=data.length;});const output=gzip?(inflate=createGunzip(),res.pipe(inflate)):res;output.on('data',accept);output.once('error',reject);
      output.once('end',()=>{if(!resolved){resolved=true;resolve({bytes,wire,trace:hash.digest('hex'),bodyText:Buffer.concat(chunks).toString(),wall:(performance.now()-started)/1000});}});
    });client.once('error',reject);client.end();
  });
  return {...result,status:result.status??200,close(){inflate?.destroy();response?.destroy();client.destroy();}};
}
const bodyHash=entry=>createHash('sha256').update(entry.body).digest('hex');
try{
    const checks=[];
    for(const label of ['candidate']){
      const target=await worker('correctness-'+label,label);
      try{
        for(const mode of ['small','medium','screen','single','gzip-small','gzip-screen','ordering','fragmented','empty','eof']){
          const result=await burst(target,mode,{end:entries[mode].end??false});assert.equal(result.status,200);assert.equal(result.bytes,entries[mode].body.length);assert.equal(result.trace,bodyHash(entries[mode]));
          const state=await untilSnapshot(target,row=>row.connections.every(c=>!c.sending));
          if(!entries[mode].end){assert.equal(state.connections.length,1);assert.equal(state.connections[0].nextPending,true);if(label==='candidate'){assert.equal(state.connections[0].scheduled,true);assert.equal(state.connections[0].expiration,'0');}}
          result.close();await untilSnapshot(target,row=>row.connections.length===0);checks.push({label,mode,status:result.status,bytes:result.bytes,trace:result.trace});
        }
        for(const mode of ['identity','incomplete','oversized'])for(const gzip of [false,true]){
          const result=await burst(target,mode,{end:true,gzip}),value={status:result.status,bytes:result.bytes??null,trace:result.trace??null,body:result.body??null},key=mode+'/'+gzip;
          if(mode==='identity'){assert.equal(result.status,502);assert.equal(JSON.parse(result.body).diagnostics.failureKind,'identity');}
          else {assert.equal(result.status,200);assert.match(result.bodyText,/^event: failure\ndata: /);const failure=JSON.parse(result.bodyText.split('data: ')[1].trim());assert.equal(typeof failure.error,'string');assert.equal(failure.retryable,mode==='incomplete');}
          result.close();await untilSnapshot(target,row=>row.connections.length===0);checks.push({label,mode,gzip,...value});
        }
        const denied=await burst(target,'single',{extraHeaders:{Origin:'http://untrusted.invalid'}});assert.equal(denied.status,403);denied.close();await untilSnapshot(target,row=>row.connections.length===0);checks.push({label,mode:'origin',status:403});
        const holders=[];try{
          for(let i=0;i<12;i++)holders.push(await burst(target,'single'));
          const limited=await burst(target,'single');assert.equal(limited.status,429);limited.close();checks.push({label,mode:'stream-slots',slots:12,rejected:429});
          const state=await target.snapshot();assert.ok(state.connections.length>=12);
        }finally{for(const held of holders)held.close();await untilSnapshot(target,row=>row.connections.length===0);}
        const reconnect=await burst(target,'ordering');assert.equal(reconnect.trace,bodyHash(entries.ordering));reconnect.close();await untilSnapshot(target,row=>row.connections.length===0);checks.push({label,mode:'reconnect',passed:true});
      }finally{await target.stop();}
    }
    const causalChecks=[];
    for(const label of ['candidate']){
      const target=await worker('causal-'+label,label);
      try{
        for(const mode of ['header-gate','record-gate','empty','eof'])for(const gzip of [false,true]){
          const before=releases.get(mode)??0;let timer;
          const timeout=new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error('Ready headers/record waited for withheld source data')),8000);});
          let result;try{result=await Promise.race([burst(target,mode,{end:true,gzip}),timeout]);}finally{clearTimeout(timer);}
          assert.equal(result.status,200);assert.equal(result.bytes,entries[mode].body.length);assert.equal(result.trace,bodyHash(entries[mode]));
          if(entries[mode].gate)assert.equal(releases.get(mode),before+1);
          result.close();await untilSnapshot(target,row=>row.connections.length===0);
          causalChecks.push({label,mode,gzip,bytes:result.bytes,wire:result.wire,trace:result.trace,headerOrRecordReleasedBeforeTail:!!entries[mode].gate,completeGzipMemberVerified:gzip});
        }
      }finally{await target.stop();}
    }
    async function raw(target,mode){
      const url=new URL(target.url);let socket;
      const result=await new Promise((resolve,reject)=>{
        let buffer=Buffer.alloc(0),ready=false;
        socket=net.createConnection({host:'127.0.0.1',port:Number(url.port),allowHalfOpen:true},()=>socket.write('GET /api/terminal/stream?node='+owner+'&session=synthetic&mode='+mode+' HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'));
        socket.on('data',data=>{if(ready)return;buffer=Buffer.concat([buffer,data]);const header=buffer.indexOf('\r\n\r\n');if(header>=0&&buffer.length>=header+4+(mode==='empty'?0:32)){assert.match(buffer.subarray(0,header).toString(),/^HTTP\/1.1 200 /);ready=true;if(mode==='late')socket.pause();resolve({at:performance.now()});}});
        socket.once('error',reject);
      });return {...result,close(){socket.destroy();}};
    }
    const rows=await Promise.all(['candidate'].map(async label=>{
      const target=await worker('deadlines-'+label,label),clients=[];
      try{
        const final=await raw(target,'empty');clients.push(final);const first=await target.snapshot();assert.equal(first.connections.length,1);
        await sleep(6200);const afterFinal=await target.snapshot();assert.equal(afterFinal.connections.length,0,'Final FIN retained a slot beyond5seconds');final.close();
        const idle=await raw(target,'idle'),late=await raw(target,'late');clients.push(idle,late);
        await sleep(28200);const blocked=await untilSnapshot(target,row=>row.connections.length===2&&row.connections.some(c=>c.sending),3000);
        await sleep(Math.max(0,31500-(performance.now()-late.at)));const stale=await target.snapshot();
        assert.equal(stale.connections.length,2,'Old initial deadline closed a later send');assert.ok(stale.connections.some(c=>c.sending),'Slow-reader send was not pending');
        // TCP may acknowledge buffered bytes several seconds after pause().
        // That completes a send and starts another full30s window. Observe
        // each current deadline; the first blocked snapshot is not its start.
        let lastExpiry=0;const deadlineObservations=[];
        function observeDeadline(row){
          const send=row.connections.find(c=>c.sending);if(!send)return;
          const expiry=Number(send.expiration)/1e9;assert.ok(Number.isFinite(expiry)&&expiry>0);
          const remaining=expiry-row.metrics.uptime;assert.ok(remaining<=30.1,'A send received more than30seconds');
          if(expiry!==lastExpiry){lastExpiry=expiry;deadlineObservations.push({observedAt:row.metrics.uptime,expiresAt:expiry,remaining});}
        }
        observeDeadline(blocked);observeDeadline(stale);
        let timeout;const limit=late.at+75000;
        do{timeout=await target.snapshot();observeDeadline(timeout);if(timeout.connections.length===1)break;await sleep(250);}while(performance.now()<limit);
        assert.equal(timeout.connections.length,1,'Blocked reader did not release its connection');
        const timeoutAge=timeout.metrics.uptime-blocked.metrics.uptime,timeoutAfterExpiry=timeout.metrics.uptime-lastExpiry;
        assert.ok(lastExpiry>0&&timeoutAfterExpiry>=0&&timeoutAfterExpiry<=2,'Current send deadline did not close its connection: '+timeoutAfterExpiry);
        assert.equal(timeout.connections[0].closed,false,'Idle heartbeat stream was closed');
        for(const client of clients)client.close();await untilSnapshot(target,row=>row.connections.length===0);
        const reopen=await burst(target,'ordering');assert.equal(reopen.trace,bodyHash(entries.ordering));reopen.close();await untilSnapshot(target,row=>row.connections.length===0);
        return {label,passed:true,finalSlotReleased:true,staleDeadlineKeptNewSend:true,blocked,stale,timeout,timeoutAge,timeoutAfterExpiry,deadlineObservations,idleSurvived:true,reconnect:true};
      }finally{for(const client of clients)client.close();await target.stop();}
    }));

    verify();const report={passed:true,checks,causalChecks,deadlineCases:rows,inputs,binarySHA256:sha(binary),actualCompiledCoreAcceptAndSend:true,productionClassRecompiled:false,logicalRecordBytesExact:true,causalNoWait:true,perSendSeconds:30,finalSeconds:5,originalTerminalActions:0,realPowerCommands:0};
    fs.writeFileSync(root+'/report.json',JSON.stringify(report,null,2)+String.fromCharCode(10),{flag:'wx',mode:0o600});console.log(JSON.stringify({passed:true,checks:checks.length,causalChecks:causalChecks.length,deadlineCases:5,actualCoreSend:true}));
}finally{for(const child of children)child.kill();for(const res of responses)res.destroy();for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));}
verify();
