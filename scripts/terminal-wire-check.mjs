// Matching release Core,synthetic values and the real browser receiver only.
// This check never reads,creates or inputs into a user's terminal session.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {coreLinkArguments,coreSwiftObjects} from './swift-core-link.mjs';

if(process.argv.includes('--help')){
  console.log('node scripts/terminal-wire-check.mjs [--v3] [--build=.build/release] [--source-root=.] [--cache=.build/module-cache] [--output=NEW_DIRECTORY]');
  console.log('Build the matching release Core first. Uses xcrun/swiftc and Node;no browser install or private fixture data is required.');
  process.exit(0);
}
const option=(name,fallback)=>process.argv.find(value=>value.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const version=process.argv.includes('--v3')?3:2;
const sourceRoot=path.resolve(option('source-root',fileURLToPath(new URL('..',import.meta.url)))),build=path.resolve(option('build',sourceRoot+'/.build/release'));
const parent=sourceRoot+'/.runtime/terminal-wire-check';
const output=option('output',null);let out;
if(output){out=path.resolve(output);fs.mkdirSync(out,{mode:0o700})}else{fs.mkdirSync(parent,{recursive:true,mode:0o700});out=fs.mkdtempSync(parent+'/run-')}
const cache=path.resolve(option('cache',sourceRoot+'/.build/module-cache')),sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const fixture=sourceRoot+'/Tests/fixtures/terminal-wire-check.swift',web=sourceRoot+'/Sources/AutoApproveCore/Resources/RemoteWeb';
const objects=await coreSwiftObjects(build),links=await coreLinkArguments(build);
assert.ok(objects.some(file=>path.basename(file)==='RemoteTerminalWire.swift.o'),'Build the matching wire2 Core first');
const inputs=Object.fromEntries([fixture,fileURLToPath(import.meta.url),fileURLToPath(new URL('./swift-core-link.mjs',import.meta.url)),sourceRoot+'/Sources/AutoApproveCore/RemoteTerminalWire.swift',sourceRoot+'/Sources/AutoApproveCore/RemoteTerminalStream.swift',web+'/terminal-wire.js',web+'/pty.js',build+'/AutoApproveCore.build/output-file-map.json',build+'/Modules/AutoApproveCore.swiftmodule',...objects,...links.filter(file=>file.endsWith('.o'))].map(file=>[file,sha(file)]));
const verify=()=>{for(const[file,digest]of Object.entries(inputs))assert.equal(sha(file),digest,file)};
async function job(name,command,args,input){
  verify();const stdout=fs.openSync(out+'/'+name+'.stdout','wx',0o600),stderr=fs.openSync(out+'/'+name+'.stderr','wx',0o600),child=spawn(command,args,{stdio:[input?'pipe':'ignore',stdout,stderr]});
  if(input)child.stdin.end(input);
  const result=await new Promise((resolve,reject)=>{child.once('error',reject);child.once('exit',(code,signal)=>resolve({code,signal}))});fs.closeSync(stdout);fs.closeSync(stderr);
  fs.writeFileSync(out+'/'+name+'-job.json',JSON.stringify(result)+'\n',{flag:'wx',mode:0o600});assert.equal(result.code,0,fs.readFileSync(out+'/'+name+'.stderr','utf8').slice(-5000));assert.equal(result.signal,null);verify();return fs.readFileSync(out+'/'+name+'.stdout','utf8');
}
// Release optimization need not retain externally callable internal encoder
// symbols. Compile its exact source,without a test-only product API or patch.
const encoderSource=sourceRoot+'/Sources/AutoApproveCore/RemoteTerminalWire.swift';
const encoderCopy=out+'/encoder.swift';
fs.writeFileSync(encoderCopy,'import AutoApproveCore\n'+fs.readFileSync(encoderSource,'utf8'),{flag:'wx',mode:0o600});
assert.equal(fs.readFileSync(encoderCopy,'utf8').slice('import AutoApproveCore\n'.length),fs.readFileSync(encoderSource,'utf8'));
inputs[encoderCopy]=sha(encoderCopy);
await job('compile','/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-Xfrontend','-disable-access-control','-module-cache-path',cache,'-I',build+'/Modules','-I',sourceRoot+'/Sources/CSQLite','-lsqlite3',...links,...objects,encoderCopy,fixture,'-o',out+'/worker']);
const rows=(await job('emit',out+'/worker',version===3?['--v3']:[])).trim().split('\n').map(JSON.parse),metadata=rows.shift();
const protocolFields=['sessionID','screen','revision','observedAt','keys','inputReason','appearance','cursor','streamID','nativeDisplay','outputReason','sequence','question','screenPatch','screenCopy','appearanceUnchanged','ptyID','offset','data','reset','columns','rows','exitCode','canInput'];
assert.equal(metadata.exactProductEncoderSource,true);assert.equal(metadata.oversizedRejected,true);assert.equal(metadata.version,version);assert.deepEqual(metadata.fields,protocolFields);assert.ok(version===3?rows.length>3000:rows.length===630);
const window={},context=vm.createContext({window,TextDecoder,TextEncoder,Uint8Array,DataView,BigInt,Number,Map,Set,URL,location:{href:'http://127.0.0.1/'},atob,btoa});
vm.runInContext(fs.readFileSync(web+'/terminal-wire.js','utf8'),context,{filename:'terminal-wire.js'});
vm.runInContext('window.qaPlain=value=>{if(value&&typeof value==="object"&&!(value instanceof Uint8Array)){if(!Array.isArray(value)&&Object.getPrototypeOf(value)!==Object.prototype)throw Error("Unexpected object prototype");for(const key of Object.keys(value))window.qaPlain(value[key]);}}',context);
const codec=window.AutoApproveTerminalWire,normal=value=>JSON.parse(JSON.stringify(value,(_key,item)=>item instanceof Uint8Array?Buffer.from(item).toString('base64'):item));
const decode=(bytes,raw=false,wireVersion=version)=>{const result=[],parser=new codec.Parser(raw,wireVersion);parser.push(bytes,event=>result.push(event));parser.finish();return result};
const representatives=new Map(),groups=new Map();let rawCopies=0;
for(const row of rows){
  const bytes=Buffer.from(row.binary,'base64'),expected={type:row.event,value:JSON.parse(Buffer.from(row.json,'base64').toString())};
  if(version===3)assert.deepEqual(normal(decode(Buffer.from(row.v2,'base64'),false,2)),[expected],row.case+' v2 reference');
  for(const raw of [false,true]){
    const result=decode(bytes,raw);assert.deepEqual(normal(result),[expected],row.case);window.qaPlain(result[0].value);
    const data=result[0].value.data;if(data instanceof Uint8Array){assert.equal(raw,true);assert.equal(row.event,'output');assert.equal(data.byteOffset,0);assert.equal(data.buffer.byteLength,data.byteLength);const before=Buffer.from(data),input=Buffer.from(bytes),owned=decode(input,true)[0].value.data;input.fill(0);assert.deepEqual(Buffer.from(owned),before);rawCopies++;}
  }
  const sse=new codec.SSEParser(),events=[];sse.push(Buffer.from(row.sse,'base64'),event=>events.push(event));sse.finish();assert.equal(events.length,1);assert.equal(events[0].type,row.event);assert.deepEqual(JSON.parse(events[0].data),expected.value);
  if(!row.case.startsWith('bound-')){if(!representatives.has(row.case))representatives.set(row.case,bytes);if(!groups.has(row.case))groups.set(row.case,{legacy:[],binary:[],v2:[]});groups.get(row.case).legacy.push(row.sse);groups.get(row.case).binary.push(row.binary);if(version===3)groups.get(row.case).v2.push(row.v2);assert.equal(bytes[3]&128,0);}
}
assert.equal(representatives.size,version===3?10:9);assert.ok(rawCopies>0);
let splitChecks=0;
for(const bytes of representatives.values())for(const raw of [false,true]){
  const expected=normal(decode(bytes,raw));
  for(let split=0;split<=bytes.length;split++){const parser=new codec.Parser(raw,version),events=[];parser.push(bytes.subarray(0,split),event=>events.push(event));parser.push(bytes.subarray(split),event=>events.push(event));parser.finish();assert.deepEqual(normal(events),expected);splitChecks++;}
  const parser=new codec.Parser(raw,version),events=[];for(const byte of bytes)parser.push(Uint8Array.of(byte),event=>events.push(event));parser.finish();assert.deepEqual(normal(events),expected);
}
const samples=[...representatives.values()],joined=Buffer.concat(samples);
for(const width of [1,3,7,14,31,1024,32749]){const parser=new codec.Parser(true,version),events=[];for(let i=0;i<joined.length;i+=width)parser.push(joined.subarray(i,i+width),event=>events.push(event));parser.finish();assert.equal(events.length,samples.length);}
let cancelled=0;new codec.Parser(true,version).push(joined,()=>{cancelled++;return false});assert.equal(cancelled,1);
const heartbeat=Buffer.from(metadata.heartbeat,'base64');assert.deepEqual([...heartbeat],[65,65,version,4,0]);new codec.Parser(false,version).push(heartbeat,()=>assert.fail('Heartbeat dispatched as data'));
const variable=value=>{value=BigInt(value);const result=[];do{const byte=Number(value&127n);value>>=7n;result.push(byte|(value?128:0))}while(value);return result};
const envelope=body=>Buffer.from([65,65,version,0,...variable(body.length),...body]),integer=(value,negative)=>envelope([0,8,0,0,0x3f+(negative?16:0),...variable(value),0]);
let integerChecks=0;
for(const value of [0n,1n,14n,15n,127n,128n,16383n,16384n,2147483647n,2147483648n,4294967295n,4294967296n,2n**42n,2n**49n,2n**53n-2n,2n**53n-1n,2n**53n,2n**63n-1n,2n**64n-1n])for(const negative of [false,true]){
  const bytes=integer(value,negative),signed=negative?-value-1n:value,safe=signed>=BigInt(Number.MIN_SAFE_INTEGER)&&signed<=BigInt(Number.MAX_SAFE_INTEGER);if(safe)assert.equal(decode(bytes)[0].value.sequence,Number(signed));else assert.throws(()=>decode(bytes));integerChecks++;
}
const malformed=[Buffer.from([65,65,version===3?2:3,4,0]),Buffer.from([65,65,version,5,0]),Buffer.from([65,65,version,4,1,0]),Buffer.from([65,65,version,4,128,0]),Buffer.from([65,65,version,0,129,137,122]),envelope([0,8,0,0,0x3f,128,0,0]),envelope([0,8,0,0,0x3f,...Array(10).fill(255),0]),envelope([0,8,0,0,...Array(66).fill(0x71),0,0]),envelope([0,0,0,1,0]),envelope([0,8,0,0,0x7f,...variable(100001),0])];
if(version===3){
 const profile=bytes=>envelope([0,0,0,0,1,0x61,120,...bytes]);
 for(const kind of [6,7,8,9,10,11,12,13,14,15])malformed.push(profile([0x50|kind]));
 for(const flags of [12,16,255])malformed.push(profile([0x52,flags,0,0]));
 for(const flags of [4,128,255])malformed.push(profile([0x53,flags,0]));
 for(const flags of [512,1024,32768,65536,2**32])malformed.push(profile([0x51,0,1,...variable(flags)]));
 malformed.push(profile([0x53,0,...variable(8001)]),profile([0x52,0,128,0,0]),profile([0x54,0x30]),profile([0x55,0x10]));
}
for(const bytes of malformed)assert.throws(()=>decode(bytes));
let prefixes=0;for(let size=1;size<samples[7].length;size++){assert.throws(()=>decode(samples[7].subarray(0,size),true));prefixes++;}
const text=value=>{const bytes=Buffer.from(value);return [...(bytes.length<15?[0x60|bytes.length]:[0x6f,...variable(bytes.length)]),...bytes]},names=['__proto__','constructor','toString','hasOwnProperty'];
const tricky=decode(envelope([0,0,0,0,4,...names.flatMap(name=>[...text(name),0x31])]))[0].value;window.qaPlain(tricky);for(const name of names){assert.equal(Object.hasOwn(tricky,name),true);assert.equal(tricky[name],1);assert.equal(Object.getOwnPropertyDescriptor(tricky,name).writable,true);}
assert.throws(()=>decode(envelope([0,0,0,0,2,...text('__proto__'),0x31,...text('__proto__'),0x32])));
const legacy=Buffer.from('\uFEFF: comment\r\nid: one\revent: screen\ndata: {"value":\r\ndata: "한글 🧪"}\r\n\r\n');
for(let split=0;split<=legacy.length;split++){const parser=new codec.SSEParser(),events=[];parser.push(legacy.subarray(0,split),event=>events.push(event));parser.push(legacy.subarray(split),event=>events.push(event));parser.finish();assert.equal(events.length,1);assert.deepEqual(JSON.parse(events[0].data),{value:'한글 🧪'});assert.equal(events[0].lastEventId,'one');}

