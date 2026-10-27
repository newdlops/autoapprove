'use strict';
// Raw PTY bytes are interpreted by xterm, never inserted as HTML or locally echoed.
window.AutoApprovePTY = class {
  constructor(container, descriptor, nodeID, api, uuid, report, fontSize = 14, streaming = true, binary = false, polling = false) {
    this.container = container; this.descriptor = descriptor; this.nodeID = nodeID; this.api = api; this.uuid = uuid; this.report = report;
    this.streaming = streaming;
    this.polling = polling && streaming;
    this.binary = binary;
    this.clientID = uuid(); this.sequence = 0; this.offset = null; this.queue = []; this.sending = false; this.disposed = false; this.ready = false; this.blocked = false;
    this.inputChannel = null; this.inputNegotiating = false; this.inputAttempted = false;
    this.inputRetries = 0; this.inputEpoch = 0;
    this.outputQueue = []; this.outputBytes = 0; this.writing = false; this.outputPaused = false; this.source = null;
    this.sourceEpoch = 0; this.retries = 0; this.reconnecting = false;
    this.maxOutputBytes = 512000; this.maxSnapshotBytes = 2097152; this.maxOutputEvents = 64;
    this.term = new Terminal({ cols: descriptor.columns, rows: descriptor.rows, fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace', fontSize, lineHeight: 1.25, cursorBlink: !matchMedia('(prefers-reduced-motion: reduce)').matches, scrollback: 4000, disableStdin: true, theme: { background: '#171a20', foreground: '#e5e8ee', cursor: '#e5e8ee', selectionBackground: '#315782' } });
    this.fitAddon = new FitAddon.FitAddon(); this.term.loadAddon(this.fitAddon); this.term.open(container);
    this.term.textarea.setAttribute('aria-label', 'PTY 터미널에 직접 입력'); this.term.textarea.setAttribute('autocapitalize', 'off'); this.term.textarea.setAttribute('autocorrect', 'off'); this.term.textarea.setAttribute('enterkeyhint', 'enter');
    this.term.attachCustomKeyEventHandler(event => !(event.key === 'Tab' && event.shiftKey));
    // libvterm on the Mac is the sole terminal-query responder. Rendering a query
    // or restoring a screen must not inject a second reply into the foreground CLI.
    for (const final of ['n', 'c', 't']) for (const prefix of ['', '?', '>', '=']) this.term.parser.registerCsiHandler({ final, ...(prefix ? {prefix} : {}) }, () => true);
    for (const prefix of ['', '?']) this.term.parser.registerCsiHandler({ final: 'p', intermediates: '$', ...(prefix ? {prefix} : {}) }, () => true);
    this.term.parser.registerDcsHandler({ final: 'q', intermediates: '$' }, () => true);
    for (const code of [4, 10, 11, 12]) this.term.parser.registerOscHandler(code, data => data.includes('?'));
    this.term.onData(data => this.enqueue(data));
    this.term.onBinary(data => this.enqueueBytes(Uint8Array.from(data, char => char.charCodeAt(0))));
    this.term.onResize(() => { clearTimeout(this.resizeTimer); this.resizeTimer = setTimeout(() => void this.resize(), 100); });
    this.observer = new ResizeObserver(() => this.fit()); this.observer.observe(container);
    this.pointerListener = event => { this.pointer = {x:event.clientX, y:event.clientY, at:event.timeStamp}; };
    this.focusListener = event => {
      const pointer = this.pointer; this.pointer = null;
      const dragged = pointer && (Math.hypot(event.clientX - pointer.x, event.clientY - pointer.y) > 8 || event.timeStamp - pointer.at > 500);
      if (this.ready && !dragged && !this.term.hasSelection() && !window.getSelection()?.toString()) this.term.focus();
    };
    container.addEventListener('pointerdown', this.pointerListener, {passive:true});
    container.addEventListener('pointerup', this.focusListener);
    this.fit(); this.run();
  }
  path(route) { return route + '?' + new URLSearchParams({ node: this.nodeID }); }
  post(route, values) { return this.api(this.path(route), { requestID: this.uuid(), ptyID: this.descriptor.ptyID, streamID: this.descriptor.streamID, clientID: this.clientID, ...values }); }
  fit() {
    if (this.disposed || !this.container.clientWidth || !this.container.clientHeight) return;
    const size = this.fitAddon.proposeDimensions(); if (!size) return;
    const columns = Math.max(20, Math.min(240, size.cols)), rows = Math.max(5, Math.min(100, size.rows));
    if (this.term.cols !== columns || this.term.rows !== rows) this.term.resize(columns, rows);
  }
  async resize() {
    if (this.disposed || this.reconnecting || !this.streaming || this.resizing || this.ending || this.descriptor.exitCode != null) return;
    this.resizing = true;
    const columns = this.term.cols, rows = this.term.rows;
    try { if (columns !== this.descriptor.columns || rows !== this.descriptor.rows) { await this.post('/api/pty/resize', {columns, rows}); this.descriptor.columns = columns; this.descriptor.rows = rows; } }
    catch (error) { if (!this.disposed) { if (error.status === 409) this.resizePending = true; else this.fail(error); } }
    finally { this.resizing = false; if (!this.disposed && (this.term.cols !== columns || this.term.rows !== rows)) void this.resize(); }
  }
  run() {
    if (this.disposed || this.blocked || document.hidden) return;
    if (this.streaming) { if(this.polling)void this.pollOutput();else this.openStream(); void this.resize(); }
    else void this.readSnapshot();
  }
  async readSnapshot() {
    try {
      // Old peers support safe viewing, but not stream/reuse. Omit the client
      // lease and leave their process size and input untouched.
      const query = new URLSearchParams({node:this.nodeID, pty:this.descriptor.ptyID, stream:this.descriptor.streamID});
      const update = await this.api('/api/pty/output?' + query);
      if (!this.disposed) this.receive(update);
    } catch (error) { if (!this.disposed) this.fail(error); }
  }
  async pollOutput() {
    if(this.pollRunning||this.disposed||this.blocked||this.ending||document.hidden)return;
    this.pollRunning=true;
    const controller=new AbortController(),epoch=this.sourceEpoch;this.pollController=controller;
    try{
      while(!controller.signal.aborted&&!this.disposed&&!this.blocked&&!this.ending&&!document.hidden&&epoch===this.sourceEpoch){
        const query=new URLSearchParams({node:this.nodeID,pty:this.descriptor.ptyID,stream:this.descriptor.streamID,client:this.clientID});
        if(this.offset!==null)query.set('offset',String(this.offset));
        const update=await this.api('/api/pty/output?'+query,undefined,controller.signal,10000);
        if(controller.signal.aborted||this.disposed||epoch!==this.sourceEpoch)return;
        this.reconnecting=false;this.receive(update,epoch);
        while(!this.disposed&&(this.writing||this.outputQueue.length))await new Promise(resolve=>setTimeout(resolve,8));
        if(!update.data.length)await new Promise(resolve=>setTimeout(resolve,25));
      }
    }catch(error){if(!controller.signal.aborted&&!this.disposed)this.reconnect(error);}
    finally{if(this.pollController===controller)this.pollController=null;this.pollRunning=false;this.resumeOutput();}
  }
  closeStream(preserveControls=false) {
    this.pollController?.abort();this.pollController=null;
    clearTimeout(this.streamWatchdog); this.source?.close(); this.source = null;
    if (!preserveControls) { this.sourceEpoch = (this.sourceEpoch || 0) + 1; this.ready = false; this.term.options.disableStdin = true; }
  }
  reconnect(error) {
    if (this.disposed || this.blocked || this.ending) return;
    // A pending write may already have reached the Mac. Never replay it or
    // silently resume input while its result is uncertain.
    if ((this.sending || this.queue.length) && this.inputChannel?.state !== 'ready' || error.failureKind === 'identity' || [400,401,403,404,409,410].includes(error.status)) { this.fail(error); return; }
    const source = this.source;
    if (source?.version && !source.received && (error.wireFormat || error.wireTimeout || [406,415].includes(error.status))) this.binary = source.version === 3 ? 2 : 0;
    this.closeStream(); this.ready = false; this.term.options.disableStdin = true; this.reconnecting = true;
    this.report('waiting', 'PTY 다시 연결 중…', this);
    if (this.retryTimer) return;
    const attempt = this.retries++;
    const delay = attempt === 0 ? 0 : Math.min(5000,250 * 2 ** Math.min(attempt-1,5));
    this.retryTimer = setTimeout(() => { this.retryTimer = null; this.resumeOutput(); },delay);
  }
  resumeOutput() {
    // Commit every queued byte before choosing the next HTTP offset.
    if (this.disposed || this.blocked || this.ending || this.retryTimer || this.writing || this.outputQueue.length) return;
    if(this.polling){if(!document.hidden){this.outputPaused=false;void this.pollOutput();}return;}
    if (this.outputPaused || this.reconnecting) { this.outputPaused = false; this.openStream(); }
  }
  resumeNetwork() {
    if (!this.reconnecting || this.disposed || this.blocked) return;
    clearTimeout(this.retryTimer); this.retryTimer = null; this.retries = 0; this.resumeOutput();
  }
  watchStream(source) {
    clearTimeout(this.streamWatchdog);
    const budget = this.sourceReceived ? 35000 : 10000;
    const remaining = Math.max(1,budget-Math.max(0,Date.now()-Math.max(this.openedAt,source.lastActivity || 0)));
    this.streamWatchdog = setTimeout(() => {
      if (this.source !== source || this.disposed) return;
      if (source.version && Date.now()-Math.max(this.openedAt,source.lastActivity || 0)<budget) { this.watchStream(source); return; }
      if (source.version || !this.sourceReceived) this.reconnect(Object.assign(new Error('PTY 출력 응답을 기다리다 시간이 지났습니다.'),{wireTimeout:true}));
    },remaining);
  }
  openStream() {
    if (this.disposed || this.blocked || !this.streaming || this.polling || document.hidden || this.source) return;
    try {
      const query = new URLSearchParams({ node: this.nodeID, pty: this.descriptor.ptyID, stream: this.descriptor.streamID, client: this.clientID });
      // Only a fully rendered offset is safe to resume. A new xterm starts from
      // the native current-screen snapshot, including the alternate buffer.
      if (this.offset !== null) query.set('offset', String(this.offset));
      const url = '/api/pty/stream?' + query;
      const source = window.AutoApproveTerminalWire?.open(url,this.binary,true) || new EventSource(url); this.source = source;
      this.openedAt = Date.now(); this.sourceReceived = false; const epoch = this.sourceEpoch;
      this.watchStream(source);
      source.addEventListener('output', event => {
        if (this.disposed || this.source !== source) return;
        try {
          this.receive(Object.hasOwn(event,'value') ? event.value : JSON.parse(event.data),epoch);
          this.sourceReceived = true;
          this.watchStream(source);
          if (Date.now()-this.openedAt >= 1500) this.retries = 0;
        } catch (error) { this.fail(error); }
      });
      source.addEventListener('failure', event => {
        if (this.disposed || this.source !== source) return;
        let failure;
        try { failure = Object.hasOwn(event,'value') ? event.value : JSON.parse(event.data); } catch (_) {}
        const error = new Error(failure?.error || 'PTY 출력 연결이 끊겼습니다. 화면을 다시 연결해주세요.');
        if (failure?.retryable === true) this.reconnect(error); else this.fail(error);
      });
      source.onerror = error => {
        if (!this.disposed && this.source === source) this.reconnect(error instanceof Error ? error : new Error('PTY 출력 연결이 끊겼습니다.'));
      };
    } catch (error) { this.fail(error); }
  }
  receive(update,epoch=this.sourceEpoch) {
    if (update.streamID !== this.descriptor.streamID || update.ptyID !== this.descriptor.ptyID || !Number.isSafeInteger(update.offset) || update.offset < 0 || typeof update.data !== 'string' && !(update.data instanceof Uint8Array)) throw new Error('PTY 연결이 바뀌었습니다. 다시 연결해주세요.');
    const singleLimit = update.reset ? this.maxSnapshotBytes : this.maxOutputBytes;
    if (typeof update.data === 'string' && update.data.length > Math.ceil(singleLimit / 3) * 4) throw new Error('터미널 출력이 너무 큽니다. 화면을 다시 연결해주세요.');
    const bytes = update.data instanceof Uint8Array ? update.data : Uint8Array.from(atob(update.data), char => char.charCodeAt(0));
    if (bytes.length > singleLimit) throw new Error('터미널 출력이 너무 큽니다. 화면을 다시 연결해주세요.');
    if (this.outputBytes + bytes.length > this.maxOutputBytes && (this.writing || this.outputQueue.length) || this.outputQueue.length >= this.maxOutputEvents) {
      // Stop receiving before xterm's own async write queue can grow. Drain the
      // bounded queue, then resume its committed offset or the native snapshot.
      // This deliberate read pause retains the current writer permission so
      // Ctrl C can still stop a flood while the bounded renderer drains.
      this.closeStream(true); this.outputPaused = true;
      this.report('waiting', '터미널 출력 반영 중…', this);
      return;
    }
    this.outputQueue.push({update, bytes, epoch}); this.outputBytes += bytes.length;
    if (update.exitCode != null) { this.closeStream(); this.ending = true; this.ready = false; this.term.options.disableStdin = true; }
    void this.renderOutput();
  }
  async renderOutput() {
    if (this.writing || this.disposed) return;
    this.writing = true;
    try {
      while (this.outputQueue.length && !this.disposed) {
        const {update, bytes, epoch} = this.outputQueue.shift();
        if (!update.reset && (this.offset === null || update.offset - this.offset !== bytes.length)) throw new Error('PTY 출력 순서가 바뀌었습니다. 화면을 다시 연결해주세요.');
        if (update.reset) {
          if (update.exitCode != null) {
            if (!Number.isInteger(update.columns) || update.columns < 20 || update.columns > 240 || !Number.isInteger(update.rows) || update.rows < 5 || update.rows > 100) throw new Error('PTY 화면 크기를 확인하지 못했습니다. 다시 연결해주세요.');
            // A closed process cannot resize its native screen. Decode its full
            // grid before fitting so trailing blank rows do not hide final text.
            this.term.resize(update.columns, update.rows);
          }
          this.term.reset();
        }
        if (bytes.length) await new Promise(resolve => this.term.write(bytes, resolve));
        if (this.disposed) return;
        this.outputBytes = Math.max(0, this.outputBytes - bytes.length); this.offset = update.offset; this.descriptor.exitCode = update.exitCode;
        if (update.reset && update.exitCode != null) this.fit();
        if (epoch === this.sourceEpoch && !this.outputPaused) this.reconnecting = false;
        this.ready = this.streaming && epoch === this.sourceEpoch && !this.reconnecting && !this.blocked && !this.ending && update.exitCode == null && update.canInput !== false; this.term.options.disableStdin = !this.ready;
        this.report(update.exitCode != null ? 'ended' : this.blocked ? 'blocked' : !this.streaming ? 'readonly' : !this.ready ? 'waiting' : 'live', update.exitCode != null ? 'PTY 종료 · 코드 ' + update.exitCode : this.blocked ? this.error : !this.streaming ? '화면 보기 · Mac 업데이트 필요' : this.ending ? 'PTY 마지막 출력 반영 중…' : this.reconnecting ? 'PTY 다시 연결 중…' : this.outputPaused ? '터미널 출력 반영 중…' : this.ready ? 'PTY 실시간 연결됨' : '출력 연결됨 · 다른 브라우저 입력 대기', this);
        if (this.ready && this.resizePending) { this.resizePending = false; void this.resize(); }
        if (this.ready && !this.inputAttempted) void this.openInputChannel();
        if (this.ready && this.queue.length) void this.flush();
        if (update.exitCode != null) { this.term.options.cursorBlink = false; return; }
      }
    } catch (error) { if (!this.disposed) this.fail(error); }
    finally {
      this.writing = false;
      this.resumeOutput();
    }
  }
  enqueue(data) { this.enqueueBytes(new TextEncoder().encode(data)); }
  async openInputChannel() {
    if (this.inputAttempted || this.inputNegotiating || this.sending || this.disposed || this.blocked || !this.ready || !window.AutoApproveInputChannel || !this.streaming) return;
    this.inputAttempted = true;
    this.inputNegotiating = true;
    const candidate = new window.AutoApproveInputChannel(this.nodeID,{mode:'pty',ptyID:this.descriptor.ptyID,streamID:this.descriptor.streamID,clientID:this.clientID,sequenceBase:this.sequence},{
      onChange:() => { if (!this.disposed && this.inputChannel === candidate) { this.sending = candidate.pendingCount > 0; if (this.ready && this.queue.length) void this.flush(); } },
      onFailure:error => {
        if (this.disposed || this.inputChannel !== candidate) return;
        if (error.recoverable && !candidate.pendingCount) this.recoverInputChannel(); else this.fail(error);
      },
      onQuality:value => { if (!this.disposed) { this.inputQuality = value; this.report('quality','',this); } }
    });
    this.inputCandidate = candidate;
    try {
      const channel = await candidate.open();
      if (this.disposed || this.blocked) { channel?.close(); return; }
      this.inputChannel = channel;
      if (channel) this.inputStableAt = performance.now();
      if (this.ready) this.report('live','PTY 실시간 연결됨',this);
    } catch (error) { if (!this.disposed) this.fail(error); }
    finally { this.inputCandidate = null; this.inputNegotiating = false; if (!this.disposed && this.ready && this.queue.length) void this.flush(); }
  }
  recoverInputChannel() {
    if (performance.now()-(this.inputStableAt || 0) > 30000) this.inputRetries = 0;
    this.inputRetries++; this.inputChannel = null; this.sending = false; this.inputQuality = null; this.report('quality','',this);
    if (this.inputRetries > 3) { this.inputNegotiating = false; if (this.ready && this.queue.length) void this.flush(); return; }
    this.inputNegotiating = true; const epoch = ++this.inputEpoch;
    this.report('waiting','입력 연결 복구 중…',this);
    this.inputRetryTimer = setTimeout(() => {
      if (this.disposed || this.blocked || epoch !== this.inputEpoch) return;
      this.inputNegotiating = false; this.inputAttempted = false;
      if (this.ready) void this.openInputChannel();
    },Math.min(2000,250*2**(this.inputRetries-1)));
  }
  takeQueued(length) {
    const next = new Uint8Array(length);
    for (let at = 0; at < length;) {
      const item = this.queue[0], count = Math.min(item.length,length-at);
      next.set(item.subarray(0,count),at); at += count;
      if (count === item.length) this.queue.shift(); else this.queue[0] = item.slice(count);
    }
    return next;
  }
  flushChannel() {
    clearTimeout(this.inputTimer); this.inputTimer = null;
    while (!this.disposed && this.ready && this.queue.length && this.inputChannel?.state === 'ready') {
      const length = Math.min(16000,this.queue.reduce((sum,item) => sum+item.length,0));
      if (!this.inputChannel.canSend(length)) break;
      const next = this.takeQueued(length);
      if (this.inputChannel.send(2,next)) this.sequence++;
      else { this.queue.unshift(next); break; }
    }
    this.sending = (this.inputChannel?.pendingCount || 0) > 0;
  }
  enqueueBytes(bytes) {
    if (!this.ready || this.disposed || !bytes.length) return;
    if (this.queue.reduce((sum, item) => sum + item.length, 0) + bytes.length > 128000) { this.fail(new Error('미전달 입력이 너무 많아 입력을 멈췄습니다. 화면을 확인해주세요.')); return; }
    for (let at = 0; at < bytes.length; at += 16000) this.queue.push(bytes.slice(at, at + 16000));
    // A fixed short window coalesces one event-loop burst without starving
    // continuous typing. The active writer drains everything arriving in flight.
    if (this.inputChannel?.state === 'ready') {
      // The first event leaves immediately; only subsequent bursts coalesce.
      if (!this.sending) void this.flush();
      else if (this.inputTimer == null) this.inputTimer = setTimeout(() => { this.inputTimer = null; void this.flush(); },4);
    } else if (!this.sending && this.inputTimer == null) this.inputTimer = setTimeout(() => { this.inputTimer = null; void this.flush(); },0);
  }
  async flush() {
    if (this.inputNegotiating) return;
    if (this.inputChannel?.state === 'ready') { this.flushChannel(); return; }
    if (this.sending || this.disposed || !this.ready || !this.queue.length) return;
    if (!this.inputAttempted && window.AutoApproveInputChannel) { void this.openInputChannel(); return; }
    clearTimeout(this.inputTimer); this.inputTimer = null;
    this.sending = true;
    // Merge only unsent bytes, within the server's existing per-request limit.
    // Keep one acknowledged request in flight; an uncertain write is never replayed.
    const length = Math.min(16000, this.queue.reduce((sum, item) => sum + item.length, 0));
    const next = this.takeQueued(length);
    try {
      const data = btoa(Array.from(next, byte => String.fromCharCode(byte)).join(''));
      const sequence = ++this.sequence;
      const result = await this.post('/api/pty/input', {sequence, data});
      if (!result.accepted || result.sequence !== sequence) throw new Error('입력 결과를 확인하지 못했습니다. 다시 보내지 말고 화면을 확인해주세요.');
    } catch (error) { if (!this.disposed) this.fail(error); }
    finally { this.sending = false; if (this.ready && !this.disposed && this.queue.length) void this.flush(); }
  }
  fail(error) {
    clearTimeout(this.inputRetryTimer); this.inputEpoch++;
    this.inputChannel?.close(); this.inputCandidate?.close(); this.inputChannel = null;
    this.inputQuality = null; this.sending = false; this.report('quality','',this);
    clearTimeout(this.inputTimer); this.inputTimer = null;
    clearTimeout(this.retryTimer); this.retryTimer = null;
    this.closeStream(); this.outputQueue = []; this.outputBytes = 0;
    this.blocked = true; this.ready = false; this.error = error.message; this.term.options.disableStdin = true;
    const bytes = this.queue.flatMap(item => Array.from(item)); this.queue = [];
    if (bytes.length) this.unsent = (this.unsent || '') + new TextDecoder().decode(new Uint8Array(bytes));
    this.report('error', this.error, this);
  }
  key(kind) {
    if (!this.ready) return;
    const prefix = this.term.modes.applicationCursorKeysMode ? '\x1bO' : '\x1b[';
    const keys = {enter:'\r',escape:'\x1b',interrupt:'\x03',eof:'\x04',tab:'\t',up:prefix+'A',down:prefix+'B',right:prefix+'C',left:prefix+'D',backspace:'\x7f'};
    if (keys[kind]) { this.term.focus(); this.enqueue(keys[kind]); }
  }
  focus() { if (this.ready) this.term.focus(); }
  font(value) { this.term.options.fontSize = value; this.fit(); }
  dispose() {
    clearTimeout(this.inputRetryTimer); this.inputEpoch++;
    this.inputChannel?.close(); this.inputCandidate?.close(); this.inputChannel = null;
    this.disposed = true; this.closeStream(); this.outputQueue = []; this.outputBytes = 0; clearTimeout(this.retryTimer); clearTimeout(this.inputTimer); clearTimeout(this.resizeTimer); this.observer.disconnect();
    this.container.removeEventListener('pointerup', this.focusListener);
    this.container.removeEventListener('pointerdown', this.pointerListener);
    const remaining = this.queue.flatMap(item => Array.from(item)); this.queue = [];
    this.term.dispose(); this.container.replaceChildren();
    return (this.unsent || '') + new TextDecoder().decode(new Uint8Array(remaining));
  }
};
