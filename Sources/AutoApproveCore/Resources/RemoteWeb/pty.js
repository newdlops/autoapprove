'use strict';
// Raw PTY bytes are interpreted by xterm, never inserted as HTML or locally echoed.
window.AutoApprovePTY = class {
  constructor(container, descriptor, nodeID, api, uuid, report, fontSize = 14, streaming = true) {
    this.container = container; this.descriptor = descriptor; this.nodeID = nodeID; this.api = api; this.uuid = uuid; this.report = report;
    this.streaming = streaming;
    this.clientID = uuid(); this.sequence = 0; this.offset = null; this.queue = []; this.sending = false; this.disposed = false; this.ready = false; this.blocked = false;
    this.outputQueue = []; this.outputBytes = 0; this.writing = false; this.outputPaused = false; this.source = null;
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
    if (this.disposed || !this.streaming || this.resizing || this.ending || this.descriptor.exitCode != null) return;
    this.resizing = true;
    const columns = this.term.cols, rows = this.term.rows;
    try { if (columns !== this.descriptor.columns || rows !== this.descriptor.rows) { await this.post('/api/pty/resize', {columns, rows}); this.descriptor.columns = columns; this.descriptor.rows = rows; } }
    catch (error) { if (!this.disposed) { if (error.status === 409) this.resizePending = true; else this.fail(error); } }
    finally { this.resizing = false; if (!this.disposed && (this.term.cols !== columns || this.term.rows !== rows)) void this.resize(); }
  }
  run() {
    if (this.disposed || this.blocked || document.hidden) return;
    if (this.streaming) { this.openStream(); void this.resize(); }
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
  closeStream() { this.source?.close(); this.source = null; }
  openStream() {
    if (this.disposed || this.blocked || !this.streaming || document.hidden || this.source) return;
    try {
      const query = new URLSearchParams({ node: this.nodeID, pty: this.descriptor.ptyID, stream: this.descriptor.streamID, client: this.clientID });
      // Only a fully rendered offset is safe to resume. A new xterm starts from
      // the native current-screen snapshot, including the alternate buffer.
      if (this.offset !== null) query.set('offset', String(this.offset));
      const source = new EventSource('/api/pty/stream?' + query); this.source = source;
      source.addEventListener('output', event => {
        if (this.disposed || this.source !== source) return;
        try { this.receive(JSON.parse(event.data)); } catch (error) { this.fail(error); }
      });
      source.addEventListener('failure', event => {
        if (this.disposed || this.source !== source) return;
        let message;
        try { message = JSON.parse(event.data).error; } catch (_) {}
        this.fail(new Error(message || 'PTY 출력 연결이 끊겼습니다. 화면을 다시 연결해주세요.'));
      });
      source.onerror = () => {
        if (!this.disposed && this.source === source) this.fail(new Error('PTY 출력 연결이 끊겼습니다. 화면을 다시 연결해주세요.'));
      };
    } catch (error) { this.fail(error); }
  }
  receive(update) {
    if (update.streamID !== this.descriptor.streamID || update.ptyID !== this.descriptor.ptyID || !Number.isSafeInteger(update.offset) || update.offset < 0 || typeof update.data !== 'string') throw new Error('PTY 연결이 바뀌었습니다. 다시 연결해주세요.');
    const singleLimit = update.reset ? this.maxSnapshotBytes : this.maxOutputBytes;
    if (update.data.length > Math.ceil(singleLimit / 3) * 4) throw new Error('터미널 출력이 너무 큽니다. 화면을 다시 연결해주세요.');
    const bytes = Uint8Array.from(atob(update.data), char => char.charCodeAt(0));
    if (bytes.length > singleLimit) throw new Error('터미널 출력이 너무 큽니다. 화면을 다시 연결해주세요.');
    if (this.outputBytes + bytes.length > this.maxOutputBytes && (this.writing || this.outputQueue.length) || this.outputQueue.length >= this.maxOutputEvents) {
      // Stop receiving before xterm's own async write queue can grow. Drain the
      // bounded queue, then resume its committed offset or the native snapshot.
      this.closeStream(); this.outputPaused = true;
      this.report('waiting', '터미널 출력 반영 중…', this);
      return;
    }
    this.outputQueue.push({update, bytes}); this.outputBytes += bytes.length;
    if (update.exitCode != null) { this.closeStream(); this.ending = true; this.ready = false; this.term.options.disableStdin = true; }
    void this.renderOutput();
  }
  async renderOutput() {
    if (this.writing || this.disposed) return;
    this.writing = true;
    try {
      while (this.outputQueue.length && !this.disposed) {
        const {update, bytes} = this.outputQueue.shift();
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
        this.ready = this.streaming && !this.blocked && !this.ending && update.exitCode == null && update.canInput !== false; this.term.options.disableStdin = !this.ready;
        this.report(update.exitCode != null ? 'ended' : this.blocked ? 'blocked' : !this.streaming ? 'readonly' : this.outputPaused || !this.ready ? 'waiting' : 'live', update.exitCode != null ? 'PTY 종료 · 코드 ' + update.exitCode : this.blocked ? this.error : !this.streaming ? '화면 보기 · Mac 업데이트 필요' : this.ending ? 'PTY 마지막 출력 반영 중…' : this.outputPaused ? '터미널 출력 반영 중…' : this.ready ? 'PTY 실시간 연결됨' : '출력 연결됨 · 다른 브라우저 입력 대기', this);
        if (this.ready && this.resizePending) { this.resizePending = false; void this.resize(); }
        if (this.ready && this.queue.length) void this.flush();
        if (update.exitCode != null) { this.term.options.cursorBlink = false; return; }
      }
    } catch (error) { if (!this.disposed) this.fail(error); }
    finally {
      this.writing = false;
      if (!this.disposed && !this.blocked && this.outputPaused) { this.outputPaused = false; this.openStream(); }
    }
  }
  enqueue(data) { this.enqueueBytes(new TextEncoder().encode(data)); }
  enqueueBytes(bytes) {
    if (!this.ready || this.disposed || !bytes.length) return;
    if (this.queue.reduce((sum, item) => sum + item.length, 0) + bytes.length > 128000) { this.fail(new Error('미전달 입력이 너무 많아 입력을 멈췄습니다. 화면을 확인해주세요.')); return; }
    for (let at = 0; at < bytes.length; at += 16000) this.queue.push(bytes.slice(at, at + 16000));
    clearTimeout(this.inputTimer); this.inputTimer = setTimeout(() => void this.flush(), 15);
  }
  async flush() {
    if (this.sending || this.disposed || !this.ready || !this.queue.length) return;
    this.sending = true;
    const next = this.queue.shift();
    try {
      const data = btoa(Array.from(next, byte => String.fromCharCode(byte)).join(''));
      const sequence = ++this.sequence;
      const result = await this.post('/api/pty/input', {sequence, data});
      if (!result.accepted || result.sequence !== sequence) throw new Error('입력 결과를 확인하지 못했습니다. 다시 보내지 말고 화면을 확인해주세요.');
    } catch (error) { if (!this.disposed) this.fail(error); }
    finally { this.sending = false; if (this.ready && !this.disposed && this.queue.length) void this.flush(); }
  }
  fail(error) {
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
    this.disposed = true; this.closeStream(); this.outputQueue = []; this.outputBytes = 0; clearTimeout(this.inputTimer); clearTimeout(this.resizeTimer); this.observer.disconnect();
    this.container.removeEventListener('pointerup', this.focusListener);
    this.container.removeEventListener('pointerdown', this.pointerListener);
    const remaining = this.queue.flatMap(item => Array.from(item)); this.queue = [];
    this.term.dispose(); this.container.replaceChildren();
    return (this.unsent || '') + new TextDecoder().decode(new Uint8Array(remaining));
  }
};
