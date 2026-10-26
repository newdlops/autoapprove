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
const parent=path.resolve(".runtime/peer-stream-batch-browser-check");fs.mkdirSync(parent,{recursive:true,mode:0o700});const root=fs.mkdtempSync(parent+'/run-');
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
const browserRecords=[],browserFrames=[];let lastID='';
for(let index=0;index<257;index++){
  let id;if(index%17===0)id='';else if(index%19===0)id='ignored'+String.fromCharCode(0)+'id';else if(index%5===0)id='record-'+index;
  if(id!==undefined&&!id.includes(String.fromCharCode(0)))lastID=id;
  const type=['screen','alive','message'][index%3],value={index,text:'합성🙂 é / "quoted"\n\u001b[32mgreen\u001b[0m '+index};
  const data=index%7===0?JSON.stringify(value,null,2):JSON.stringify(value);
  const record=(index%13===0?': keepalive\n\n':'')+'event: '+type+'\n'+(id===undefined?'':'id: '+id+'\n')+data.split('\n').map(line=>'data: '+line).join('\n')+'\n\n';
  browserFrames.push(Buffer.from(record));browserRecords.push({type,id:lastID,value});
}
const browserBody=Buffer.concat(browserFrames),browserGates=new Map(),browserReleases=new Map(),browserConnections=new Map();
entries['browser-ordered']={body:browserBody,browser:true};entries['browser-fragmented']={body:browserBody,browser:true,split:true};
entries['browser-partial']={body:Buffer.concat([browserBody,Buffer.from('data: {"unfinished":')]),browser:true};
entries['browser-reconnect']={body:browserBody,browser:true,reconnect:true};
entries['browser-header-gate']={body:browserBody,browser:true,gate:'headers'};entries['browser-record-gate']={body:browserBody,browser:true,gate:'record'};

