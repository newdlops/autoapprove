// Protocol state recovery and asynchronous decompression ordering. Real
// workerd, native sockets and browser checks live in cloudflare-worker-check.
import assert from 'node:assert/strict';
import {gzipSync} from 'node:zlib';
import {TunnelRoom,packet,unpack} from '../Sources/AutoApproveCore/Resources/CloudflareRelay/relay.mjs';

class Socket{
  readyState=1;bufferedAmount=0;sent=[];
  constructor(attachment){this.attachment=attachment;}
  serializeAttachment(value){this.attachment=structuredClone(value);}
  deserializeAttachment(){return structuredClone(this.attachment);}
  send(value){this.sent.push(new Uint8Array(value));}
  close(){this.readyState=3;}
}
function context(connector,input=[]){return {getWebSockets:tag=>tag==='connector'?[connector]:tag==='input'?input:[],acceptWebSocket:()=>{throw Error('not needed in protocol-only test');}};}
function count(value){const bytes=new Uint8Array(4);new DataView(bytes.buffer).setUint32(0,value);return bytes;}
const checks=[];

const connector=new Socket({features:3}),browser=new Socket({id:73,credit:64000}),ctx=context(connector,[browser]);
let room=new TunnelRoom(ctx,{});
await room.webSocketMessage(browser,new Uint8Array(8).buffer);
assert.equal(unpack(connector.sent.at(-1).buffer).id,73);
assert.equal(browser.attachment.credit,63992);
room=new TunnelRoom(ctx,{});
for(let i=0;i<3;i++)await room.webSocketMessage(browser,new Uint8Array(16000).buffer);
assert.equal(browser.attachment.credit,15992);
await room.webSocketMessage(connector,packet(10,73,count(8)).buffer);
assert.equal(browser.attachment.credit,16000);
room=new TunnelRoom(ctx,{});
await room.webSocketMessage(browser,new Uint8Array(16000).buffer);
assert.equal(browser.attachment.credit,0);assert.equal(browser.readyState,1);
await room.webSocketMessage(browser,new Uint8Array(1).buffer);assert.equal(browser.readyState,3);
assert.equal(connector.sent.filter(value=>unpack(value.buffer).type===7).length,5);
checks.push('Hibernate-style reconstruction preserves browser IDs and exact upload credit across reconnectable state');

const upstream=new Socket({features:3}),live=new TunnelRoom(context(upstream),{});
const responsePromise=live.fetch(new Request('https://fixture.invalid/api/data'));
const request=unpack(upstream.sent.find(value=>unpack(value.buffer).type===1).buffer);
await live.webSocketMessage(upstream,packet(2,request.id,new TextEncoder().encode(JSON.stringify({status:200,headers:{'Content-Type':'application/octet-stream'}}))).buffer);
const response=await responsePromise,body=response.arrayBuffer();
const parts=Array.from({length:4},(_,i)=>new Uint8Array(32768).fill(65+i));
const pending=[];
for(const raw of parts){const packed=gzipSync(raw),payload=new Uint8Array(4+packed.length);payload.set(count(raw.length));payload.set(packed,4);pending.push(live.webSocketMessage(upstream,packet(9,request.id,payload).buffer));}
pending.push(live.webSocketMessage(upstream,packet(4,request.id).buffer));
await Promise.all(pending);
assert.deepEqual(new Uint8Array(await body),new Uint8Array(Buffer.concat(parts.map(value=>Buffer.from(value)))));
assert.equal(upstream.readyState,1);
checks.push('Back-to-back compressed frames and END retain byte order across asynchronous gzip decoding');

const brokenPromise=live.fetch(new Request('https://fixture.invalid/api/broken'));
const badRequest=unpack(upstream.sent.filter(value=>unpack(value.buffer).type===1).at(-1).buffer);
await live.webSocketMessage(upstream,packet(2,badRequest.id,new TextEncoder().encode(JSON.stringify({status:200,headers:{}}))).buffer);
const brokenResponse=await brokenPromise;const failure=brokenResponse.arrayBuffer().then(()=>false,()=>true);
const expanded=new Uint8Array(32768).fill(90),compressed=gzipSync(expanded),bomb=new Uint8Array(4+compressed.length);bomb.set(count(1));bomb.set(compressed,4);
await live.webSocketMessage(upstream,packet(9,badRequest.id,bomb).buffer);
assert.equal(await failure,true);assert.equal(upstream.readyState,1);
assert.ok(upstream.sent.some(value=>{const frame=unpack(value.buffer);return frame.type===5&&frame.id===badRequest.id;}));
checks.push('Declared decompression bounds reject an expanding payload and cancel only its request');

const old=new Socket({features:0}),legacy=new TunnelRoom(context(old),{});
const unavailable=await legacy.fetch(new Request('https://fixture.invalid/api/input/socket',{headers:{Upgrade:'websocket','Sec-WebSocket-Protocol':'autoapprove-input.v1'}}));
assert.equal(unavailable.status,426);assert.equal(old.sent.length,0);
for(const bytes of [new Uint8Array(),new Uint8Array([65,65,1,11,0,0,0,1]),new Uint8Array([65,65,1,7,0,0,0,0])])assert.throws(()=>unpack(bytes.buffer));
checks.push('Old connector capability negotiation keeps legacy HTTP input available; malformed kinds are rejected');
console.log(JSON.stringify({passed:true,checks,scope:'Protocol state and stream tests; native/browser/workerd integration is separately verified.'},null,2));
