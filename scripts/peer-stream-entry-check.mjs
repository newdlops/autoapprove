// Real production stream class + release Core, with synthetic loopback-only
// upstream events. No original CLI, installed app, profile or input is used.
import assert from 'node:assert/strict';
import {execFileSync,spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {createHash,randomUUID} from 'node:crypto';
import {gzipSync} from 'node:zlib';
import {mkdir,readFile,readdir,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {coreLinkArguments} from './swift-core-link.mjs';

const option=(name,fallback)=>process.argv.find(v=>v.startsWith('--'+name+'='))?.slice(name.length+3)??fallback;
const out=path.resolve(option('output','.runtime/peer-stream-entry/current'));
const build=path.resolve('.build/release'),cache=path.resolve('.build/cache/PeerStreamEntry');
await mkdir(out,{recursive:true,mode:0o700});await mkdir(cache,{recursive:true});
const source=await readFile('Sources/AutoApproveCore/RemotePTYStream.swift','utf8');
let implementation=source.slice(source.indexOf('final class RemotePTYPeerBodyStream:'));
assert.ok(implementation.startsWith('final class RemotePTYPeerBodyStream:'));
const primed=implementation.includes('CheckedContinuation<Data, Error>');
let instrumented=false;
for(const [search,replacement]of [
 ['buffer.range(of: Data("\\n\\n".utf8))','probeBoundary(buffer,range:buffer.startIndex..<buffer.endIndex)'],
 ['buffer.range(of: Self.eventBoundary, in: searchRange)','probeBoundary(buffer,range:searchRange)']
])if(implementation.includes(search)){implementation=implementation.replace(search,replacement);instrumented=true;break;}
assert.ok(instrumented,'Instrument the actual production delimiter search, never a substitute parser');
const fixture=(await readFile('Tests/fixtures/peer-stream-entry.swift','utf8')).replace('// PROBE_OPEN',primed?
 'let initial = try await stream.open()':'try await stream.open(); let initial = Data()');
const generated=path.join(out,'PeerStreamEntryProbe.swift'),binary=path.join(out,'PeerStreamEntryProbe');
await writeFile(generated,fixture+'\n'+implementation);
const objects=(await readdir(path.join(build,'AutoApproveCore.build'))).filter(v=>v.endsWith('.swift.o')).map(v=>path.join(build,'AutoApproveCore.build',v));
execFileSync('/usr/bin/xcrun',['swiftc','-O','-parse-as-library','-module-cache-path',cache,'-I',path.join(build,'Modules'),'-I',path.resolve('Sources/CSQLite'),'-lsqlite3',...await coreLinkArguments(build),...objects,generated,'-o',binary],{stdio:'inherit',timeout:300000});
const sha=value=>createHash('sha256').update(value).digest('hex');
await writeFile(path.join(out,'provenance.json'),JSON.stringify({sourceSHA256:sha(source),fixtureSHA256:sha(fixture),binarySHA256:sha(await readFile(binary)),primed},null,2)+'\n');
const id=randomUUID(),sockets=new Set(),children=[],checks=[];
const event=(screen,revision='fixture')=>Buffer.from('event: screen\nid: '+revision+'\ndata: '+JSON.stringify({sessionID:'synthetic + 한글',streamID:'same-original',screen,revision,keys:['characters','enter'],observedAt:'2026-10-18T00:00:00Z'})+'\n\n');
const small=event('원본🙂 é\n› 입력'),large=event('합성 화면\n'+'x'.repeat(1_800_000)),second=event('다음 화면','second');
const server=createServer((req,res)=>{
 const kind=new URL(req.url,'http://localhost').searchParams.get('case');
 assert.equal(req.method,'GET');assert.equal(req.headers['x-autoapprove-node'],id);
 res.useChunkedEncodingByDefault=false;
 res.writeHead(200,{'Content-Type':'text/event-stream','X-AutoApprove-Node':kind==='identity'?randomUUID():id,'Connection':'close',...(kind.startsWith('gzip')?{'Content-Encoding':'gzip'}:{})});
 let bytes=small;
 if(kind==='gzip-large')bytes=gzipSync(large,{level:1});
 else if(kind==='gzip-two')bytes=gzipSync(Buffer.concat([small,second]),{level:1});
 else if(kind.startsWith('gzip')){bytes=gzipSync(small);if(kind==='gzip-corrupt'){bytes=Buffer.from(bytes);bytes[bytes.length-5]^=255;}if(kind==='gzip-truncated')bytes=bytes.subarray(0,bytes.length-5);}
 if(kind==='oversized')bytes=Buffer.from('event: screen\ndata: '+'x'.repeat(2_000_129));
 if(kind==='header-only'){
  res.flushHeaders();const timer=setTimeout(()=>res.end(bytes),250);res.once('close',()=>clearTimeout(timer));return;
 }
 if(kind==='fragmented'){
  res.write(bytes.subarray(0,bytes.length-1));const timer=setTimeout(()=>res.end(bytes.subarray(bytes.length-1)),30);res.once('close',()=>clearTimeout(timer));return;
 }
 if(kind==='multiple')bytes=Buffer.concat([Buffer.from(': keepalive\n\n'),small,second]);
 res.end(bytes);
});
server.on('connection',socket=>{sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const base='http://127.0.0.1:'+server.address().port;
async function probe(kind){return new Promise((resolve,reject)=>{
 const child=spawn(binary,[base,id,kind],{stdio:['ignore','pipe','pipe']});children.push(child);let stdout='',stderr='';
 child.stdout.on('data',p=>stdout+=p);child.stderr.on('data',p=>stderr+=p);const timer=setTimeout(()=>child.kill(),10000);
 child.on('error',reject);child.on('exit',code=>{clearTimeout(timer);if(code!==0)reject(new Error(stderr||'Probe exit '+code));else try{resolve(JSON.parse(stdout));}catch(error){reject(error);}});
});}
try{
 for(const kind of ['plain','gzip','fragmented','header-only','multiple','gzip-two','gzip-large','gzip-corrupt','gzip-truncated','oversized','identity']){
  const result=await probe(kind);
  const frames=kind==='multiple'?[Buffer.from(': keepalive\n\n'),small,second]:kind==='gzip-two'?[small,second]:kind==='gzip-large'?[large]:[small];
  if(['gzip-corrupt','gzip-truncated','oversized','identity'].includes(kind)){
   assert.equal(result.errorStatus,kind==='oversized'||kind==='identity'?502:503);
   if(kind==='identity')assert.equal(result.openMS,undefined,'A wrong node fails before successful opening');
   else assert.equal(typeof result.openMS,'number','Authenticated headers open successfully; body faults remain stream failures after HTTP 200');
   for(const e of result.events)assert.ok(e.bytes===small.length&&e.sha256===sha(small),'Never emit partial JSON, including a corrupt/truncated compressed event');
  }else{
   assert.equal(result.errorStatus,undefined);
   assert.deepEqual(result.events,frames.map(bytes=>({bytes:bytes.length,sha256:sha(bytes)})),'Preserve exact SSE boundaries, order and Unicode bytes');
   if(kind==='fragmented')assert.equal(result.initialBytes,0,'A split final newline is not an initial event');
   if(kind==='header-only'){assert.equal(result.initialBytes,0);assert.ok(result.openMS<200,'Do not delay headers while awaiting an unavailable first event');}
  }
  checks.push({kind,...result});
 }
 const report={result:'PASS',checks,scope:'Instrumented actual production peer stream plus release Core, real loopback sockets, synthetic content. Search bytes measure delimiter work, not network bytes or whole app CPU.'};
 await writeFile(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n',{mode:0o600});
 console.log(JSON.stringify(report,null,2));
 if(process.argv.includes('--assert-efficient')){
  assert.ok(checks.find(x=>x.kind==='plain').initialBytes===small.length,'A ready first event must accompany the authenticated headers, without a second downstream send');
  assert.ok(checks.find(x=>x.kind==='gzip-large').search.bytes<=large.length*3,'Fragmented/decompressed events must not repeatedly scan already inspected screen bytes');
 }
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();for(const socket of sockets)socket.destroy();
 await new Promise(resolve=>server.close(resolve));
}