const sockets=new Set(),responses=new Set(),children=new Set(),counts={};
const server=createServer((req,res)=>{
  const mode=new URL(req.url,'http://localhost').searchParams.get('mode'),entry=entries[mode];assert.ok(entry,'Unexpected upstream request '+req.url);assert.equal(req.method,'GET');assert.equal(req.headers['x-autoapprove-node'],owner);
  counts[mode]=(counts[mode]??0)+1;responses.add(res);res.once('close',()=>responses.delete(res));
  res.useChunkedEncodingByDefault=false;res.writeHead(200,{'Content-Type':'text/event-stream','X-AutoApprove-Node':entry.identity??owner,'Connection':'close'});
  if(entry.browser){
    const key=mode+'/'+new URL(req.url,'http://localhost').searchParams.get('test'),number=(browserConnections.get(key)??0)+1;browserConnections.set(key,number);
    if(entry.gate){
      assert.equal(browserGates.has(key),false);
      browserGates.set(key,()=>{browserReleases.set(key,(browserReleases.get(key)??0)+1);res.end(entry.gate==='headers'?entry.body:entry.body.subarray(browserFrames[0].length));});
      res.once('close',()=>browserGates.delete(key));
      if(entry.gate==='headers')res.flushHeaders();else res.write(entry.body.subarray(0,browserFrames[0].length));
    }else if(entry.reconnect){
      assert.ok(number<=2,'Unexpected third browser reconnect');
      res.end(Buffer.concat([Buffer.from('retry: 10\n\n'),...browserFrames.slice(number===1?0:128,number===1?128:undefined)]));
    }else if(entry.split){
      const widths=[1,2,3,7,17,127],body=entry.body;let offset=0,step=0;
      const write=()=>{if(res.destroyed)return;if(offset>=body.length){res.end();return;}const end=Math.min(body.length,offset+widths[step++%widths.length]);const data=body.subarray(offset,end);offset=end;res.write(data);setImmediate(write);};write();
    }else res.end(entry.body);
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
    const accept=data=>{bytes+=data.length;hash.update(data);if(end)chunks.push(data);if(!end&&bytes>=expected.length){assert.equal(bytes,expected.length);resolved=true;resolve({bytes,wire,trace:hash.digest('hex'),wall:(performance.now()-started)/1000});}};
    client=request(target.url+'/api/terminal/stream?node='+owner+'&session=synthetic&mode='+mode,{headers:{...(gzip?{'Accept-Encoding':'gzip'}:{}),...extraHeaders}},res=>{
      response=res;if(res.statusCode!==200){let body='';res.on('data',d=>body+=d);res.on('end',()=>resolve({status:res.statusCode,body,wall:(performance.now()-started)/1000}));return;}
      assert.equal(res.headers['x-autoapprove-node'],gateway);assert.equal(res.headers['content-type'],'text/event-stream; charset=utf-8');assert.equal(res.headers['cache-control'],'no-store');assert.equal(res.headers['content-encoding'],gzip?'gzip':undefined);
      res.on('data',data=>{wire+=data.length;});const output=gzip?(inflate=createGunzip(),res.pipe(inflate)):res;output.on('data',accept);output.once('error',reject);
      output.once('end',()=>{if(!resolved){resolved=true;resolve({bytes,wire,trace:hash.digest('hex'),bodyText:Buffer.concat(chunks).toString(),wall:(performance.now()-started)/1000});}});
    });client.once('error',reject);client.end();
  });
  return {...result,status:result.status??200,close(){inflate?.destroy();response?.destroy();client.destroy();}};
}
const bodyHash=entry=>createHash('sha256').update(entry.body).digest('hex');
try{
    const module=process.env.AUTOAPPROVE_PLAYWRIGHT_MODULE||'playwright',executablePath=process.env.AUTOAPPROVE_CHROMIUM_PATH;
    const {chromium}=await import(module),browser=await chromium.launch({headless:true,chromiumSandbox:true,...(executablePath?{executablePath}:{})}),checks=[],pageErrors=[];
    try{
      for(const label of ['candidate']){
        const target=await worker('browser-'+label,label);
        try{
          for(const encoding of ['identity','gzip']){
            const context=await browser.newContext({viewport:{width:390,height:844},isMobile:true,hasTouch:true,extraHTTPHeaders:{'Accept-Encoding':encoding}}),page=await context.newPage();page.on('pageerror',error=>pageErrors.push(String(error)));
            await page.goto(target.url+'/api/discovery');assert.equal(await page.evaluate(()=>location.origin),target.url);
            await page.exposeFunction('releaseOwnedTail',key=>{const release=browserGates.get(key);assert.ok(release,'Browser requested data before the upstream gate existed');browserGates.delete(key);release();});
            try{
              for(const mode of ['browser-ordered','browser-fragmented','browser-partial','browser-reconnect','browser-header-gate','browser-record-gate']){
                const token=label+'-'+encoding+'-'+mode,key=mode+'/'+token,url=target.url+'/api/terminal/stream?node='+owner+'&session=synthetic&mode='+mode+'&test='+token;
                const result=await page.evaluate(async({url,mode,key,total})=>await new Promise((resolve,reject)=>{
                  const source=new EventSource(url),records=[];let opens=0,reconnects=0,gateReleased=false,finished=false;
                  const timer=setTimeout(()=>finish(Error('Browser EventSource did not deliver all records')),12000);
                  function finish(error,failure){if(finished)return;finished=true;clearTimeout(timer);source.close();if(error)reject(error);else resolve({records,opens,reconnects,gateReleased,failure});}
                  source.onopen=()=>{opens++;if(mode==='browser-header-gate'&&!gateReleased){gateReleased=true;window.releaseOwnedTail(key).catch(finish);}};
                  for(const type of ['screen','alive','message'])source.addEventListener(type,event=>{
                    try{
                      records.push({type:event.type,id:event.lastEventId,value:JSON.parse(event.data)});
                      if(mode==='browser-record-gate'&&records.length===1&&!gateReleased){gateReleased=true;window.releaseOwnedTail(key).catch(finish);}
                      if(records.length===total&&mode!=='browser-partial')finish();
                    }catch(error){finish(error);}
                  });
                  source.addEventListener('failure',event=>{try{finish(undefined,{value:JSON.parse(event.data),id:event.lastEventId});}catch(error){finish(error);}});
                  source.onerror=()=>{if(mode==='browser-reconnect'){reconnects++;}else if(!finished)finish(Error('Unexpected browser stream error in '+mode));};
                }),{url,mode,key,total:browserRecords.length});
                assert.deepEqual(result.records,browserRecords,token+' event/id/Unicode ordering');
                if(mode==='browser-partial'){assert.equal(result.failure.value.retryable,true);assert.equal(typeof result.failure.value.error,'string');assert.equal(result.failure.id,browserRecords.at(-1).id);}
                if(mode==='browser-reconnect'){assert.equal(result.opens,2);assert.ok(result.reconnects>=1);assert.equal(browserConnections.get(key),2);}
                if(mode.endsWith('-gate')){assert.equal(result.gateReleased,true);assert.equal(browserReleases.get(key),1);}
                await untilSnapshot(target,row=>row.connections.every(connection=>connection.closed||!connection.nextPending));
                checks.push({label,encoding,mode,records:result.records.length,opens:result.opens,reconnects:result.reconnects,gateReleased:result.gateReleased,failure:result.failure??null,orderedNativeEvents:true,UTF8AndMultilineData:true,lastEventIDsExact:true});
              }
            }finally{await context.close();}
          }
          await untilSnapshot(target,row=>row.connections.length===0);
        }finally{await target.stop();}
      }
      assert.deepEqual(pageErrors,[]);
      fs.writeFileSync(root+'/report.json',JSON.stringify({passed:true,browser:'chromium',version:browser.version(),checks,actualNativeEventSource:true,actualCompiledCoreAcceptAndSend:true,productionClassRecompiled:false,sourcePage:'Same-origin Core /api/discovery JSON,not a replacement transport',viewport:{width:390,height:844},mobileEmulation:true,visualUIAudit:false,realPhoneOrWebKit:false,pageErrors,observerSHA256:sha(import.meta.filename),inputs,binarySHA256:sha(binary),originalTerminalActions:0,realPowerCommands:0},null,2)+String.fromCharCode(10),{flag:'wx',mode:0o600});
      console.log(JSON.stringify({passed:true,checks:checks.length,nativeEventSource:true,UnicodeIDsOrderAndReconnect:true,noWaitGates:true,realPhoneOrWebKit:false}));
    }finally{await browser.close();}
}finally{for(const child of children)child.kill();for(const res of responses)res.destroy();for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));}
verify();
