// Actual release Core and synthetic upstream only. The fixture cancels its
// own acceptor/monitors before its first await; no original terminal or app.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn,execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {gzipSync} from 'node:zlib';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';
const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const build=path.resolve(option('build','.build/release')),sourceRoot=path.resolve(option('source-root','.'));
const cache=path.resolve(option('cache','.build/module-cache')),parent=path.resolve('.runtime/peer-stream-buffer-check');
fs.mkdirSync(parent,{recursive:true,mode:0o700});const root=fs.mkdtempSync(parent+'/run-');
const action='check',plan={specs:{"small":{"size":32,"count":8192,"rounds":1},"medium":{"size":256,"count":1024,"rounds":2},"screen":{"size":4096,"count":64,"rounds":8},"single":{"size":4096,"count":1,"rounds":32},"large-tail":{"size":1900000,"count":65,"rounds":8},"gzip-small":{"size":32,"count":8192,"rounds":1},"gzip-large-tail":{"size":1900000,"count":65,"rounds":8}}};
const sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fixture=path.resolve('Tests/fixtures/peer-stream-buffer-check.swift'),driver=import.meta.filename;
const objects=await coreSwiftObjects(build),links=await coreLinkArguments(build);

const hashes=Object.fromEntries([fixture,driver,path.join(path.dirname(import.meta.filename),'swift-core-link.mjs'),build+'/AutoApproveCore.build/output-file-map.json',sourceRoot+'/Sources/AutoApproveCore/RemotePTYStream.swift',build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(v=>v.endsWith('.o'))].map(file=>[file,sha(file)]));
function verify(){for(const[file,digest]of Object.entries(hashes))assert.equal(sha(file),digest,file);}
verify();execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-Xfrontend','-disable-access-control','-module-cache-path',cache,'-I',build+'/Modules','-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...links,...objects,fixture,'-o',root+'/check-worker'],{stdio:'inherit',timeout:300000});verify();
  const owner='11111111-1111-4111-8111-111111111111',frame=size=>Buffer.from(': '+'x'.repeat(size-4)+'\n\n');
  const cases={};
  for(const[name,spec]of Object.entries(plan.specs)){
    const frames=name.includes('large-tail')?[frame(spec.size),...Array.from({length:spec.count-1},()=>frame(32))]:Array.from({length:spec.count},()=>frame(spec.size));
    cases[name]={frames,gzip:name.startsWith('gzip')};
  }
  cases.ordering={frames:[Buffer.from(': heartbeat\n\n'),...Array.from({length:513},(_,index)=>Buffer.from('event: screen\nid: '+index+'\ndata: '+JSON.stringify({screen:'합성🙂 é '+index+'\n',revision:String(index)})+'\n\n'))]};
  cases.fragmented={frames:[Buffer.from('event: screen\ndata: '+JSON.stringify({screen:'합성🙂 '+ 'x'.repeat(60000)})+'\n\n')],fragmented:true};
  cases['header-only']={frames:[frame(32)],headerOnly:true};
  cases.incomplete={frames:[frame(32)],suffix:Buffer.from(': unfinished'),error:503};
  cases.oversized={frames:[],raw:Buffer.alloc(2_000_129,120),error:502};
  cases.identity={frames:[],raw:frame(32),identity:false,status:502};
  cases['gzip-corrupt']={frames:[frame(32)],gzip:true,corrupt:true,error:503,allowPrefix:true};
  cases['gzip-truncated']={frames:[frame(32)],gzip:true,truncated:true,error:503,allowPrefix:true};
  cases.long={frames:Array.from({length:32768},()=>frame(31))};
  cases['boundary-valid']={frames:[frame(2_000_128)]};
  cases['boundary-over']={frames:[],raw:frame(2_000_129),error:502};
  cases.empty={frames:[]};
  for(const entry of Object.values(cases)){
    const plain=entry.raw??Buffer.concat([...entry.frames,...(entry.suffix?[entry.suffix]:[])]);entry.plain=plain;entry.wire=entry.gzip?gzipSync(plain,{level:1}):plain;
    if(entry.corrupt){entry.wire=Buffer.from(entry.wire);entry.wire[entry.wire.length-5]^=255;}
    if(entry.truncated)entry.wire=entry.wire.subarray(0,entry.wire.length-5);
  }
  const sockets=new Set(),children=[],requests={},server=createServer((req,res)=>{
    const name=new URL(req.url,'http://localhost').searchParams.get('mode'),entry=cases[name];assert.ok(entry,'Unexpected metadata or LAN request '+req.url);assert.equal(req.method,'GET');assert.equal(req.headers['x-autoapprove-node'],owner);requests[name]=(requests[name]??0)+1;
    res.useChunkedEncodingByDefault=false;res.writeHead(200,{'Content-Type':'text/event-stream','X-AutoApprove-Node':entry.identity===false?'wrong-owner':owner,'Connection':'close',...(entry.gzip?{'Content-Encoding':'gzip'}:{})});
    if(entry.headerOnly||entry.fragmented){if(entry.headerOnly)res.flushHeaders();else res.write(entry.wire.subarray(0,entry.wire.length-1));const timer=setTimeout(()=>res.end(entry.headerOnly?entry.wire:entry.wire.subarray(entry.wire.length-1)),entry.headerOnly?250:30);res.once('close',()=>clearTimeout(timer));}
    else res.end(entry.wire);
  });
  server.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});
  async function worker(name,label,url){
    verify();const binary=root+'/check-worker',args=[url,root+'/state-'+name,label];
    const out=fs.openSync(root+'/'+name+'.stdout','wx',0o600),err=fs.openSync(root+'/'+name+'.stderr','wx',0o600),start=performance.now(),child=spawn(binary,args,{stdio:['pipe','pipe',err]});children.push(child);
    let text='',pending,readyResolve,readyReject,doneResolve,rows=0,closed=false;
    const ready=new Promise((resolve,reject)=>{readyResolve=resolve;readyReject=reject;}),done=new Promise(resolve=>{doneResolve=resolve;});
    fs.writeFileSync(root+'/'+name+'.started.json',JSON.stringify({command:binary,args,pid:child.pid,at:new Date().toISOString()})+'\n',{flag:'wx',mode:0o600});
    child.stdout.on('data',bytes=>{text+=bytes.toString();let newline;while((newline=text.indexOf('\n'))>=0){const line=text.slice(0,newline);text=text.slice(newline+1);let value;try{value=JSON.parse(line);}catch(error){readyReject(error);pending?.reject(error);continue;}if(value.ready){assert.equal(value.actualCorePublicHandler,true);assert.equal(value.ownedAcceptorCancelled,true);readyResolve();continue;}fs.writeSync(out,JSON.stringify(value)+'\n');rows++;if(pending&&pending.id===value.id){const active=pending;pending=undefined;active.resolve(value);}else{const error=Error('Unexpected owned row '+value.id);readyReject(error);pending?.reject(error);}}});
    child.stdin.on('error',error=>{readyReject(error);pending?.reject(error);});
    child.once('error',error=>{readyReject(error);pending?.reject(error);doneResolve({code:null,error:String(error)});});
    child.once('exit',(code,signal)=>{closed=true;fs.closeSync(out);fs.closeSync(err);const result={code,signal,seconds:(performance.now()-start)/1000,rows};fs.writeFileSync(root+'/'+name+'.job.json',JSON.stringify(result)+'\n',{flag:'wx',mode:0o600});if(code!==0){const error=Error(name+' failed: '+fs.readFileSync(root+'/'+name+'.stderr','utf8').slice(-3500));readyReject(error);pending?.reject(error);}doneResolve(result);});
    return {ready,async request(value){assert.equal(pending,undefined);assert.equal(closed,false);const result=new Promise((resolve,reject)=>{pending={id:value.id,resolve,reject};});child.stdin.write(JSON.stringify(value)+'\n');return result;},async stop(){if(!closed)child.stdin.end();const result=await done;assert.equal(result.code,0);assert.equal(result.signal,null);return result;}};
  }
  const trace=frames=>{const hash=createHash('sha256');for(const data of frames){const length=Buffer.alloc(8);length.writeBigInt64LE(BigInt(data.length));hash.update(length);hash.update(data);}return hash.digest('hex');};
  try{
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});const url='http://127.0.0.1:'+server.address().port;

      const checks=[];
      for(const label of ['candidate']){
        const target=await worker('check-'+label,label,url);await target.ready;
        try{for(const name of [...Object.keys(cases),'backpressure','cancel']){
          const entry=cases[name]??cases.small,mode=cases[name]?name:'small',result=await target.request({id:label+'/'+name,mode,check:true,pause:name==='backpressure',cancel:name==='cancel'});
          assert.equal(result.status,entry.status??200,name);
          if(result.status===200){
            const prefix=entry.allowPrefix||name==='cancel';assert.ok(prefix?result.events<=entry.frames.length:result.events===entry.frames.length,name+' events');
            const expected=entry.frames.slice(0,result.events);assert.equal(result.bytes,expected.reduce((sum,b)=>sum+b.length,0));assert.equal(result.trace,trace(expected));assert.equal(result.callerOutputsRetainedExactly,true);
            assert.equal(result.error?.status,entry.error,name+' body error');if(name==='fragmented'||name==='header-only')assert.equal(result.initialBytes,0);
            assert.ok(result.chunks<=result.events,'Chunks cannot exceed complete logical records');
            if(['small','medium','gzip-small','long'].includes(name))assert.ok(result.chunks>0,'Actual Core output must remain nonempty');
          }else assert.equal(result.events,0);
          checks.push({label,name,...result});
        }}finally{await target.stop();}
      }
      const report={passed:true,inputs:hashes,coreObjects:objects.length,moduleSHA256:hashes[build+'/Modules/AutoApproveCore.swiftmodule'],binarySHA256:sha(root+'/check-worker'),casesPerSide:Object.keys(cases).length+2,checks,actualCompiledCore:true,noStreamClassRecompiled:true,retainedOutputBytesExact:true,logicalConsumedPrefixBound:true,backpressureAndCancel:true,originalTerminalActions:0,realPowerCommands:0};
      fs.writeFileSync(root+'/report.json',JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});console.log(JSON.stringify({passed:true,casesPerSide:report.casesPerSide,actualCompiledCore:true,physicalChunks:checks.reduce((sum,v)=>sum+(v.chunks??0),0),logicalRecords:checks.reduce((sum,v)=>sum+v.events,0)}));

  }finally{for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();for(const socket of sockets)socket.destroy();await new Promise(resolve=>server.close(resolve));}

verify();
console.log('PEER_STREAM_BUFFER actual Core cases 21; exact events/errors; retained bytes; bounded logical prefix; cancellation/backpressure');
