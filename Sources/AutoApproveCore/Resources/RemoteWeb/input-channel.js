'use strict';
// One ordered writer, bounded outstanding bytes, no replay or local echo.
window.AutoApproveInputChannel = class {
  static keys = ['characters','enter','escape','interrupt','up','down','left','right','backspace','delete','home','end','tab'];
  constructor(node, binding, callbacks = {}) {
    this.node = node; this.binding = binding; this.callbacks = callbacks;
    this.state = 'opening'; this.sequence = 0; this.acknowledged = 0;
    this.pending = new Map(); this.pendingBytes = 0; this.samples = [];
    this.encoder = new TextEncoder(); this.decoder = new TextDecoder('utf-8', {fatal:true});
  }
  get pendingCount() { return this.pending.size; }
  static packet(kind, sequence = 0, payload = new Uint8Array()) {
    if (!(payload instanceof Uint8Array) || payload.length > 16001 || !Number.isInteger(sequence) || sequence < 0 || sequence > 0xffffffff) throw new Error('실시간 입력 형식을 확인하지 못했습니다.');
    const bytes = new Uint8Array(8 + payload.length);
    bytes.set([65,73,1,kind]); new DataView(bytes.buffer).setUint32(4,sequence); bytes.set(payload,8); return bytes;
  }
  open() {
    this.opened = new Promise((resolve,reject) => { this.resolve = resolve; this.reject = reject; });
    try {
      const url = new URL('/api/input/socket', location.href); url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
      url.searchParams.set('node',this.node);
      this.socket = new WebSocket(url, 'autoapprove-input.v1'); this.socket.binaryType = 'arraybuffer';
      this.openTimer = setTimeout(() => this.fallback(),4000);
      this.socket.onopen = () => {
        try { this.socket.send(window.AutoApproveInputChannel.packet(0,0,this.encoder.encode(JSON.stringify(this.binding)))); }
        catch (_) { this.fallback(); }
      };
      this.socket.onmessage = event => this.receive(event.data);
      this.socket.onerror = () => this.disconnected(); this.socket.onclose = () => this.disconnected();
    } catch (_) { this.fallback(); }
    return this.opened;
  }
  fallback() {
    if (this.state !== 'opening' || this.sequence !== 0) return;
    const resolve = this.resolve; this.resolve = null; this.reject = null;
    this.close(); resolve?.(null);
  }
  disconnected() {
    if (this.state === 'opening') { this.fallback(); return; }
    if (this.state === 'ready') {
      const error = new Error(this.pendingCount ? '입력 전달 결과를 확인하지 못했습니다. 같은 입력을 다시 보내지 말고 원본 화면을 확인해주세요.' : '실시간 입력 연결이 끊겼습니다. 화면을 다시 연결해주세요.');
      error.recoverable = this.pendingCount === 0; this.fail(error);
    }
  }
  receive(value) {
    if (this.state === 'closed') return;
    try {
      if (!(value instanceof ArrayBuffer) || value.byteLength < 8 || value.byteLength > 16009) throw new Error('실시간 입력 응답을 확인하지 못했습니다.');
      const bytes = new Uint8Array(value), view = new DataView(value), kind = bytes[3], sequence = view.getUint32(4), payload = bytes.subarray(8);
      if (bytes[0] !== 65 || bytes[1] !== 73 || bytes[2] !== 1) throw new Error('실시간 입력 버전이 다릅니다.');
      if (kind === 1 && sequence === 0) {
        if (payload.length === 1 && payload[0] === 1 && this.state === 'opening') return; // Authenticated bridge greeting.
        if (payload.length || this.state !== 'opening') throw new Error('입력 연결 확인 순서가 바뀌었습니다.');
        clearTimeout(this.openTimer); this.openTimer = null; this.state = 'ready';
        const resolve = this.resolve; this.resolve = null; this.reject = null; resolve?.(this);
        this.ping(); this.pingTimer = setInterval(() => this.ping(),this.binding.mode==='screen'?1000:15000); this.changed(); return;
      }
      if (kind === 5) {
        const failure = JSON.parse(this.decoder.decode(payload));
        if (this.state === 'opening' && [404,405,426].includes(failure.status)) { this.fallback(); return; }
        throw new Error(typeof failure.message === 'string' ? failure.message : '입력 전달을 확인하지 못했습니다.');
      }
      if (this.state !== 'ready') throw new Error('입력 연결을 먼저 확인해주세요.');
      if (kind === 7 && sequence === 0 && payload.length === 8) {
        const sent = new DataView(payload.buffer,payload.byteOffset,8).getFloat64(0);
        if (sent !== this.lastPing) throw new Error('연결 지연 측정 응답을 확인하지 못했습니다.');
        clearTimeout(this.pongTimer);this.pongTimer=null;
        this.observe(performance.now()-sent); this.lastPing = null; return;
      }
      if (kind !== 4 || payload.length || sequence <= this.acknowledged || sequence > this.sequence || !this.pending.has(sequence)) throw new Error('입력 확인 순서가 바뀌었습니다. 화면을 확인해주세요.');
      const now = performance.now();
      for (const [id,item] of this.pending) if (id <= sequence) { this.pending.delete(id); this.pendingBytes -= item.bytes; this.observe(now-item.sent,false); }
      this.acknowledged = sequence; this.armDeadline(); this.quality(); this.changed();
    } catch (error) { this.fail(error); }
  }
  canSend(length) {
    if(this.state!=='ready'||this.socket.readyState!==WebSocket.OPEN||this.pendingCount>=16||this.pendingBytes+length>64000)return false;
    if(this.socket.bufferedAmount>=64000){this.watchBuffer();return false;}
    this.clearBufferWait();return true;
  }
  watchBuffer() {
    if(this.state!=='ready'||this.bufferTimer!=null)return;
    if(this.bufferStarted==null){this.bufferStarted=performance.now();this.bufferDelay=8;}
    this.bufferTimer=setTimeout(()=>{
      this.bufferTimer=null;if(this.state!=='ready')return;
      if(this.socket.readyState!==WebSocket.OPEN){this.disconnected();return;}
      if(this.socket.bufferedAmount<64000){this.clearBufferWait();this.changed();return;}
      if(performance.now()-this.bufferStarted>=20000){
        const error=new Error(this.pendingCount?'입력 전달 결과를 확인하지 못했습니다. 같은 입력을 다시 보내지 말고 원본 화면을 확인해주세요.':'입력 연결의 전송 대기가 길어 연결을 다시 확인합니다.');
        error.recoverable=this.pendingCount===0;this.fail(error);return;
      }
      this.bufferDelay=Math.min(100,this.bufferDelay*2);this.watchBuffer();
    },Math.max(1,Math.min(this.bufferDelay,20000-(performance.now()-this.bufferStarted))));
  }
  clearBufferWait() {
    if(this.bufferStarted==null)return;
    clearTimeout(this.bufferTimer);this.bufferTimer=null;this.bufferStarted=null;this.bufferDelay=0;
  }
  send(kind,payload) {
    if (!this.canSend(payload.length)) return false;
    if (this.sequence === 0xffffffff) { this.fail(new Error('입력 연결을 새로 확인해주세요.')); return false; }
    const sequence = ++this.sequence;
    this.pending.set(sequence,{bytes:payload.length,sent:performance.now()}); this.pendingBytes += payload.length;
    try { this.socket.send(window.AutoApproveInputChannel.packet(kind,sequence,payload)); this.armDeadline(); this.changed(); }
    catch (_) { this.fail(new Error('입력 전달 결과를 확인하지 못했습니다. 원본 화면을 확인해주세요.')); }
    // A reserved/attempted write is never returned to the unsent queue.
    return true;
  }
  armDeadline() {
    const first=this.pending.entries().next().value;
    if(first&&this.ackTimer!=null&&this.ackSequence===first[0])return;
    clearTimeout(this.ackTimer); this.ackTimer = null;
    this.ackSequence=first?.[0]??null;
    if(first){const[sequence,item]=first;this.ackTimer=setTimeout(()=>{
      this.ackTimer=null;
      if(this.state==='ready'&&this.pending.keys().next().value===sequence)this.fail(new Error('입력 확인 응답이 늦어 직접 입력을 멈췄습니다. 원본 화면을 확인해주세요.'));
    },Math.max(1,20000-(performance.now()-item.sent)));}
  }
  ping() {
    if (this.state !== 'ready' || this.lastPing != null) return;
    this.lastPing = performance.now(); const bytes = new Uint8Array(8); new DataView(bytes.buffer).setFloat64(0,this.lastPing);
    this.pongTimer=setTimeout(()=>{
      if(this.state!=='ready'||this.lastPing==null)return;
      const error=new Error(this.pendingCount?'입력 전달 결과를 확인하지 못했습니다. 같은 입력을 다시 보내지 말고 원본 화면을 확인해주세요.':'입력 연결의 응답이 없어 연결을 다시 확인합니다.');
      error.recoverable=this.pendingCount===0;this.fail(error);
    },this.binding.mode==='screen'?3000:7500);
    try { this.socket.send(window.AutoApproveInputChannel.packet(6,0,bytes)); } catch (_) { this.disconnected(); }
  }
  observe(ms,notify = true) {
    if (!Number.isFinite(ms) || ms < 0 || ms > 60000) return;
    this.samples.push(ms); if (this.samples.length > 64) this.samples.shift(); if (notify) this.quality();
  }
  quality() {
    const values = [...this.samples].sort((a,b) => a-b);
    this.callbacks.onQuality?.({transport:'WebSocket',samples:values.length,medianMS:values.length ? values[Math.ceil(values.length*.5)-1] : null,p95MS:values.length ? values[Math.ceil(values.length*.95)-1] : null,pending:this.pendingCount});
  }
  changed() {
    if(this.state!=='ready'||this.changeScheduled)return;this.changeScheduled=true;
    queueMicrotask(()=>{this.changeScheduled=false;if(this.state==='ready')this.callbacks.onChange?.();});
  }
  fail(error) {
    if (this.state === 'closed') return;
    const reject = this.reject, opening = this.state === 'opening'; this.resolve = null; this.reject = null;
    this.close(); if (opening) reject?.(error); else queueMicrotask(() => this.callbacks.onFailure?.(error));
  }
  close() {
    if (this.state === 'closed') return; this.state = 'closed';
    clearTimeout(this.openTimer); clearTimeout(this.ackTimer); clearInterval(this.pingTimer);clearTimeout(this.pongTimer);this.pongTimer=null;this.lastPing=null;
    this.ackTimer=null;this.ackSequence=null;this.clearBufferWait();
    if (this.socket) { this.socket.onopen = this.socket.onmessage = this.socket.onerror = this.socket.onclose = null; this.socket.close(); }
    // Keep only numeric pending metadata for the owner to classify uncertainty.
    const resolve = this.resolve; this.resolve = null; this.reject = null; resolve?.(null);
  }
};
