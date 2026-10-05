import { test } from 'node:test';
import assert from 'node:assert/strict';
import Module from 'node:module';
import { EventEmitter } from 'node:events';

test('original VT execution survives app reconnection and native input uses the same existing terminal', async () => {
  const callbacks = new Map<string, (event: any) => void>();
  const disposable = { dispose() {} };
  const event = (name: string) => (callback: (value: any) => void) => { callbacks.set(name, callback); return disposable; };
  const writes: string[] = [], commands: string[] = [], sockets: FakeSocket[] = [];
  class FakeSocket extends EventEmitter {
    destroyed = false; writableLength = 0; messages: any[] = [];
    setEncoding() { return this; }
    write(value: string) { this.messages.push(JSON.parse(value)); return true; }
    destroy() { if (!this.destroyed) { this.destroyed = true; this.emit('close'); } return this; }
  }
  const terminal = { name: 'existing-codex', processId: Promise.resolve(4200),
    show() { window.activeTerminal = terminal; }, sendText(text: string, append: boolean) { assert.equal(append, false); writes.push(text); } };
  const window: any = {
    terminals: [terminal], activeTerminal: terminal, state: { focused: true }, activeColorTheme: { kind: 2 },
    createOutputChannel: () => ({ ...disposable, appendLine() {}, show() {} }),
    createStatusBarItem: () => ({ ...disposable, show() {} }),
    onDidOpenTerminal: event('open'), onDidCloseTerminal: event('close'),
    onDidStartTerminalShellExecution: event('start'), onDidEndTerminalShellExecution: event('end'),
    onDidChangeActiveTerminal: event('selection'), onDidChangeWindowState: event('focus'),
    onDidChangeActiveColorTheme: event('theme'), setStatusBarMessage: () => disposable,
    showInformationMessage: async () => undefined, showWarningMessage: async () => undefined
  };
  const api = { window, StatusBarAlignment: { Right: 2 }, env: {},
    workspace: { getConfiguration: () => ({ get: (_name: string, fallback: any) => fallback }), onDidChangeConfiguration: event('config') },
    extensions: { all: [], onDidChange: event('extensions') },
    commands: { registerCommand: () => disposable, executeCommand: async (name: string) => { commands.push(name); window.state.focused = true; } } };
  const loader = Module as unknown as { _load: (request: string, parent: any, main: boolean) => unknown };
  const load = loader._load, interval = global.setInterval, clearInterval = global.clearInterval, timeout = global.setTimeout, clearTimeout = global.clearTimeout;
  let heartbeat: () => void = () => {}, reconnect: () => void = () => {};
  loader._load = function(request, parent, main) {
    if (request === 'vscode') { return api; }
    if (request === 'node:net') { return { createConnection: () => { const socket = new FakeSocket(); sockets.push(socket); return socket; } }; }
    return load.call(this, request, parent, main);
  };
  global.setInterval = ((callback: () => void) => { heartbeat = callback; return {} as NodeJS.Timeout; }) as typeof global.setInterval;
  global.clearInterval = (() => {}) as typeof global.clearInterval;
  global.setTimeout = ((callback: () => void, delay?: number, ...args: any[]) => {
    if (delay === 2000) { reconnect = callback; return {} as NodeJS.Timeout; }
    return timeout(callback, delay, ...args);
  }) as typeof global.setTimeout;
  global.clearTimeout = (() => {}) as typeof global.clearTimeout;
  let pending: ((value: IteratorResult<string>) => void) | undefined;
  const stream = { [Symbol.asyncIterator]() { return this; }, next: () => new Promise<IteratorResult<string>>(resolve => { pending = resolve; }) };
  const output = async (value: string) => {
    for (let count = 0; !pending && count < 100; count++) { await new Promise(resolve => timeout(resolve, 5)); }
    assert.ok(pending, 'The original execution reader remains attached');
    const resolve = pending!; pending = undefined; resolve({ done: false, value });
    await new Promise(resolve => timeout(resolve, 25));
  };
  let extension: typeof import('./extension') | undefined;
  try {
    extension = require('./extension'); extension!.activate({ subscriptions: [] } as any);
    await new Promise(resolve => timeout(resolve, 0));
    const execution = { read: () => stream };
    callbacks.get('start')!({ terminal, execution });
    await output('\x1b[31moriginal\x1b[0m');
    sockets[0].emit('connect'); heartbeat();
    const registration = sockets[0].messages.find(message => message.method === 'register').params.terminals[0];
    assert.equal(registration.streamAttached, true, 'A command started while the app is offline remains attached');
    const identity = registration.id;
    sockets[0].destroy(); await output('\r\nMac output while app restarts');
    reconnect(); sockets[1].emit('connect'); heartbeat();
    const second = sockets[1].messages.find(message => message.method === 'register').params.terminals[0];
    assert.equal(second.id, identity); assert.equal(second.streamAttached, true);
    const screen = sockets[1].messages.find(message => message.method === 'screen');
    assert.ok(screen.params.screen.includes('Mac output while app restarts'));
    assert.equal(screen.params.appearance.runs[0].fg, '#cd3131');
    const reveal = { method: 'reveal', id: 'connect-original', terminalID: identity, native: true,
      generation: second.nativeGeneration, expiresAt: Date.now() + 1000 };
    sockets[0].emit('data', JSON.stringify(reveal) + '\n');
    sockets[1].emit('data', JSON.stringify({ ...reveal, id: 'expired', expiresAt: Date.now() - 1 }) + '\n');
    sockets[1].emit('data', JSON.stringify({ ...reveal, id: 'stale', generation: 'old generation' }) + '\n');
    assert.deepEqual(commands, [], 'Retired sockets and stale reveals never activate a source window');
    assert.match(second.windowToken, /^[a-f0-9-]{36}$/);
    window.terminals.push({ ...terminal, processId: Promise.resolve(4201) });
    sockets[1].emit('data', JSON.stringify({ ...reveal, id: 'duplicate-screen', view: 'screen' }) + '\n');
    await new Promise(resolve => timeout(resolve, 0));
    assert.deepEqual(commands, [], 'Duplicate names cannot identify a Mac window preview');
    sockets[1].emit('data', JSON.stringify(reveal) + '\n');
    await new Promise(resolve => timeout(resolve, 0));
    assert.deepEqual(commands, ['workbench.action.focusWindow'], 'Normal input reveals the exact existing terminal even when another terminal has the same name');
    const native = sockets[1].messages.filter(message => message.method === 'register').at(-1).params.terminals[0];
    assert.equal(native.selected, true);
    const input = { method: 'remoteInput', id: 'phone-key', terminalID: identity, native: true, generation: native.nativeGeneration,
      expiresAt: Date.now() + 1000, kind: 'characters', text: '한글 🧪', relay: true };
    sockets[1].emit('data', JSON.stringify(input) + '\n'); sockets[1].emit('data', JSON.stringify(input) + '\n');
    assert.deepEqual(writes, ['한글 🧪'], 'Only one write reaches the same existing terminal object');
    window.state.focused = false; callbacks.get('focus')!({ focused: false });
    sockets[1].emit('data', JSON.stringify({ ...input, id: 'after-focus-change' }) + '\n');
    assert.deepEqual(writes, ['한글 🧪']);
    callbacks.get('end')!({ terminal, execution }); heartbeat();
    assert.equal(sockets[1].messages.filter(message => message.method === 'register').at(-1).params.terminals[0].streamAttached, false);
  } finally {
    extension?.deactivate(); pending?.({ done: true, value: undefined });
    loader._load = load; global.setInterval = interval; global.clearInterval = clearInterval; global.setTimeout = timeout; global.clearTimeout = clearTimeout;
  }
});