vm.runInContext(fs.readFileSync(web+'/pty.js','utf8'),context,{filename:'pty.js'});
const tick=async()=>{await Promise.resolve();await Promise.resolve()};
for(const raw of [false,true]){
  const instance=Object.create(window.AutoApprovePTY.prototype),pending=[];
  Object.assign(instance,{descriptor:{streamID:'s',ptyID:'p'},maxOutputBytes:32,maxSnapshotBytes:64,maxOutputEvents:64,outputQueue:[],outputBytes:0,writing:false,disposed:false,blocked:false,streaming:true,queue:[],offset:null,term:{options:{},reset(){},write(bytes,done){pending.push({bytes,done})}},closeStream(){this.closed=(this.closed||0)+1},openStream(){this.opened=(this.opened||0)+1},report(){}});
  const data=Uint8Array.of(27,91,51,49,109,65),packet=(offset,reset)=>({streamID:'s',ptyID:'p',offset,reset,data:raw?data:Buffer.from(data).toString('base64')});
  instance.receive(packet(6,true));assert.equal(instance.offset,null);assert.deepEqual([...pending[0].bytes],[...data]);instance.receive(packet(12,false));pending.shift().done();await tick();assert.equal(instance.offset,6);pending.shift().done();await tick();assert.equal(instance.offset,12);assert.equal(instance.outputBytes,0);assert.equal(instance.ready,true);
  assert.throws(()=>instance.receive({...packet(18,false),streamID:'wrong'}));assert.throws(()=>instance.receive({...packet(18,false),offset:2**53}));assert.throws(()=>instance.receive({...packet(18,false),data:raw?new Uint8Array(33):Buffer.alloc(33).toString('base64')}));
  instance.receive({...packet(42,false),data:raw?new Uint8Array(30):Buffer.alloc(30).toString('base64')});instance.receive(packet(48,false));assert.equal(instance.outputPaused,true);assert.equal(instance.outputQueue.length,0);assert.equal(instance.closed,1);pending.shift().done();await tick();assert.equal(instance.offset,42);assert.equal(instance.opened,1);assert.equal(instance.outputBytes,0);
}
const gzipRequests=[];for(const[name,group]of groups)for(const side of version===3?['legacy','binary','v2']:['legacy','binary'])gzipRequests.push({name:name+'/'+side,frames:group[side]});
const compressed=(await job('gzip',out+'/worker',['gzip'],gzipRequests.map(row=>JSON.stringify(row)+'\n').join(''))).trim().split('\n').map(JSON.parse);
const compression=[];for(const[name,group]of groups){const before=compressed.find(row=>row.name===name+'/legacy'),after=compressed.find(row=>row.name===name+'/binary'),v2=compressed.find(row=>row.name===name+'/v2');compression.push({name,sseGzipBytes:before.streamBytes,binaryGzipBytes:after.streamBytes,ratio:after.streamBytes/before.streamBytes,...(v2?{v2GzipBytes:v2.streamBytes,v3vsV2:after.streamBytes/v2.streamBytes,rawV2Bytes:group.v2.reduce((n,s)=>n+Buffer.from(s,'base64').length,0),rawV3Bytes:group.binary.reduce((n,s)=>n+Buffer.from(s,'base64').length,0)}:{})});}
assert.ok(compression.every(row=>row.ratio<=1.05),'Normal wire streams exceed the SSE gzip byte budget');verify();
if(version===3)assert.ok(compression.every(row=>row.v3vsV2<=1.01),'Compact schema exceeds the existing gzip byte budget');
const report={passed:true,version,inputs,coreObjects:objects.length,actualCompiledCoreEncoder:false,exactProductEncoderSourceCompiled:true,encoderSourceBodyUnchanged:true,terminalDTOAndGzipFromLinkedCore:true,terminalDTORecompiled:false,frames:rows.length,normalFrames:rows.filter(row=>!row.case.startsWith('bound-')).length,boundaryFrames:rows.filter(row=>row.case.startsWith('bound-')).length,rawCopies,rawCopiesOwnExactStorage:true,splitChecks,integerChecks,malformedRejected:malformed.length,truncatedPrefixes:prefixes,sseSplitChecks:legacy.length+1,cancelStopsDispatch:true,actualPTYReceiveAndRenderOffsetChecks:true,queueLimitsAndBackpressurePreserved:true,compression,browserRuntime:'Node VM only;actual Core transport,real-browser and physical-device checks are separate.',originalTerminalActions:0,realPowerCommands:0};
fs.writeFileSync(out+'/report.json',JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
console.log(JSON.stringify({passed:true,coreObjects:objects.length,exactProductEncoderSourceCompiled:true,terminalDTOAndGzipFromLinkedCore:true,frames:rows.length,rawCopies,splitChecks,integerChecks,malformedRejected:malformed.length,sseSplitChecks:legacy.length+1,compression,report:out+'/report.json'}));
