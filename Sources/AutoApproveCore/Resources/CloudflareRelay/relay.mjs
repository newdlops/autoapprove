// HTTP/SSE relay only. Browser authorization stays in the Mac gateway.
const LIMIT=32, BODY=2_000_000, BUDGET=8_000_000, WINDOW=262144, CHUNK=32768;
const REQUEST=1, HEADERS=2, DATA=3, END=4, CANCEL=5, CREDIT=6, HELLO=0;
const SOCKET_DATA=7,SOCKET_CLOSE=8,COMPRESSED_DATA=9,SOCKET_CREDIT=10,SOCKET_WINDOW=64000,SOCKET_MESSAGE=16009;
const encoder=new TextEncoder(),decoder=new TextDecoder('utf-8',{fatal:true});
export function packet(type,id,payload=new Uint8Array()) {
  const out=new Uint8Array(8+payload.byteLength),view=new DataView(out.buffer);
  out.set([65,65,1,type]);view.setUint32(4,id);out.set(payload,8);return out;
}
export function unpack(value) {
  if(typeof value==='string')throw Error('binary required');
  const bytes=new Uint8Array(value);
  if(bytes.length<8||bytes.length>BODY+32780||bytes[0]!==65||bytes[1]!==65||bytes[2]!==1)throw Error('invalid packet');
  const type=bytes[3],id=new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength).getUint32(4);
  if(type>10||(id===0)!==(type===HELLO))throw Error('invalid kind');
  return {type,id,payload:bytes.subarray(8)};
}
const error=status=>new Response(status===503?'Mac이 연결되어 있지 않습니다.':'연결 요청을 처리하지 못했습니다.',{status,headers:{'Cache-Control':'no-store','Content-Type':'text/plain; charset=utf-8'}});
const hop=new Set(['connection','upgrade','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','transfer-encoding','content-length']);
function amount(value){const bytes=new Uint8Array(4);new DataView(bytes.buffer).setUint32(0,value);return bytes;}
async function inflate(payload,expected){
  const reader=new Response(payload.subarray(4)).body.pipeThrough(new DecompressionStream('gzip')).getReader();
  const chunks=[];let size=0;
  try{while(true){const {done,value}=await reader.read();if(done)break;size+=value.byteLength;if(size>expected)throw Error('inflate bound');chunks.push(value);}
    if(size!==expected)throw Error('inflate length');const result=new Uint8Array(size);let at=0;for(const chunk of chunks){result.set(chunk,at);at+=chunk.byteLength;}return result;
  }finally{await reader.cancel().catch(()=>{});reader.releaseLock();}
}
function headersObject(headers) {
  return Object.fromEntries([...headers].filter(([key])=>!hop.has(key.toLowerCase())));
}
async function authorized(request,expected) {
  const value=request.headers.get('Authorization')||'';
  if(!/^Bearer [A-Za-z0-9_-]{43}$/.test(value)||!/^[a-f0-9]{64}$/.test(expected||''))return false;
  const digest=await crypto.subtle.digest('SHA-256',encoder.encode(value.slice(7)));
  const actual=Array.from(new Uint8Array(digest),v=>v.toString(16).padStart(2,'0')).join('');
  let difference=0;for(let i=0;i<64;i++)difference|=actual.charCodeAt(i)^expected.charCodeAt(i);
  return difference===0;
}
export default {
  async fetch(request,env) {
    const url=new URL(request.url);
    if(url.hostname!==env.PUBLIC_HOST)return error(403);
    if(url.protocol!=='https:')return Response.redirect('https://'+env.PUBLIC_HOST+url.pathname+url.search,308);
    return env.TUNNEL.get(env.TUNNEL.idFromName('gateway')).fetch(request);
  }
};
export class TunnelRoom {
  constructor(ctx,env) {
    this.ctx=ctx;this.env=env;this.pending=new Map();this.counter=0;this.bodyBytes=0;
    this.socket=ctx.getWebSockets('connector').find(socket=>socket.readyState===1)||null;
    this.features=this.socket?.deserializeAttachment()?.features||0;
    // Browser socket attachments survive Durable Object hibernation. HTTP
    // responses keep their normal in-memory stream and credit ownership.
    for(const socket of ctx.getWebSockets('input')){
      const saved=socket.deserializeAttachment();
      if(!saved||!Number.isInteger(saved.id)||saved.id<=0||saved.id>0xffffffff||!Number.isInteger(saved.credit)||saved.credit<0||saved.credit>SOCKET_WINDOW||this.pending.has(saved.id)){try{socket.close(1011,'closed');}catch{};continue;}
      this.pending.set(saved.id,{ws:true,started:true,socket,uploadCredit:saved.credit,timer:null});this.counter=Math.max(this.counter,saved.id);
    }
  }
  send(type,id,payload) {
    if(!this.socket||this.socket.readyState!==1||this.socket.bufferedAmount>4_000_000)throw Error('unavailable');
    this.socket.send(packet(type,id,payload));
  }
  discard(id,status=502,notify=true) {
    const pending=this.pending.get(id);if(!pending)return;
    this.pending.delete(id);clearTimeout(pending.timer);
    pending.reader?.cancel().catch(()=>{});
    if(pending.ws&&pending.socket){try{pending.socket.close(1011,'closed');}catch{}}
    if(!pending.started)pending.resolve(error(status));
    else {try {pending.controller?.error(Error('연결이 종료됐습니다.'));}catch{}}
    if(notify){try{this.send(pending.ws?SOCKET_CLOSE:CANCEL,id);}catch{}}
  }
  disconnected() {for(const id of [...this.pending.keys()])this.discard(id,503,false);}
  credit(id) {
    const pending=this.pending.get(id);
    if(!pending?.controller)return;
    const available=Math.max(0,Math.min(WINDOW,Math.floor(pending.controller.desiredSize||0)-(pending.deliveryBytes||0)));
    const amount=available-pending.credit;
    if(amount>=CHUNK||amount>0&&pending.credit===0){
      const bytes=new Uint8Array(4);new DataView(bytes.buffer).setUint32(0,amount);
      try{this.send(CREDIT,id,bytes);pending.credit+=amount;}catch{this.discard(id,503,false);}
    }
  }
  async fetch(request) {
    const url=new URL(request.url);
    if(url.pathname==='/_autoapprove/connector') {
      if(request.headers.get('Upgrade')?.toLowerCase()!=='websocket')return error(426);
      if(!await authorized(request,this.env.CONNECTOR_HASH))return error(403);
      this.disconnected();
      if(this.socket){try{this.socket.close(1001,'replaced');}catch{}}
      const pair=new WebSocketPair(),[client,server]=Object.values(pair);
      this.features=request.headers.get('X-AutoApprove-Relay')==='2'?3:0;
      this.ctx.acceptWebSocket(server,['connector']);server.serializeAttachment({features:this.features});this.socket=server;
      server.send(packet(HELLO,0,new Uint8Array(this.features?[1,this.features]:[1])));
      return new Response(null,{status:101,webSocket:client});
    }
    if(!this.socket||this.socket.readyState!==1)return error(503);
    if(request.signal?.aborted)return error(499);
    if(this.pending.size>=LIMIT)return error(503);
    if(!['GET','POST','HEAD','OPTIONS'].includes(request.method))return error(405);
    const isSocket=request.headers.get('Upgrade')?.toLowerCase()==='websocket';
    if(isSocket&&(url.pathname!=='/api/input/socket'||request.method!=='GET'||!(this.features&1)||!request.headers.get('Sec-WebSocket-Protocol')?.split(',').map(value=>value.trim()).includes('autoapprove-input.v1')))return error(426);
    do{this.counter=(this.counter+1)>>>0;}while(this.counter===0||this.pending.has(this.counter));
    const id=this.counter;
    let resolve;const response=new Promise(done=>{resolve=done;});
    const pending={resolve,started:false,controller:null,credit:0,reader:null,method:request.method,ws:isSocket,deliveryBytes:0,
      timer:setTimeout(()=>this.discard(id,504),45000)};
    this.pending.set(id,pending);
    if(!isSocket)request.signal?.addEventListener('abort',()=>this.discard(id,499),{once:true});
    let held=0;
    try {
      const chunks=[];
      if(request.body){
        pending.reader=request.body.getReader();
        while(true){
          const {done,value}=await pending.reader.read();if(done)break;
          if(held+value.byteLength>BODY||this.bodyBytes+value.byteLength>BUDGET){this.discard(id,413);return await response;}
          chunks.push(value);held+=value.byteLength;this.bodyBytes+=value.byteLength;
        }
        pending.reader=null;
      }
      if(this.pending.get(id)!==pending)return await response;
      const metadata=encoder.encode(JSON.stringify({method:request.method,path:url.pathname+url.search,headers:headersObject(request.headers),...(isSocket?{socket:true}:{})}));
      if(metadata.length>32768){this.discard(id,431);return await response;}
      const payload=new Uint8Array(4+metadata.length+held);new DataView(payload.buffer).setUint32(0,metadata.length);
      payload.set(metadata,4);let offset=4+metadata.length;
      for(const chunk of chunks){payload.set(chunk,offset);offset+=chunk.byteLength;}
      this.send(REQUEST,id,payload);
    } catch {this.discard(id,503);}
    finally{this.bodyBytes-=held;}
    return await response;
  }
  async webSocketMessage(socket,value) {
    if(socket!==this.socket){
      const saved=socket.deserializeAttachment(),pending=this.pending.get(saved?.id);
      if(!pending?.ws||pending.socket!==socket)return;
      try{
        if(typeof value==='string')throw Error('binary');const bytes=new Uint8Array(value);
        if(bytes.byteLength>SOCKET_MESSAGE||bytes.byteLength>pending.uploadCredit)throw Error('socket window');
        pending.uploadCredit-=bytes.byteLength;socket.serializeAttachment({id:saved.id,credit:pending.uploadCredit});
        this.send(SOCKET_DATA,saved.id,bytes);
      }catch{this.discard(saved.id,502);}
      return;
    }
    try {
      const frame=unpack(value),pending=this.pending.get(frame.id);
      if(!pending)return;
      if(frame.type===HEADERS){
        if(pending.started||frame.payload.byteLength>32768)throw Error('headers');
        const metadata=JSON.parse(decoder.decode(frame.payload));
        if(pending.ws){
          if(metadata.status!==101){this.discard(frame.id,503);return;}
          const pair=new WebSocketPair(),[client,server]=Object.values(pair);
          this.ctx.acceptWebSocket(server,['input']);server.serializeAttachment({id:frame.id,credit:SOCKET_WINDOW});
          pending.started=true;pending.socket=server;pending.uploadCredit=SOCKET_WINDOW;clearTimeout(pending.timer);
          pending.resolve(new Response(null,{status:101,headers:{'Sec-WebSocket-Protocol':'autoapprove-input.v1'},webSocket:client}));return;
        }
        if(!Number.isInteger(metadata.status)||metadata.status<200||metadata.status>599||!metadata.headers||typeof metadata.headers!=='object')throw Error('status');
        const headers=new Headers(metadata.headers);for(const name of hop)headers.delete(name);
        pending.started=true;clearTimeout(pending.timer);
        pending.noBody=pending.method==='HEAD'||[204,304].includes(metadata.status);
        const stream=pending.noBody?null:new ReadableStream({
          start:controller=>{pending.controller=controller;this.credit(frame.id);},
          pull:()=>this.credit(frame.id),
          cancel:()=>this.discard(frame.id)
        },new ByteLengthQueuingStrategy({highWaterMark:WINDOW}));
        pending.resolve(new Response(stream,{status:metadata.status,headers}));
      } else if(frame.type===DATA||frame.type===COMPRESSED_DATA){
        let size=frame.payload.byteLength;
        if(frame.type===COMPRESSED_DATA){
          if(!(this.features&2)||size<5||size>CHUNK+4)throw Error('compression');
          size=new DataView(frame.payload.buffer,frame.payload.byteOffset,4).getUint32(0);
        }
        if(pending.ws||!pending.started||pending.noBody||size<=0||size>CHUNK||size>pending.credit)throw Error('window');
        pending.credit-=size;pending.deliveryBytes+=size;
        pending.delivery=(pending.delivery||Promise.resolve()).then(async()=>{
          const bytes=frame.type===COMPRESSED_DATA?await inflate(frame.payload,size):frame.payload;
          if(this.pending.get(frame.id)!==pending)return;
          pending.deliveryBytes-=size;pending.controller.enqueue(bytes);this.credit(frame.id);
        }).catch(()=>this.discard(frame.id,502));
        await pending.delivery;
      } else if(frame.type===END){
        if(pending.ws||!pending.started||frame.payload.byteLength)throw Error('end');
        pending.delivery=(pending.delivery||Promise.resolve()).then(()=>{
          if(this.pending.get(frame.id)!==pending)return;
          this.pending.delete(frame.id);clearTimeout(pending.timer);pending.controller?.close();
        }).catch(()=>this.discard(frame.id,502));await pending.delivery;
      } else if(frame.type===SOCKET_DATA){
        if(!pending.ws||!pending.started||!pending.socket||frame.payload.byteLength>SOCKET_MESSAGE||pending.socket.bufferedAmount+frame.payload.byteLength>SOCKET_WINDOW)throw Error('socket');
        pending.socket.send(frame.payload);this.send(SOCKET_CREDIT,frame.id,amount(frame.payload.byteLength));
      } else if(frame.type===SOCKET_CREDIT){
        if(!pending.ws||!pending.started||frame.payload.byteLength!==4)throw Error('socket credit');
        const count=new DataView(frame.payload.buffer,frame.payload.byteOffset,4).getUint32(0);
        if(count<=0||pending.uploadCredit+count>SOCKET_WINDOW)throw Error('socket credit');
        pending.uploadCredit+=count;pending.socket.serializeAttachment({id:frame.id,credit:pending.uploadCredit});
      } else if(frame.type===SOCKET_CLOSE){
        if(!pending.ws||frame.payload.byteLength)throw Error('socket close');this.discard(frame.id,503,false);
      } else if(frame.type===CANCEL){
        if(frame.payload.byteLength)throw Error('cancel');this.discard(frame.id,502,false);
      } else {throw Error('type');}
    } catch {
      this.disconnected();try{socket.close(1002,'protocol');}catch{}
      if(this.socket===socket)this.socket=null;
    }
  }
  async webSocketClose(socket) {
    if(socket===this.socket){this.disconnected();this.socket=null;this.features=0;}
    else {const id=socket.deserializeAttachment()?.id;if(this.pending.get(id)?.socket===socket)this.discard(id,502);}
  }
  async webSocketError(socket) {await this.webSocketClose(socket);}
}
