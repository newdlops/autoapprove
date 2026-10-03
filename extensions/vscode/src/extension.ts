import * as vscode from 'vscode';
import * as net from 'node:net';
import * as os from 'node:os';
import * as path from 'node:path';
import { randomUUID } from 'node:crypto';
import { ScreenMirror } from './screen';
import { readThemeColors, resolveTerminalTheme } from './theme';

type TerminalState = { id: string; terminal: vscode.Terminal; shellPID?: number; mirror?: ScreenMirror; execution?: vscode.TerminalShellExecution; executionActive?: boolean };
let connection: net.Socket | undefined;
let reconnectTimer: NodeJS.Timeout | undefined;
let heartbeat: NodeJS.Timeout | undefined;
let stopped = false;
let connected = false;
const terminals = new Map<vscode.Terminal, TerminalState>();
let status: vscode.StatusBarItem;
let output: vscode.OutputChannel;
let revealStatus: vscode.Disposable | undefined;
let themeColors: Record<string, unknown> = {};
let themeGeneration = 0;

export function activate(context: vscode.ExtensionContext): void {
  output = vscode.window.createOutputChannel('AutoApprove');
  status = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 20);
  status.command = 'autoapprove.showStatus';
  context.subscriptions.push(output, status);
  context.subscriptions.push(vscode.commands.registerCommand('autoapprove.showStatus', () => output.show()));
  if (process.platform !== 'darwin' || vscode.env.remoteName) {
    output.appendLine('현재 버전은 로컬 macOS 터미널만 지원합니다.');
    return;
  }
  context.subscriptions.push(vscode.commands.registerCommand('autoapprove.reconnect', () => { connection?.destroy(); connect(); }));
  context.subscriptions.push(vscode.window.onDidOpenTerminal(terminal => { void registerTerminal(terminal); }));
  context.subscriptions.push(vscode.window.onDidCloseTerminal(terminal => {
    terminals.get(terminal)?.mirror?.dispose(); terminals.delete(terminal); sendRegistration();
  }));
  context.subscriptions.push(vscode.window.onDidStartTerminalShellExecution(event => {
    // read() must be called synchronously with the start event, before waiting for processId.
    const stream = event.execution.read();
    const state = ensureTerminal(event.terminal);
    state.mirror?.dispose();
    const mirror = new ScreenMirror();
    if (!connected) { mirror.invalidate(); }
    state.mirror = mirror; state.execution = event.execution; state.executionActive = true;
    void registerTerminal(event.terminal);
    void (async () => {
      try {
        for await (const data of stream) {
          if (state.mirror !== mirror || stopped) { break; }
          await mirror.write(data);
        }
      } catch { mirror.invalidate(); }
      if (state.mirror === mirror) { mirror.invalidate(); sendRegistration(); }
    })();
  }));
  context.subscriptions.push(vscode.window.onDidEndTerminalShellExecution(event => {
    const state = terminals.get(event.terminal);
    if (state?.execution === event.execution) { state.mirror?.invalidate(); state.execution = undefined; state.executionActive = false; sendRegistration(); }
  }));
  context.subscriptions.push(vscode.workspace.onDidChangeConfiguration(event => {
    if (event.affectsConfiguration('autoapprove.socketPath')) { connection?.destroy(); connect(); }
    if (event.affectsConfiguration('workbench.colorTheme')) { void refreshThemeColors(); }
  }));
  context.subscriptions.push(vscode.window.onDidChangeActiveColorTheme(() => { void refreshThemeColors(); }));
  context.subscriptions.push(vscode.extensions.onDidChange(() => { void refreshThemeColors(); }));
  void refreshThemeColors();
  for (const terminal of vscode.window.terminals) { void registerTerminal(terminal); }
  status.show(); connect();
  let tick = 0;
  heartbeat = setInterval(() => {
    if (!connected) { return; }
    if (tick++ % 8 === 0) { sendRegistration(); }
    for (const state of terminals.values()) {
      if (state.mirror?.valid) {
        const theme = terminalColors();
        send('screen', { terminalID: state.id, screen: state.mirror.snapshot(), appearance: state.mirror.appearance(theme.palette, theme.defaults, theme.boldIsBright), generation: state.mirror.generation });
      }
    }
  }, 250);
}

async function refreshThemeColors(): Promise<void> {
  const generation = ++themeGeneration, name = vscode.workspace.getConfiguration('workbench').get<string>('colorTheme', '');
  for (const extension of vscode.extensions.all) {
    const themes = extension.packageJSON.contributes?.themes;
    if (!Array.isArray(themes)) { continue; }
    const theme = themes.find((value: any) => value.id === name || value.label === name);
    if (!theme || typeof theme.path !== 'string') { continue; }
    const colors = await readThemeColors(path.resolve(extension.extensionPath, theme.path));
    if (generation === themeGeneration) { themeColors = colors; }
    return;
  }
  if (generation === themeGeneration) { themeColors = {}; }
}
function terminalColors() {
  const config = vscode.workspace.getConfiguration('workbench');
  const custom = config.get<Record<string, unknown>>('colorCustomizations', {});
  const name = config.get<string>('colorTheme', '');
  return resolveTerminalTheme(themeColors, custom, name, vscode.window.activeColorTheme.kind,
    vscode.workspace.getConfiguration('terminal.integrated').get<string>('defaultLocation') === 'editor',
    vscode.workspace.getConfiguration('terminal.integrated').get<boolean>('drawBoldTextInBrightColors', true));
}

