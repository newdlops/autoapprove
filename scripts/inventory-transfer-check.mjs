// Real Core inventory responses and native peer validation, synthetic originals only.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer,get,request} from 'node:http';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import {createHash,randomUUID} from 'node:crypto';
import {gunzipSync} from 'node:zlib';
import path from 'node:path';
const option=name=>process.argv.find(arg=>arg.startsWith('--'+name+'='))?.slice(name.length+3);
const binary=path.resolve(option('binary')||'dist/qa/stream-payload/StreamPayloadPreview');
const gatewayBinary=path.resolve(option('gateway-binary')||binary),ownerBinary=path.resolve(option('owner-binary')||binary);
const output=path.resolve(option('output')||'dist/qa/inventory-transfer.json'),baseline=process.argv.includes('--baseline');
await mkdir(path.dirname(output),{recursive:true});
const root=await mkdtemp('/private/tmp/aa-inventory-transfer-'),children=[],sockets=new Set(),checks=[],native=[];
let proxy;
const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
async function start(label,executable){
 const child=spawn(executable,[path.join(root,label),label,'--direct-only'],{stdio:['ignore','pipe','pipe']});children.push(child);let buffer='',error='',ready;
 child.stdout.on('data',part=>{buffer+=part;for(const line of buffer.split('\n'))if(line.startsWith('{'))try{const value=JSON.parse(line);if(value.url)ready=value;}catch{}});child.stderr.on('data',part=>error+=part);
 const end=performance.now()+20000;while(!ready&&child.exitCode===null&&child.signalCode===null&&performance.now()<end)await wait(20);
 assert.ok(ready,'Synthetic Core startup: '+error);return ready;
}
async function json(url,body){const response=await fetch(url,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(12000)});assert.equal(response.status,200);return response.json();}
function raw(url,headers={}){
 return new Promise((resolve,reject)=>{const req=get(url,{headers},res=>{const chunks=[];res.on('data',chunk=>chunks.push(chunk));res.on('error',reject);res.on('end',()=>{const body=Buffer.concat(chunks);resolve({status:res.statusCode,headers:res.headers,body});});});req.on('error',reject);req.setTimeout(10000,()=>req.destroy(new Error('Inventory read timeout')));});
}
const hash=body=>'"'+createHash('sha256').update(body).digest('hex')+'"';
try{
 const [gateway,owner]=await Promise.all([start('Gateway',gatewayBinary),start('Owner',ownerBinary)]),route=owner.url+'/api/inventory';
 const identity=await raw(route,{'Accept-Encoding':'identity'}),gzip=await raw(route,{'Accept-Encoding':'gzip'});
 assert.equal(identity.status,200);assert.equal(gzip.status,200);assert.equal(identity.headers['content-encoding'],undefined);
 assert.equal(identity.headers.etag,hash(identity.body));assert.equal(identity.headers['x-autoapprove-node'],owner.id);
 if(baseline){assert.equal(gzip.headers['content-encoding'],undefined);assert.deepEqual(gzip.body,identity.body);}
 else{
  assert.equal(gzip.headers['content-encoding'],'gzip');assert.equal(gzip.headers.etag,hash(gzip.body));assert.notEqual(gzip.headers.etag,identity.headers.etag);
  assert.deepEqual(gunzipSync(gzip.body),identity.body);assert.equal(Number(gzip.headers['content-length']),gzip.body.length);assert.ok(gzip.body.length<identity.body.length*0.7);
  for(const reply of [identity,gzip])assert.equal(reply.headers.vary,'Accept-Encoding');
 }
 checks.push('Strong ETags identify the exact selected wire bytes; decoded fields, Unicode and original node match');
 for(const [encoding,tag]of [['identity',identity.headers.etag],['gzip',gzip.headers.etag]]){
  for(const condition of [tag,'W/'+tag,'"another", '+tag,'*']){
   const same=await raw(route,{'Accept-Encoding':encoding,'If-None-Match':condition});assert.equal(same.status,304);assert.equal(same.body.length,0);assert.equal(same.headers.etag,tag);assert.equal(same.headers['x-autoapprove-node'],owner.id);assert.equal(same.headers['content-encoding'],undefined);assert.equal(same.headers['content-length'],undefined);if(!baseline)assert.equal(same.headers.vary,'Accept-Encoding');
  }
 }
 checks.push('Both representations return empty identity-pinned 304, including weak/list/star request validators');
 if(!baseline){
  for(const [encoding,tag]of [['identity',gzip.headers.etag],['gzip',identity.headers.etag]])assert.equal((await raw(route,{'Accept-Encoding':encoding,'If-None-Match':tag})).status,200);
  checks.push('Switching encoding never reuses a different strong representation');
 }
 for(const encoding of [undefined,'br','gzip;q=0, *;q=1']){
  const reply=await raw(route,encoding==null?{}:{'Accept-Encoding':encoding});assert.equal(reply.headers['content-encoding'],undefined);assert.deepEqual(reply.body,identity.body);assert.equal(reply.headers.etag,identity.headers.etag);
 }
 checks.push('Absent/unsupported/refused encoding keeps byte-identical legacy JSON and validator');
 for(const headers of [{'Origin':'http://unrelated.example'},{'X-AutoApprove-Node':randomUUID()}])assert.ok((await raw(route,{'Accept-Encoding':'gzip',...headers})).status>=400);
 checks.push('Compression does not bypass origin or original node validation');
 proxy=createServer((req,res)=>{
  if(req.url==='/api/discovery'){
   json(owner.url+'/api/discovery').then(value=>{const body=Buffer.from(JSON.stringify({...value,urls:[proxyURL],port:proxy.address().port}));res.writeHead(200,{'Content-Length':body.length,'Content-Type':'application/json',Connection:'close'});res.end(body);},()=>res.destroy());return;
  }
  const upstream=request(owner.url+req.url,{method:req.method,headers:{...req.headers,host:new URL(owner.url).host}},reply=>{
   const entry=req.url==='/api/inventory'?{status:reply.statusCode,encoding:reply.headers['content-encoding']||'identity',bytes:0,etag:reply.headers.etag,requestedTag:req.headers['if-none-match']||null,acceptEncoding:req.headers['accept-encoding']}:null;
   if(entry)native.push(entry);res.writeHead(reply.statusCode,reply.headers);reply.on('data',part=>{if(entry)entry.bytes+=part.length;});reply.on('error',()=>res.destroy());reply.pipe(res);
  });upstream.on('error',()=>res.destroy());res.once('close',()=>upstream.destroy());req.pipe(upstream);
 });
 proxy.on('connection',socket=>{sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});await new Promise(resolve=>proxy.listen(0,'127.0.0.1',resolve));
 const proxyURL='http://127.0.0.1:'+proxy.address().port;
 await json(gateway.url+'/api/peers',{address:proxyURL});
 async function dashboard(){const value=await json(gateway.url+'/api/network');const node=value.nodes.find(node=>node.id===owner.id);assert.ok(node?.online&&node.state);assert.equal(node.state.id,owner.id);return node.state;}
 const first=await dashboard();assert.ok(first.sessions.length);assert.equal(native.filter(row=>row.status===200).length,1);assert.equal(native[0].acceptEncoding,'gzip');assert.equal(native[0].encoding,baseline?'identity':'gzip');
 await wait(3200);const count=native.length;const repeated=await Promise.all(Array.from({length:16},dashboard));assert.equal(native.length-count,1);assert.equal(native.at(-1).status,304);assert.equal(native.at(-1).bytes,0);assert.equal(native.at(-1).requestedTag,native[0].etag);assert.deepEqual(repeated[0].sessions,first.sessions);
 checks.push('16 native dashboard readers share one conditional peer request and reuse only its matching empty 304');
 await json(gateway.url+'/api/action?node='+owner.id,{requestID:randomUUID(),action:'pause',paused:true});
 const changed=await dashboard();assert.equal(changed.snapshot.paused,true);assert.equal(native.at(-1).status,200);assert.notEqual(native.at(-1).etag,native[0].etag);assert.equal(native.at(-1).encoding,baseline?'identity':'gzip');
 checks.push('A real control change invalidates the peer body and publishes a fresh representation');
 const binarySHA256={gateway:createHash('sha256').update(await readFile(gatewayBinary)).digest('hex'),owner:createHash('sha256').update(await readFile(ownerBinary)).digest('hex')};
 const report={baseline,binarySHA256,plainBytes:identity.body.length,negotiatedBytes:gzip.body.length,native,checks,scope:'Actual Swift HTTP and native gateway with synthetic originals; raw response body bytes, not whole traffic or physical phone speed'};
 await writeFile(output,JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
}finally{
 for(const child of children)if(child.exitCode===null&&child.signalCode===null)child.kill();for(const socket of sockets)socket.destroy();
 if(proxy)await new Promise(resolve=>proxy.close(resolve));await Promise.all(children.map(child=>child.exitCode!==null||child.signalCode!==null?null:new Promise(resolve=>child.once('exit',resolve))));await rm(root,{recursive:true,force:true});
}
