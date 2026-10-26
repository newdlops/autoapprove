// HTTP/SSE relay only. Browser authorization stays in the Mac gateway.
const LIMIT=32, BODY=2_000_000, BUDGET=8_000_000, WINDOW=262144, CHUNK=32768;
const REQUEST=1, HEADERS=2, DATA=3, END=4, CANCEL=5, CREDIT=6, HELLO=0;
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
  if(type>6||(id===0)!==(type===HELLO))throw Error('invalid kind');
  return {type,id,payload:bytes.subarray(8)};
}
const error=status=>new Response(status===503?'Mac이 연결되어 있지 않습니다.':'연결 요청을 처리하지 못했습니다.',{status,headers:{'Cache-Control':'no-store','Content-Type':'text/plain; charset=utf-8'}});
const hop=new Set(['connection','upgrade','keep-alive','proxy-authenticate','proxy-authorization','te','trailer','transfer-encoding','content-length']);
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
  }
  send(type,id,payload) {
    if(!this.socket||this.socket.readyState!==1||this.socket.bufferedAmount>4_000_000)throw Error('unavailable');
    this.socket.send(packet(type,id,payload));
  }
  discard(id,status=502,notify=true) {
    const pending=this.pending.get(id);if(!pending)return;
    this.pending.delete(id);clearTimeout(pending.timer);
    pending.reader?.cancel().catch(()=>{});
    if(!pending.started)pending.resolve(error(status));
    else {try {pending.controller?.error(Error('연결이 종료됐습니다.'));}catch{}}
    if(notify){try{this.send(CANCEL,id);}catch{}}
  }
  disconnected() {for(const id of [...this.pending.keys()])this.discard(id,503,false);}
  credit(id) {
    const pending=this.pending.get(id);
    if(!pending?.controller)return;
    const available=Math.max(0,Math.min(WINDOW,Math.floor(pending.controller.desiredSize||0)));
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
      this.ctx.acceptWebSocket(server,['connector']);this.socket=server;
      server.send(packet(HELLO,0,new Uint8Array([1])));
      return new Response(null,{status:101,webSocket:client});
    }
    if(!this.socket||this.socket.readyState!==1)return error(503);
    if(request.signal?.aborted)return error(499);
    if(this.pending.size>=LIMIT)return error(503);
    if(!['GET','POST','HEAD','OPTIONS'].includes(request.method))return error(405);
    do{this.counter=(this.counter+1)>>>0;}while(this.counter===0||this.pending.has(this.counter));
    const id=this.counter;
    let resolve;const response=new Promise(done=>{resolve=done;});
    const pending={resolve,started:false,controller:null,credit:0,reader:null,method:request.method,
      timer:setTimeout(()=>this.discard(id,504),45000)};
    this.pending.set(id,pending);
    request.signal?.addEventListener('abort',()=>this.discard(id,499),{once:true});
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
      const metadata=encoder.encode(JSON.stringify({method:request.method,path:url.pathname+url.search,headers:headersObject(request.headers)}));
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
    if(socket!==this.socket)return;
    try {
      const frame=unpack(value),pending=this.pending.get(frame.id);
      if(!pending)return;
      if(frame.type===HEADERS){
        if(pending.started||frame.payload.byteLength>32768)throw Error('headers');
        const metadata=JSON.parse(decoder.decode(frame.payload));
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
      } else if(frame.type===DATA){
        if(!pending.started||pending.noBody||frame.payload.byteLength>CHUNK||frame.payload.byteLength>pending.credit)throw Error('window');
        pending.credit-=frame.payload.byteLength;pending.controller.enqueue(frame.payload);this.credit(frame.id);
      } else if(frame.type===END){
        if(!pending.started||frame.payload.byteLength)throw Error('end');
        this.pending.delete(frame.id);clearTimeout(pending.timer);pending.controller?.close();
      } else if(frame.type===CANCEL){
        if(frame.payload.byteLength)throw Error('cancel');this.discard(frame.id,502,false);
      } else {throw Error('type');}
    } catch {
      this.disconnected();try{socket.close(1002,'protocol');}catch{}
      if(this.socket===socket)this.socket=null;
    }
  }
  async webSocketClose(socket) {if(socket===this.socket){this.disconnected();this.socket=null;}}
  async webSocketError(socket) {if(socket===this.socket){this.disconnected();this.socket=null;}}
}