function ensureTerminal(terminal: vscode.Terminal): TerminalState {
  let state = terminals.get(terminal);
  if (!state) { state = { id: randomUUID(), terminal }; terminals.set(terminal, state); }
  return state;
}
async function registerTerminal(terminal: vscode.Terminal): Promise<void> {
  const state = ensureTerminal(terminal);
  state.shellPID = await terminal.processId;
  if (terminals.has(terminal)) { sendRegistration(); }
}
function sendRegistration(): void {
  send('register', { terminals: Array.from(terminals.values()).map(state => ({
    id: state.id, shellPID: state.shellPID, name: state.terminal.name, streamAttached: state.mirror?.valid === true, executionActive: state.executionActive, remoteInputVersion: 2
  })) });
}
function send(method: string, params: Record<string, unknown>): void {
  if (connected && connection && !connection.destroyed) {
    if (connection.writableLength > 1_000_000) { connection.destroy(); return; }
    connection.write(JSON.stringify({ id: randomUUID(), method, params }) + '\n');
  }
}
function connect(): void {
  if (stopped || connection && !connection.destroyed) { return; }
  if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = undefined; }
  const custom = vscode.workspace.getConfiguration('autoapprove').get<string>('socketPath', '');
  const socketPath = custom || path.join(process.env.AUTOAPPROVE_HOME || path.join(os.homedir(), 'Library/Application Support/AutoApprove'), 'bridge.sock');
  let buffer = '';
  const socket = net.createConnection(socketPath);
  connection = socket;
  socket.setEncoding('utf8');
  socket.on('connect', () => {
    if (socket !== connection) { socket.destroy(); return; }
    connected = true; status.text = '$(link) AutoApprove'; status.tooltip = '로컬 앱 연결됨 · 클릭하여 연결 로그 보기';
    output.appendLine('AutoApprove 앱에 연결했습니다.'); sendRegistration();
  });
  socket.on('data', (data: string) => {
    buffer += data;
    if (Buffer.byteLength(buffer) > 2_000_000) { socket.destroy(); return; }
    let index: number;
    while ((index = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
      try { handleMessage(JSON.parse(line) as Record<string, any>); }
      catch { output.appendLine('올바르지 않은 앱 메시지를 무시했습니다.'); }
    }
  });
  socket.on('error', () => { /* close handles reconnection without logging private terminal content. */ });
  socket.on('close', () => {
    if (socket !== connection) { return; }
    connected = false;
    for (const state of terminals.values()) { state.mirror?.invalidate(); }
    status.text = '$(debug-disconnect) AutoApprove'; status.tooltip = '앱 연결 대기. 연결이 끊긴 출력은 다음 명령부터 다시 연결됩니다.';
    if (!stopped) { reconnectTimer = setTimeout(connect, 2000); }
  });
}

function handleMessage(message: Record<string, any>): void {
  if (message.method === 'remoteInput') {
    const state = Array.from(terminals.values()).find(state => state.id === message.terminalID);
    const success = connected && !!state?.execution && !!state.mirror?.consumeInput(message);
    if (success) {
      const keys: Record<string, string> = { enter: '\r', escape: '\x1b', interrupt: '\x03', up: '\x1b[A', down: '\x1b[B', left: '\x1b[D', right: '\x1b[C', backspace: '\x7f', delete: '\x1b[3~', home: '\x1b[H', end: '\x1b[F', tab: '\t' };
      state!.terminal.sendText(message.kind === 'submit' ? message.text + '\r' : ['text', 'characters'].includes(message.kind) ? message.text : keys[message.kind], false);
    }
    send('remoteInputResult', { actionID: message.id, success });
    return;
  }
  const sizes = message.result?.terminalSizes;
  if (sizes && typeof sizes === 'object') {
    for (const state of terminals.values()) { const size = sizes[state.id]; if (size) { state.mirror?.resize(size.columns, size.rows); } }
  }
  if (message.method === 'reveal') {
    const state = Array.from(terminals.values()).find(state => state.id === message.terminalID);
    if (state) {
      state.terminal.show(false);
      const label = typeof message.label === 'string' ? message.label.slice(0, 120) : state.terminal.name;
      const detail = typeof message.detail === 'string' ? message.detail.slice(0, 160) : state.terminal.name;
      void vscode.window.showInformationMessage(`열린 터미널: ${label} · ${detail}`);
      revealStatus?.dispose();
      revealStatus = vscode.window.setStatusBarMessage(`$(terminal) 열린 터미널: ${label.replace(/\$\(/g, '(')}`, 3000);
    } else {
      void vscode.window.showWarningMessage('대상 터미널이 닫혔습니다. AutoApprove에서 목록을 새로고침해주세요.');
    }
  }
  if (message.method === 'approve') {
    const state = Array.from(terminals.values()).find(state => state.id === message.terminalID);
    const success = connected && typeof message.id === 'string' && typeof message.fingerprint === 'string'
      && (message.dialog === undefined || typeof message.dialog === 'string')
      && typeof message.generation === 'string' && typeof message.expiresAt === 'number'
      && !!state?.execution && !!state.mirror?.consume(message as { id: string; fingerprint: string; generation: string; expiresAt: number; answer: string });
    // No await between final validation and this write. Only the matched terminal object is used.
    if (success) { state!.terminal.sendText('1\r', false); }
    send('actionResult', { actionID: message.id, success });
  }
}

export function deactivate(): void {
  stopped = true; connected = false;
  revealStatus?.dispose();
  if (heartbeat) { clearInterval(heartbeat); }
  if (reconnectTimer) { clearTimeout(reconnectTimer); }
  connection?.destroy();
  for (const state of terminals.values()) { state.mirror?.dispose(); }
  terminals.clear();
}
