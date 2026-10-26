'use strict';
// Shared by original terminals and PTYs. A close cancels the single owned GET.
(() => {
  const type = 'application/vnd.autoapprove.terminal-v2';
  const compactType = 'application/vnd.autoapprove.terminal-v3';
  const fields = ['sessionID','screen','revision','observedAt','keys','inputReason','appearance','cursor','streamID','nativeDisplay','outputReason','sequence','question','screenPatch','screenCopy','appearanceUnchanged','ptyID','offset','data','reset','columns','rows','exitCode','canInput'];
  const events = ['screen','alive','output','failure'];
  const runBooleans = ['bold','dim','italic','underline','strike','inverse','hidden'];
  const cursorStyles = ['block','bar','underline'];
  const limit = 2000000, fatalUTF8 = new TextDecoder('utf-8', {fatal:true});
  const own = (object,key,value) => {
    if (Object.hasOwn(object,key)) throw new Error('중복된 터미널 필드입니다.');
    Object.defineProperty(object,key,{value,enumerable:true,writable:true,configurable:true});
  };
  function base64(bytes) {
    let text = '';
    for (let index=0;index<bytes.length;index+=8192) text += String.fromCharCode(...bytes.subarray(index,index+8192));
    return btoa(text);
  }
  function hex(bytes) {
    const digits='0123456789abcdef';let text='';
    for(let index=0;index<bytes.length;index++){const byte=bytes[index];text+=digits[byte>>4]+digits[byte&15];}
    return text;
  }
  class Reader {
    constructor(data,version=2) { this.data=data;this.version=version;this.offset=0;this.nodes=0;this.strings=0; }
    charge(nodes,strings) {
      this.nodes+=nodes;this.strings+=strings;
      if(this.nodes>100000||this.strings>limit)throw new Error('터미널 데이터 구조가 너무 큽니다.');
    }
    stringValue(depth) { const value=this.value(depth);if(typeof value!=='string')throw new Error('잘못된 터미널 문자열입니다.');return value; }
    run(depth,implicit=false) {
      if(depth+1>64)throw new Error('터미널 데이터 구조가 너무 큽니다.');
      const offset=this.uint(),length=this.uint(),flags=this.uint();
      if(flags>65535||((flags>>>9)&~(flags>>>2)&127))throw new Error('잘못된 터미널 속성 비트입니다.');
      const value={offset,length};let count=4,strings=12;
      if(flags&1){count++;strings+=2;}if(flags&2){count++;strings+=2;}
      for(let index=0;index<7;index++)if(flags&(1<<(index+2))){count+=2;strings+=runBooleans[index].length;}
      this.charge(count+(implicit?1:0),strings);
      if(flags&1)value.fg=this.stringValue(depth+1);if(flags&2)value.bg=this.stringValue(depth+1);
      for(let index=0;index<7;index++)if(flags&(1<<(index+2)))value[runBooleans[index]]=!!(flags&(1<<(index+9)));
      return value;
    }
    schema(kind,depth) {
      if(depth+1>64)throw new Error('터미널 데이터 구조가 너무 큽니다.');
      if(kind===1)return this.run(depth);
      if(kind===2){
        const flags=this.byte(),style=flags>>>2;
        if(flags>11||style>2)throw new Error('잘못된 터미널 커서 비트입니다.');
        this.charge(10,30+cursorStyles[style].length);
        return {offset:this.uint(),padding:this.uint(),visible:!!(flags&1),style:cursorStyles[style],blink:!!(flags&2)};
      }
      if(kind===3){
        const flags=this.byte();if(flags>3)throw new Error('잘못된 터미널 색상 비트입니다.');
        this.charge(2+((flags&1)?1:0)+((flags&2)?1:0),4+((flags&1)?10:0)+((flags&2)?10:0));
        const value={runs:[]};
        if(flags&1)value.foreground=this.stringValue(depth+1);if(flags&2)value.background=this.stringValue(depth+1);
        const count=this.length(15);if(count>8000)throw new Error('터미널 속성이 너무 많습니다.');
        for(let index=0;index<count;index++)value.runs.push(this.run(depth+2,true));return value;
      }
      if(kind===4){
        this.charge(10,44);
        return {baseRevision:this.stringValue(depth+1),baseLength:this.uint(),prefix:this.uint(),suffix:this.uint(),text:this.stringValue(depth+1),length:this.uint()};
      }
      if(kind===5){
        this.charge(11,46);
        return {baseRevision:this.stringValue(depth+1),baseLength:this.uint(),start:this.uint(),count:this.uint(),head:this.stringValue(depth+1),tail:this.stringValue(depth+1),length:this.uint()};
      }
      throw new Error('지원하지 않는 터미널 스키마입니다.');
    }
    raw(count) {
      if (!Number.isSafeInteger(count) || count<0 || count>this.data.length-this.offset) throw new Error('불완전한 터미널 프레임입니다.');
      const bytes=this.data.subarray(this.offset,this.offset+count); this.offset+=count; return bytes;
    }
    byte() { if(this.offset>=this.data.length) throw new Error('불완전한 터미널 프레임입니다.'); return this.data[this.offset++]; }
    uint() {
      let value=0, scale=1;
      for(let index=0;index<8;index++) {
        const byte=this.byte();
        if(index===7 && byte>15) throw new Error('터미널 정수 범위를 넘었습니다.');
        value += (byte&127)*scale;
        if(!(byte&128)) { if(index && byte===0) throw new Error('잘못된 터미널 정수입니다.'); return value; }
        scale*=128;
      }
      throw new Error('터미널 정수가 너무 깁니다.');
    }
    length(small) {
      const value=small<15 ? small : this.uint();
      if(value>limit) throw new Error('터미널 프레임이 너무 큽니다.');
      return value;
    }
    text(bytes) {
      this.strings+=bytes.length;
      if(this.strings>limit) throw new Error('터미널 문자가 너무 많습니다.');
      return fatalUTF8.decode(bytes);
    }
    value(depth=0,rawOutput=false) {
      if(depth>64 || ++this.nodes>100000) throw new Error('터미널 데이터 구조가 너무 큽니다.');
      const header=this.byte(), tag=header>>4, small=header&15;
      if(tag<3) { if(small) throw new Error('잘못된 터미널 값입니다.'); return tag===0?null:tag===2; }
      if(tag===3 || tag===4) {
        const value=small<15?small:this.uint(), signed=tag===4?-value-1:value;
        if(!Number.isSafeInteger(signed)) throw new Error('터미널 정밀도를 확인하지 못했습니다.');
        return signed;
      }
      if(tag===5) {
        if(small) { if(this.version===3)return this.schema(small,depth);throw new Error('잘못된 터미널 숫자입니다.'); }
        const bytes=this.raw(8), value=new DataView(bytes.buffer,bytes.byteOffset,8).getFloat64(0,true);
        if(!Number.isFinite(value)) throw new Error('잘못된 터미널 숫자입니다.');
        return value;
      }
      if(tag===12 || tag===13) {
        if(small) throw new Error('잘못된 터미널 식별자입니다.');
        let text=hex(this.raw(16));
        if(tag===13) text=text.toUpperCase();
        return [text.slice(0,8),text.slice(8,12),text.slice(12,16),text.slice(16,20),text.slice(20)].join('-');
      }
      if(tag===14 || tag===15) {
        if(small) throw new Error('잘못된 터미널 색상입니다.');
        let text=hex(this.raw(3));
        return '#'+(tag===15?text.toUpperCase():text);
      }
      const count=this.length(small);
      if(tag===6) return this.text(this.raw(count));
      if(tag===9) { this.strings+=Math.ceil(count/3)*4; if(this.strings>limit) throw new Error('터미널 출력이 너무 큽니다.'); const bytes=this.raw(count);return rawOutput?new Uint8Array(bytes):base64(bytes); }
      if(tag===10 || tag===11) {
        if(count>256) throw new Error('터미널 해시가 너무 깁니다.');
        const text=hex(this.raw(count));
        return tag===11?text.toUpperCase():text;
      }
      if(count>100000 || count>this.data.length-this.offset) throw new Error('터미널 항목이 너무 많습니다.');
      if(tag===7) { const array=[]; for(let index=0;index<count;index++) array.push(this.value(depth+1)); return array; }
      if(tag!==8) throw new Error('지원하지 않는 터미널 값입니다.');
      const object={};
      for(let index=0;index<count;index++) { const key=this.value(depth+1); if(typeof key!=='string') throw new Error('잘못된 터미널 필드입니다.'); own(object,key,this.value(depth+1)); }
      return object;
    }
  }
  function decode(mode,bytes,rawOutput=false,version=2) {
    const event=mode&127;
    if(event===4 && mode===4 && bytes.length===0) return null;
    if(event>=events.length) throw new Error('지원하지 않는 터미널 이벤트입니다.');
    if(mode&128) return {type:events[event],value:JSON.parse(fatalUTF8.decode(bytes))};
    const reader=new Reader(bytes,version), mask=reader.raw(4), flags=new DataView(mask.buffer,mask.byteOffset,4).getUint32(0,true), value={};
    if(flags>>>fields.length) throw new Error('지원하지 않는 터미널 필드입니다.');
    for(let index=0;index<fields.length;index++) if(flags&(1<<index)) own(value,fields[index],reader.value(0,rawOutput&&event===2&&index===18));
    const extra=reader.length(15);
    if(extra>100000) throw new Error('터미널 필드가 너무 많습니다.');
    for(let index=0;index<extra;index++) { const key=reader.value(); if(typeof key!=='string') throw new Error('잘못된 터미널 필드입니다.'); own(value,key,reader.value()); }
    if(reader.offset!==bytes.length) throw new Error('터미널 프레임 뒤에 데이터가 남았습니다.');
    return {type:events[event],value};
  }
  class Parser {
    constructor(rawOutput=false,version=2) { this.rawOutput=rawOutput;this.version=version;this.header=new Uint8Array(14);this.reset(); }
    reset() { this.headerCount=0; this.expected=null; this.body=null; this.received=0; this.mode=0; }
    push(chunk,emit) {
      let offset=0;
      while(offset<chunk.length) {
        if(this.expected===null) {
          const byte=chunk[offset++];
          if(this.headerCount>=this.header.length) throw new Error('터미널 헤더가 너무 깁니다.');
          this.header[this.headerCount++]=byte;
          if(this.headerCount<=4) {
            if(this.headerCount<=3 && byte!==[65,65,this.version][this.headerCount-1]) throw new Error('터미널 전송 버전이 다릅니다.');
            if(this.headerCount===4) this.mode=byte;
            continue;
          }
          if(byte&128) continue;
          const reader=new Reader(this.header.subarray(4,this.headerCount)); this.expected=reader.length(15);
          if(this.expected===0) { const event=decode(this.mode,new Uint8Array(),this.rawOutput,this.version); this.reset(); if(event && emit(event)===false) return; }
        } else {
          const count=Math.min(this.expected-this.received,chunk.length-offset);
          if(this.received===0 && count===this.expected) {
            const event=decode(this.mode,chunk.subarray(offset,offset+count),this.rawOutput,this.version); offset+=count; this.reset();
            if(event && emit(event)===false) return;
          } else {
            if(!this.body) this.body=new Uint8Array(this.expected);
            this.body.set(chunk.subarray(offset,offset+count),this.received);this.received+=count;offset+=count;
            if(this.received===this.expected) { const event=decode(this.mode,this.body,this.rawOutput,this.version);this.reset();if(event && emit(event)===false)return; }
          }
        }
      }
    }
    finish() { if(this.headerCount || this.expected!==null) throw new Error('터미널 프레임 수신이 중단됐습니다.'); }
  }
  class SSEParser {
    constructor() { this.decoder=new TextDecoder('utf-8');this.line='';this.data=[];this.size=0;this.event='';this.id='';this.skipLF=false;this.first=true; }
    push(chunk,emit,final=false) {
      const text=this.decoder.decode(chunk,{stream:!final});
      for(const character of text) {
        if(this.first) { this.first=false;if(character==='\uFEFF')continue; }
        if(this.skipLF) { this.skipLF=false;if(character==='\n')continue; }
        if(character==='\r'||character==='\n') {
          const line=this.line;this.line='';this.skipLF=character==='\r';
          if(!line) {
            if(this.data.length) { const event={type:this.event||'message',data:this.data.join('\n'),lastEventId:this.id};this.data=[];this.size=0;this.event='';if(emit(event)===false)return; }
            else this.event='';
          } else if(line[0]!==':') {
            const colon=line.indexOf(':'),name=colon<0?line:line.slice(0,colon);let value=colon<0?'':line.slice(colon+1);if(value[0]===' ')value=value.slice(1);
            if(name==='data'){this.data.push(value);this.size+=value.length;if(this.size>limit)throw new Error('터미널 출력이 너무 큽니다.');}
            else if(name==='event')this.event=value;
            else if(name==='id'&&!value.includes('\0'))this.id=value;
          }
        } else { this.line+=character;if(this.line.length>limit)throw new Error('터미널 출력 줄이 너무 큽니다.'); }
      }
    }
    finish() { this.push(new Uint8Array(),()=>{},true); }
  }
  class Source {
    constructor(url,rawOutput=false,version=2) { this.rawOutput=rawOutput;this.url=url;this.version=version;this.received=false;this.listeners=new Map();this.closed=false;this.controller=new AbortController();queueMicrotask(()=>void this.run()); }
    addEventListener(name,callback) { let list=this.listeners.get(name);if(!list)this.listeners.set(name,list=[]);list.push(callback); }
    emit(event) { if(this.closed)return false;this.received=true;for(const callback of this.listeners.get(event.type)||[]) { callback(event);if(this.closed)return false; }return !this.closed; }
    close() { if(this.closed)return;this.closed=true;this.controller.abort();void this.reader?.cancel().catch(()=>{}); }
    async run() {
      try {
        const response=await fetch(this.url,{signal:this.controller.signal,cache:'no-store',credentials:'omit',headers:{Accept:(this.version===3?compactType+', ':'')+type+', text/event-stream'}});
        if(!response.ok) { let message='터미널 연결을 확인해주세요.',failureKind;try{const value=await response.json();if(typeof value.error==='string')message=value.error;failureKind=value.diagnostics?.failureKind;}catch(_){}throw Object.assign(new Error(message),{status:response.status,failureKind}); }
        const content=response.headers.get('content-type')?.split(';')[0].trim().toLowerCase();
        if(content!==type&&content!=='text/event-stream'&&!(this.version===3&&content===compactType))throw Object.assign(new Error('터미널 전송 형식을 확인하지 못했습니다.'),{wireFormat:true});
        if(!response.body)throw new Error('터미널 출력 연결이 없습니다.');
        const parser=content==='text/event-stream'?new SSEParser():new Parser(this.rawOutput,content===compactType?3:2),reader=response.body.getReader();this.reader=reader;
        try { while(!this.closed){
          const {value,done}=await reader.read();
          try { if(done)parser.finish();else parser.push(value,event=>this.emit(event)); }
          catch(error){error.wireFormat=true;throw error;}
          if(done)throw new Error('터미널 출력 연결이 끝났습니다.');
          this.lastActivity=Date.now();
        } }
        finally { this.reader=null;try{await reader.cancel();}catch(_){}reader.releaseLock(); }
      } catch(error) { if(!this.closed){this.close();this.onerror?.(error);} }
    }
  }
  window.AutoApproveTerminalWire={type,compactType,Parser,SSEParser,decode,Source,open(url,binary,rawOutput=false) {
    const version=binary===true?2:binary;
    if(![2,3].includes(version) || typeof fetch!=='function' || typeof ReadableStream==='undefined' || typeof BigInt==='undefined')return new EventSource(url);
    const target=new URL(url,location.href);target.searchParams.set('wire',String(version));return new Source(target.href,rawOutput,version);
  }};
})();
