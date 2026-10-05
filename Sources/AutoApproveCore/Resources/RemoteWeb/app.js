'use strict';
const $ = id => document.getElementById(id);
const text = (element, value) => { const next = String(value ?? ''); if (element.textContent !== next) element.textContent = next; };
const show = (element, visible) => { element.hidden = !visible; };
const make = (tag, className, value) => { const element = document.createElement(tag); if (className) element.className = className; if (value !== undefined) text(element, value); return element; };
const uuid = () => typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, c => (Number(c) ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> Number(c) / 4).toString(16));
const agents = { codex: 'Codex', claude: 'Claude Code', shell: '셸' };
const hosts = { terminal: 'Terminal', iterm: 'iTerm2', orca: 'Orca', tmux: 'tmux', pty: 'PTY', vscode: 'VS Code', claudeBackground: 'Claude 백그라운드', unknown: '터미널 미확인' };
let nodes = [], allSessions = [], selectedKey = '', selectedItem = null, filter = 'all', latestFrame = null;
let connected = false, loadingNetwork = false, loadingFrame = false, mutation = false, networkTimer, frameTimer, feedbackTimer;
let detailGeneration = 0, questionSignature = '', historySignature = '';
let frameController = null, quietFrames = 0, fastFrameUntil = 0;
let terminalStream = null, terminalPending = null, terminalPaint = 0, terminalStreamFailed = '';
let terminalFrameReceivedAt = -Infinity, terminalPendingAt = -Infinity;
const terminalFrameFresh = () => !!latestFrame && !terminalStream?.reconnecting && performance.now() - terminalFrameReceivedAt < 10000;
let nativeSessionKey = '', nativeZoom = 1, nativeZoomLimit = 4, nativeImageValue = null, nativeConnectingKey = '';
const nativeTerminal = () => !!selectedItem && !selectedItem.view.pty && nativeSessionKey === selectedKey;
const nativeConnection = () => !!selectedItem && !selectedItem.view.pty && selectedItem.session.terminal !== 'tmux' && (supportsNativeTerminal(selectedItem.node) || !!latestFrame?.nativeDisplay);
let terminalValue = null, terminalRows = [], terminalAppearanceKey = null;
let terminalFollowScroll = null;
let lastNetworkUpdate = null;
let lastNetworkStartedAt = -Infinity;
let directMode = false, composing = false, directSending = false, inputInFlight = false, directTimer, inputFailure = '';
let composePreferred = false, composeMode = false;
const keyboardMarker = '\u200b';
let inputGeneration = 0, terminalFontSize = 14;
let directStreamID = null;
let cursorLayoutPending = false;
const directQueue = [];
const rows = new Map(), machineRows = new Map(), drafts = new Map(), questionDrafts = new Map();
const structuredDrafts = new Map(), messageDrafts = new Map();
const questionDeliveries = new Map(), questionEditing = new Map();
let queueSnapshot = null, queueLoading = false, queueGeneration = 0, queueSessionKey = '';
const queueConversations = new Map();
let screenStarting = false, screenStartNode = null;
let webFormSignature = '', screenListSignature = '', sharedScreen = null, sharedScreenTimer, sharedScreenController;
let messageSending = false, messageUncertain = new Set(), interactionLinkOpened = false;
const keyFor = (node, session, view) => `${node.id}/${view?.ptyID ? 'pty:' + view.ptyID : session.id}`;
let ptyClient = null;
const ptyDrafts = new Map();
const ptyTemporary = new Map(), ptyRetained = new Map();
const retainedPTYStorage = 'autoapprove-ended-ptys';
const sessionEnded = item => item?.session.phase === 'ended' || item?.view.pty?.exitCode != null || item?.view.pty?.closed === true;
function retainEndedPTY(item) {
  item.session.phase = 'ended'; item.session.automatic = false;
  item.session.detail = 'PTY가 종료되었습니다. 마지막 출력은 계속 볼 수 있습니다.';
  item.view.phaseTitle = '종료'; item.view.canApprove = false;
  ptyRetained.set(item.key, item); ptyTemporary.delete(item.key);
  allSessions = allSessions.filter(row => row.key !== item.key);
  try {
    const retained = JSON.parse(sessionStorage.getItem(retainedPTYStorage) || '[]').filter(entry => entry.nodeID !== item.node.id || entry.descriptor?.ptyID !== item.view.ptyID);
    retained.push({nodeID:item.node.id, sessionID:item.session.id, descriptor:{...item.view.pty, closed:true}, title:item.view.title});
    sessionStorage.setItem(retainedPTYStorage, JSON.stringify(retained.slice(-24)));
  } catch (_) {}
}
const supportsRelease = (node, minimum) => {
  const version = versionNumbers(node.state?.release);
  if (!version) return false;
  for (let i = 0; i < minimum.length; i++) if (version[i] !== minimum[i]) return version[i] > minimum[i];
  return true;
};
const supportsPTYStream = node => supportsRelease(node, [0, 2, 41, 48]);
const supportsTerminalStream = node => supportsRelease(node, [0, 2, 42, 49]);
const supportsNativeTerminal = node => supportsRelease(node, [0, 2, 43, 51]);
function reconcilePTYInventory(inventory) {
  inventory = inventory.filter(item => !sessionEnded(item) && !sessionEnded(ptyRetained.get(item.key)));
  for (const [key, temporary] of ptyTemporary) {
    if (sessionEnded(temporary)) { retainEndedPTY(temporary); continue; }
    if (inventory.some(item => item.key === key)) { ptyTemporary.delete(key); continue; }
    const node = nodes.find(node => node.id === temporary.node.id && node.online);
    if (node) inventory.push({...temporary, node});
  }
  return inventory;
}
function descriptorItem(nodeID, descriptor, automatic = false) {
  if (!descriptor || typeof descriptor.ptyID !== 'string' || !descriptor.ptyID || descriptor.ptyID.length > 128 || typeof descriptor.streamID !== 'string' || !descriptor.streamID || descriptor.streamID.length > 128 || typeof descriptor.cwd !== 'string' || descriptor.cwd.length > 8192 || !['shell','codex','claude'].includes(descriptor.program) || !Number.isInteger(descriptor.pid) || descriptor.pid < 1 || !Number.isInteger(descriptor.columns) || descriptor.columns < 20 || descriptor.columns > 240 || !Number.isInteger(descriptor.rows) || descriptor.rows < 5 || descriptor.rows > 100) throw new Error('PTY 연결 정보를 확인하지 못했습니다. 화면을 다시 연결해주세요.');
  const node = nodes.find(node => node.id === nodeID);
  if (!node) throw new Error('Mac 연결을 확인한 뒤 터미널을 다시 선택해주세요.');
  const ended = descriptor.exitCode != null || descriptor.closed === true;
  const session = {id:'pty:' + descriptor.ptyID, agent:descriptor.program, pid:descriptor.pid, started:descriptor.streamID, tty:descriptor.tty, cwd:descriptor.cwd, terminal:'pty', hostName:'PTY', phase:ended ? 'ended' : 'idle', automatic, detail:'화면을 눌러 직접 입력하세요.'};
  const view = {session, title:'PTY · ' + descriptor.cwd.split('/').filter(Boolean).pop(), phaseTitle:ended ? '종료' : '입력 대기', canApprove:false, canReveal:false, canRead:true, keys:[], ptyID:descriptor.ptyID, pty:descriptor};
  const key = keyFor(node, session, view);
  const existing = allSessions.find(item => item.key === key) || ptyRetained.get(key);
  if (existing) {
    if (descriptor.exitCode != null) { existing.view.pty = {...existing.view.pty, ...descriptor}; retainEndedPTY(existing); }
    return existing;
  }
  const item = {node, session, view, key};
  if (sessionEnded(item)) retainEndedPTY(item);
  else { ptyTemporary.set(key, item); allSessions.push(item); }
  return item;
}
function selectPTYDescriptor(nodeID, descriptor, automatic = false, focus = false) {
  const item = descriptorItem(nodeID, descriptor, automatic);
  selectSession(item.key, focus);
  // A slow peer inventory cannot hold up this already-created terminal.
  void refreshNetwork();
}
function stopPTY() {
  if (!ptyClient) return;
  const key = ptyClient.sessionKey, draft = ptyClient.dispose();
  if (draft) ptyDrafts.set(key, (ptyDrafts.get(key) || '') + draft);
  ptyClient = null;
}
function ptyReport(state, message, client) {
  if (client !== ptyClient) return;
  if (selectedItem?.view.pty) selectedItem.view.pty.exitCode = client.descriptor.exitCode;
  if (state === 'ended') { retainEndedPTY(selectedItem); renderDetail(); renderList(); renderMachines(); }
  terminalState(['error', 'blocked'].includes(state) ? 'error' : ['ended','waiting','readonly'].includes(state) ? 'pending' : 'live', message);
  const error = ['error', 'blocked'].includes(state), readonly = state === 'readonly';
  text($('terminal-error'), readonly ? '직접 입력과 실시간 출력은 이 Mac을 AutoApprove 0.2.41 (빌드 48) 이상으로 업데이트하면 사용할 수 있습니다.' : message);
  show($('terminal-error'), error || readonly); text($('terminal-retry'), readonly ? '화면 새로고침' : '화면 다시 연결'); show($('terminal-retry'), error || readonly);
  text($('terminal-time'), nowLabel(new Date()));
  const draft = (ptyDrafts.get(selectedKey) || '') + (client.unsent || '');
  show($('pty-unsent'), !!draft); $('pty-unsent-text').value = draft;
  updateControls();
}
function ensurePTY() {
  const item = selectedItem; if (!item?.view.pty || document.hidden) return;
  const streaming = supportsPTYStream(item.node);
  if (ptyClient?.sessionKey === item.key && ptyClient.streaming === streaming) return;
  stopPTY();
  ptyClient = new AutoApprovePTY($('pty-screen'), {...item.view.pty}, item.node.id, api, uuid, ptyReport, terminalFontSize, streaming);
  ptyClient.sessionKey = item.key;
}
const currentNode = () => nodes.find(node => node.id === selectedItem?.node.id);
const originalStreamSelected = () => !!selectedItem && !selectedItem.view.pty && !sessionEnded(selectedItem)
  && latestFrame?.sessionID === selectedItem.session.id && terminalStreamFailed !== selectedKey
  && (terminalStream?.key === selectedKey && terminalStream.generation === detailGeneration || inputInFlight);
const originalTerminalConnected = () => !!currentNode()?.online || originalStreamSelected();
const nowLabel = date => new Date(date).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
const needsReview = session => ['approval', 'input'].includes(session.phase) || (session.queuedQuestions || []).some(question => !['sending', 'queued'].includes(question.reply?.phase));
const inputKeys = () => latestFrame?.keys || selectedItem?.view.keys || [];
const byteLength = value => new TextEncoder().encode(value).length;
let webInteracted = false, firstWebRefresh = true;
const bundledWebVersion = document.querySelector('meta[name="autoapprove-web-version"]')?.content.split(':');
const loadedWebVersion = bundledWebVersion?.length === 3 ? { version: bundledWebVersion[0], build: Number(bundledWebVersion[1]), api: Number(bundledWebVersion[2]) } : null;
const versionNumbers = release => release?.api === 1 && Number.isInteger(release.build) && release.build > 0 && release.build <= 1000000 && /^(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})\.(0|[1-9]\d{0,5})$/.test(release.version) ? [...release.version.split('.').map(Number), release.build] : null;
const newerVersion = (left, right) => {
  const a = versionNumbers(left), b = versionNumbers(right);
  if (!a || !b) return false;
  for (let i = 0; i < a.length; i++) { if (a[i] !== b[i]) return a[i] > b[i]; }
  return false;
};
function updateWebVersion(result) {
  const initial = firstWebRefresh; firstWebRefresh = false;
  const loaded = versionNumbers(loadedWebVersion) ? loadedWebVersion : result.gatewayRelease;
  let gateway = result.preferredGateway;
  if (!gateway && newerVersion(result.gatewayRelease, loaded)) gateway = { id: result.gatewayID, name: '이 Mac', url: location.origin + '/', release: result.gatewayRelease };
  const online = gateway && result.nodes.some(node => node.id === gateway.id && node.online);
  if (!online || !newerVersion(gateway.release, loaded)) { show($('web-update'), false); return; }
  let url;
  try {
    url = new URL(gateway.url);
    const host = url.hostname, parts = host.split('.').map(Number);
    const privateHost = host === 'localhost' || parts.length === 4 && parts.every(n => Number.isInteger(n) && n >= 0 && n <= 255) && (parts[0] === 127 || parts[0] === 10 || parts[0] === 192 && parts[1] === 168 || parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31 || parts[0] === 169 && parts[1] === 254);
    if (url.protocol !== 'http:' || !privateHost || url.username || url.password || !['', '/'].includes(url.pathname)) throw new Error('invalid gateway');
    url.search = new URLSearchParams({ webNode: gateway.id }).toString(); url.hash = location.hash;
  } catch (_) { show($('web-update'), false); return; }
  const draftPresent = composing || mutation || inputInFlight || directSending || directQueue.length || $('terminal-input').value || [...drafts.values()].some(Boolean) || [...questionDrafts.values()].some(draft => draft.answer || draft.choices.length);
  if (initial && !webInteracted && !draftPresent) { location.replace(url.href); return; }
  text($('web-update-message'), `${gateway.name} · 웹 ${gateway.release.version} (빌드 ${gateway.release.build}). 새 탭에서 열며 초안은 여기에 남습니다.`);
  $('open-latest-web').href = url.href; show($('web-update'), true);
}
for (const event of ['pointerdown', 'keydown', 'input', 'compositionstart']) document.addEventListener(event, () => { webInteracted = true; }, { capture: true, passive: true });
$('open-latest-web').addEventListener('click', () => { const url = new URL($('open-latest-web').href); url.hash = location.hash; $('open-latest-web').href = url.href; });

function updateViewport() {
  const viewport = window.visualViewport;
  document.body.classList.toggle('terminal-compact', (viewport?.height || innerHeight) <= 400);
  document.documentElement.style.setProperty('--terminal-viewport-height', `${viewport?.height || innerHeight}px`);
  document.documentElement.style.setProperty('--terminal-viewport-top', `${viewport?.offsetTop || 0}px`);
}
function terminalFocus(enabled) {
  document.body.classList.toggle('terminal-focus', enabled);
  $('terminal-focus').setAttribute('aria-pressed', String(enabled));
  text($('terminal-focus'), enabled ? '상세 보기' : '크게 보기');
  text($('terminal-heading'), enabled && selectedItem ? selectedItem.view.title : '터미널 화면');
  $('terminal-heading').title = selectedItem?.view.title || '';
  $('terminal-settings').open = false;
  updateViewport();
}
function sizeInput() {
  const input = $('terminal-input'); input.style.height = 'auto'; input.style.height = `${Math.min(96, Math.max(48, input.scrollHeight))}px`;
}
function setFontSize(value) {
  terminalFontSize = Math.min(20, Math.max(12, value));
  $('terminal-screen').style.setProperty('--terminal-font-size', `${terminalFontSize}px`);
  text($('font-size'), `${terminalFontSize}px`);
  $('font-smaller').disabled = terminalFontSize === 12; $('font-larger').disabled = terminalFontSize === 20;
  try { localStorage.setItem('terminal-font-size', String(terminalFontSize)); } catch (_) {}
  scheduleCursor();
  ptyClient?.font(terminalFontSize);
}
function scheduleCursor() {
  if (cursorLayoutPending) return;
  cursorLayoutPending = true;
  requestAnimationFrame(() => { cursorLayoutPending = false; positionCursor(); });
}
function positionCursor() {
  const pre = $('terminal-screen'), caret = $('terminal-cursor'), cursor = latestFrame?.cursor;
  show(caret, false);
  if (nativeTerminal()) {
    const bounds = $('native-screen').getBoundingClientRect(), terminal = pre.parentElement.getBoundingClientRect();
    $('terminal-keyboard').style.left = `${Math.max(12, bounds.left - terminal.left + 12)}px`;
    $('terminal-keyboard').style.top = `${Math.max(48, bounds.bottom - terminal.top - 28)}px`;
    $('terminal-composition').style.left = '12px'; $('terminal-composition').style.top = $('terminal-keyboard').style.top;
    return;
  }
  const value = terminalValue;
  if (!cursor || value === null || !Number.isInteger(cursor.offset) || cursor.offset < 0 || cursor.offset > value.length
    || !Number.isInteger(cursor.padding) || cursor.padding < 0 || cursor.padding > 500 || !['block', 'bar', 'underline'].includes(cursor.style)
    || cursor.offset < value.length && /[\udc00-\udfff]/.test(value[cursor.offset])) return;
  const terminal = pre.parentElement, bounds = pre.getBoundingClientRect(), container = terminal.getBoundingClientRect();
  if (!bounds.width || !bounds.height) return;
  const style = getComputedStyle(pre), lineHeight = parseFloat(style.lineHeight);
  const canvas = document.createElement('canvas'), context = canvas.getContext('2d'); context.font = style.font;
  const cell = context.measureText(' ').width;
  const walker = document.createTreeWalker(pre, NodeFilter.SHOW_TEXT);
  let node, remaining = cursor.offset, rect;
  while ((node = walker.nextNode())) {
    // At a line boundary, prefer the next row's start over the previous newline's end.
    if (remaining === node.length && node.nextSibling === null && walker.nextNode()) { remaining -= node.length; node = walker.currentNode; }
    if (remaining <= node.length) {
      const range = document.createRange(); range.setStart(node, remaining); range.collapse(true);
      rect = range.getBoundingClientRect(); break;
    }
    remaining -= node.length;
  }
  let x = rect?.height ? rect.left : bounds.left + parseFloat(style.paddingLeft) - pre.scrollLeft;
  let y = rect?.height ? rect.top : bounds.top + parseFloat(style.paddingTop) - pre.scrollTop;
  if (cursor.offset === value.length && value.endsWith('\n')) {
    const range = document.createRange(); range.selectNodeContents(pre.lastChild);
    const rectangles = range.getClientRects(), last = rectangles[rectangles.length - 1];
    x = bounds.left + parseFloat(style.paddingLeft) - pre.scrollLeft;
    if (last?.height) y = last.top + lineHeight;
  }
  x += cursor.padding * cell;
  const selection = window.getSelection();
  const selecting = selection && !selection.isCollapsed && pre.contains(selection.anchorNode);
  if (selectedItem?.session.terminal === 'tmux' && $('follow').checked && cursor.visible && !selecting) {
    const top = pre.scrollTop, left = pre.scrollLeft;
    const minY = bounds.top + parseFloat(style.paddingTop), maxY = bounds.bottom - parseFloat(style.paddingBottom) - lineHeight;
    const minX = bounds.left + parseFloat(style.paddingLeft), maxX = bounds.right - parseFloat(style.paddingRight) - cell;
    if (y < minY) pre.scrollTop += y - minY;
    else if (y > maxY) pre.scrollTop += y - maxY;
    if (x < minX) pre.scrollLeft += x - minX;
    else if (x > maxX) pre.scrollLeft += x - maxX;
    x -= pre.scrollLeft - left; y -= pre.scrollTop - top;
    terminalFollowScroll = {key:selectedKey, top:pre.scrollTop, left:pre.scrollLeft,
      width:pre.clientWidth, height:pre.clientHeight, contentWidth:pre.scrollWidth, contentHeight:pre.scrollHeight};
  }
  const inView = x >= bounds.left && x < bounds.right - 1 && y + lineHeight > bounds.top && y < bounds.bottom;
  caret.style.left = `${x - container.left}px`; caret.style.top = `${y - container.top}px`;
  caret.style.width = `${Math.max(2, cell)}px`; caret.style.height = `${lineHeight}px`;
  caret.dataset.style = cursor.style; caret.dataset.blink = String(cursor.blink); caret.dataset.offset = String(cursor.offset);
  show(caret, cursor.visible === true && inView && !composing && !!latestFrame && connected);
  // Native phone IME candidate UI uses this same insertion point.
  if (inView && !composing) {
    $('terminal-keyboard').style.left = `${x - container.left}px`;
    $('terminal-keyboard').style.top = `${y - container.top}px`;
  }
  const composition = $('terminal-composition');
  composition.style.left = `${Math.max(12, Math.min(x - container.left, container.width - 48))}px`;
  composition.style.top = `${Math.max(bounds.top - container.top, Math.min(y - container.top, bounds.bottom - container.top - lineHeight))}px`;
  composition.style.maxWidth = `${Math.max(36, container.width - parseFloat(composition.style.left) - 12)}px`;
}
function keyboardText() {
  const value = $('terminal-keyboard').value;
  return value.startsWith(keyboardMarker) ? value.slice(1) : value;
}
function resetKeyboard() {
  // A character before the caret lets phone keyboards emit Backspace even when no draft is present.
  $('terminal-keyboard').value = keyboardMarker; $('terminal-keyboard').setSelectionRange(1, 1);
  show($('terminal-composition'), false);
}
function restoreDirectDraft(value, key = selectedKey) {
  if (!value || !key) return;
  const draft = value + (key === selectedKey ? $('terminal-input').value : drafts.get(key) || '');
  drafts.set(key, draft);
  if (key === selectedKey) { $('terminal-input').value = draft; composePreferred = true; sizeInput(); }
}
function stopDirect(preserve = true, failedText = '') {
  clearTimeout(directTimer); inputGeneration++;
  if (preserve && selectedKey) {
    const pending = failedText + directQueue.filter(item => item.key === selectedKey && item.kind === 'characters').map(item => item.value).join('') + keyboardText();
    restoreDirectDraft(pending);
    drafts.set(selectedKey, $('terminal-input').value);
  }
  directQueue.length = 0; directMode = false; directStreamID = null; composing = false; resetKeyboard();
  if (document.activeElement === $('terminal-keyboard')) $('terminal-keyboard').blur();
}
function armDirect() {
  if (!directMode) directStreamID = latestFrame?.streamID || null;
  directMode = true;
}
function focusKeyboard() {
  if (composeMode) { if (!$('terminal-input').disabled) $('terminal-input').focus({ preventScroll: true }); return; }
  if ($('terminal-keyboard').disabled) return;
  if (document.activeElement === $('terminal-keyboard')) return;
  armDirect(); inputFailure = ''; captureDirectText();
  if (composePreferred) { updateControls(); return; }
  $('terminal-keyboard').focus({ preventScroll: true }); updateControls();
}

async function api(path, body, signal) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) controller.abort();
  const timeout = setTimeout(() => controller.abort(), 20000);
  try {
    const response = await fetch(path, { method: body ? 'POST' : 'GET', headers: body ? { 'Content-Type': 'application/json' } : {}, body: body ? JSON.stringify(body) : undefined, signal: controller.signal, cache: 'no-store', credentials: 'omit' });
    const result = await response.json();
    if (!response.ok) throw Object.assign(new Error(result.error || '요청을 처리하지 못했습니다. 상태를 새로고침해주세요.'), {status: response.status});
    return result;
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('연결 응답이 늦습니다. 입력을 다시 보내기 전에 터미널 화면을 확인해주세요.');
    if (error instanceof TypeError) throw new Error('Mac과의 연결이 끊겼습니다. 같은 핫스팟과 Mac의 웹 접속 설정을 확인해주세요.');
    throw error;
  } finally { clearTimeout(timeout); signal?.removeEventListener('abort', abort); }
}

function terminalState(state, label) {
  $('terminal-live').dataset.state = state; text($('terminal-live'), label);
}
function terminalPlaceholder(value) {
  terminalValue = null; terminalRows = []; terminalAppearanceKey = null; text($('terminal-screen'), value);
  $('terminal-screen').style.removeProperty('--ansi-fg'); $('terminal-screen').style.removeProperty('--ansi-bg');
  $('terminal-colors').disabled = true; text($('terminal-color-status'), '');
  show($('terminal-cursor'), false);
}
function clearNativeImage() {
  nativeImageValue = null; $('native-image').removeAttribute('src');
  $('native-image-stage').style.removeProperty('width'); $('native-image-stage').style.removeProperty('height');
}
function fitNativeImage() {
  const image = latestFrame?.nativeDisplay?.image, viewport = $('native-screen');
  if (!nativeTerminal() || !image || viewport.hidden || !viewport.clientWidth || !viewport.clientHeight) return;
  const fit = Math.min(1, viewport.clientWidth / image.width, viewport.clientHeight / image.height);
  nativeZoomLimit = Math.max(4, Math.ceil(1 / fit)); nativeZoom = Math.min(nativeZoom, nativeZoomLimit);
  const scale = fit * nativeZoom;
  const width = Math.max(1, Math.round(image.width * scale)), height = Math.max(1, Math.round(image.height * scale));
  $('native-image').style.width = `${width}px`; $('native-image').style.height = `${height}px`;
  $('native-image-stage').style.width = `${width}px`; $('native-image-stage').style.height = `${height}px`;
  text($('native-scale'), `${Math.round(scale * 100)}%`);
  $('native-zoom-out').disabled = nativeZoom <= 1; $('native-zoom-in').disabled = nativeZoom >= nativeZoomLimit;
  if (nativeZoom === 1) { viewport.scrollLeft = 0; viewport.scrollTop = 0; }
  scheduleCursor();
}
function renderNativeDisplay() {
  const native = nativeTerminal(), available = nativeConnection(), display = native ? latestFrame?.nativeDisplay : undefined;
  const image = native && display?.state === 'live' ? display.image : null;
  const host = selectedItem.session.hostName || hosts[selectedItem.session.terminal] || '터미널';
  const online = (connected && currentNode()?.online || originalStreamSelected()) && allSessions.some(item => item.key === selectedKey);
  const states = {live:'Mac 원본 화면',permissionRequired:'Mac 권한 필요',inactive:'원본 탭 연결 필요',unavailable:'원본 화면 연결 불가'};
  const defaults = {live:'같은 원본 탭에 입력합니다.',permissionRequired:'Mac에서 선택한 창 보기의 화면 기록 권한을 확인한 뒤 연결해주세요.',inactive:'원본 터미널 연결을 눌러 같은 탭을 열어주세요.',unavailable:'Mac의 원본 터미널과 권한을 확인해주세요.'};
  show($('native-connection'), available && (native || !!latestFrame?.outputReason || !latestFrame?.keys.includes('characters'))); show($('native-view-label'), available);
  $('native-view').checked = native;
  $('native-view').disabled = !online || nativeConnectingKey === selectedKey || document.hidden;
  show($('native-screen'), native); show($('native-tools'), !!image);
  show($('native-image-stage'), !!image); show($('native-empty'), native && !image);
  $('terminal-screen').classList.toggle('native-accessible', native);
  $('terminal-screen').tabIndex = native ? -1 : 0;
  document.querySelector('.terminal').dataset.display = native ? 'native' : 'text';
  if (!image) clearNativeImage();
  else if (nativeImageValue !== image.data) {
    nativeImageValue = image.data; $('native-image').width = image.width; $('native-image').height = image.height;
    $('native-image').src = 'data:image/jpeg;base64,' + image.data;
  }
  $('native-image').alt = `현재 Mac ${host}의 원본 창 화면`;
  if (available) {
    const waiting = nativeConnectingKey === selectedKey || !latestFrame && terminalStream && terminalStreamFailed !== selectedKey;
    const status = !online ? 'Mac 연결 끊김' : waiting ? native ? 'Mac 창 연결 중' : '터미널 연결 중' : display ? states[display.state] : latestFrame ? `${host} 원본 터미널` : '터미널 연결 끊김';
    const message = !online ? '연결을 확인한 뒤 원본 터미널을 다시 연결해주세요.' : waiting ? '같은 원본 터미널에 연결하고 있습니다.' : display?.message || defaults[display?.state] || latestFrame?.outputReason || latestFrame?.inputReason || '원본 출력과 키 입력을 중계합니다. Mac 창 보기는 화면 설정에서 선택할 수 있습니다.';
    text($('native-status'), `${status} · ${message}`);
    $('native-connection').dataset.state = online ? display?.state || (latestFrame ? 'live' : 'unavailable') : 'unavailable';
    text($('native-empty'), !online ? 'Mac에 다시 연결하면 원본 화면을 볼 수 있습니다.' : '원본 터미널을 연결하면 실제 창 화면이 여기에 표시됩니다.');
    $('native-connect').disabled = !online || mutation || inputInFlight || nativeConnectingKey === selectedKey || document.hidden;
    text($('native-connect'), nativeConnectingKey === selectedKey ? '연결 중…' : native ? 'Mac 창 연결' : '원본 터미널 연결');
  }
  for (const id of ['terminal-wrap','terminal-colors','follow']) $(id).closest('label').hidden = native;
  show($('terminal-font-controls'), !native);
  if (image) { $('terminal-colors').disabled = true; text($('terminal-color-status'), `${host} 실제 창의 원본 색상과 커서`); }
  fitNativeImage();
}
function mergeNativeDisplay(display, previous, compact) {
  if (display === undefined) return undefined;
  if (!display || !['live','permissionRequired','inactive','unavailable'].includes(display.state) || display.message != null && (typeof display.message !== 'string' || display.message.length > 4096)) throw new Error('원본 터미널 화면 상태를 확인하지 못했습니다. 화면을 다시 연결해주세요.');
  const result = {state:display.state, message:display.message};
  if (display.state !== 'live') return result;
  let image = display.image;
  if (image === undefined && compact && previous?.state === 'live') image = previous.image;
  if (!image) return {state:'unavailable', message:'Mac 창 이미지를 받지 못했습니다. Mac 창 보기를 다시 켜주세요. 원본 입력은 유지됩니다.'};
  if (image !== previous?.image) {
    try { validateNativeImage(image); }
    catch (_) { return {state:'unavailable', message:'Mac 창 이미지 정보를 확인하지 못했습니다. Mac 창 보기를 다시 켜주세요. 원본 입력은 유지됩니다.'}; }
  }
  return {...result, image};
}
function validateNativeImage(image) {
  const invalid = () => { throw new Error('원본 화면 이미지 정보를 확인하지 못했습니다. 화면을 다시 연결해주세요.'); };
  if (!Number.isInteger(image.width) || image.width < 1 || image.width > 2048 || !Number.isInteger(image.height) || image.height < 1 || image.height > 2048 || image.width * image.height > 4194304 || typeof image.data !== 'string' || !image.data || image.data.length > 1000000 || image.data.length % 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(image.data)) invalid();
  let bytes; try { bytes = atob(image.data); } catch (_) { invalid(); }
  if (bytes.length > 750000 || btoa(bytes) !== image.data || bytes.charCodeAt(0) !== 0xff || bytes.charCodeAt(1) !== 0xd8 || bytes.charCodeAt(bytes.length - 2) !== 0xff || bytes.charCodeAt(bytes.length - 1) !== 0xd9) invalid();
  let offset = 2;
  while (offset + 3 < bytes.length) {
    if (bytes.charCodeAt(offset++) !== 0xff) invalid();
    while (bytes.charCodeAt(offset) === 0xff) offset++;
    const marker = bytes.charCodeAt(offset++);
    if (marker === 0xda || marker === 0xd9) break;
    if (marker === 0x01 || marker >= 0xd0 && marker <= 0xd7) continue;
    const length = bytes.charCodeAt(offset) * 256 + bytes.charCodeAt(offset + 1);
    if (length < 2 || offset + length > bytes.length) invalid();
    if ([0xc0,0xc1,0xc2,0xc3,0xc5,0xc6,0xc7,0xc9,0xca,0xcb,0xcd,0xce,0xcf].includes(marker)) {
      if (length < 8 || bytes.charCodeAt(offset + 3) * 256 + bytes.charCodeAt(offset + 4) !== image.height || bytes.charCodeAt(offset + 5) * 256 + bytes.charCodeAt(offset + 6) !== image.width) invalid();
      return;
    }
    offset += length;
  }
  invalid();
}
function terminalAppearance(value, appearance) {
  const color = value => value === undefined || /^#[\da-f]{6}$/i.test(value);
  if (!appearance || !Array.isArray(appearance.runs) || appearance.runs.length > 8000 || !color(appearance.foreground) || !color(appearance.background)) return null;
  let end = 0;
  for (const run of appearance.runs) {
    if (!Number.isInteger(run.offset) || !Number.isInteger(run.length) || run.offset < end || run.length < 1 || run.offset + run.length > value.length || !color(run.fg) || !color(run.bg)) return null;
    end = run.offset + run.length;
  }
  return appearance;
}
function colorStatus(appearance) {
  $('terminal-colors').disabled = !appearance;
  text($('terminal-color-status'), appearance ? '터미널이 보낸 원본 색상과 서식' : selectedItem?.session.terminal === 'vscode'
    ? '색상 정보를 받지 못했습니다. Mac에서 VS Code 확장을 업데이트한 뒤 새로 실행한 CLI부터 원본 색상을 볼 수 있습니다.'
    : '이 연결은 텍스트만 제공합니다. 원본 색상은 VS Code 확장 연결에서 볼 수 있습니다.');
}
function terminalRun(value, run) {
  const element = make('span', 'terminal-run', value);
  if (run.fg) element.style.setProperty('--run-fg', run.fg);
  if (run.bg) element.style.setProperty('--run-bg', run.bg);
  for (const flag of ['bold', 'dim', 'italic', 'underline', 'strike', 'inverse', 'hidden']) if (run[flag] === true) element.classList.add('ansi-' + flag);
  return element;
}
function renderTerminal(value, inputAppearance) {
  const appearance = terminalAppearance(value, inputAppearance), appearanceKey = JSON.stringify(appearance);
  colorStatus(appearance);
  if (value === terminalValue && appearanceKey === terminalAppearanceKey) return false;
  const pre = $('terminal-screen'), scrollTop = pre.scrollTop, scrollLeft = pre.scrollLeft;
  for (const [name, color] of [['--ansi-fg', appearance?.foreground], ['--ansi-bg', appearance?.background]]) {
    if (color) pre.style.setProperty(name, color); else pre.style.removeProperty(name);
  }
  const lines = value.match(/[^\n]*\n|[^\n]+$/g) || [];
  // Bound the row count without dropping text; original attributes remain separately bounded.
  if (lines.length > 2000) lines.splice(0, lines.length - 1999, lines.slice(0, lines.length - 1999).join(''));
  const runs = appearance?.runs || [];
  let offset = 0, runIndex = 0;
  const next = lines.map(value => {
    const parts = [], end = offset + value.length;
    while (runIndex < runs.length && runs[runIndex].offset + runs[runIndex].length <= offset) runIndex++;
    for (let i = runIndex; i < runs.length && runs[i].offset < end; i++) {
      const run = runs[i], start = Math.max(offset, run.offset), stop = Math.min(end, run.offset + run.length);
      if (stop > start) parts.push({ ...run, offset: start - offset, length: stop - start });
    }
    offset = end;
    return { value, parts, signature: value + '\u0000' + JSON.stringify(parts) };
  });
  let start = 0, oldEnd = terminalRows.length, newEnd = next.length;
  while (start < oldEnd && start < newEnd && terminalRows[start].signature === next[start].signature) start++;
  while (oldEnd > start && newEnd > start && terminalRows[oldEnd - 1].signature === next[newEnd - 1].signature) { oldEnd--; newEnd--; }
  if (terminalValue === null) pre.replaceChildren();
  const anchor = terminalRows[oldEnd]?.element || null;
  for (let i = start; i < oldEnd; i++) terminalRows[i].element.remove();
  const fragment = document.createDocumentFragment(), added = [];
  for (let i = start; i < newEnd; i++) {
    const row = next[i], element = make('span', 'terminal-line');
    let position = 0;
    for (const run of row.parts) {
      if (run.offset > position) element.append(document.createTextNode(row.value.slice(position, run.offset)));
      element.append(terminalRun(row.value.slice(run.offset, run.offset + run.length), run)); position = run.offset + run.length;
    }
    if (position < row.value.length) element.append(document.createTextNode(row.value.slice(position)));
    fragment.append(element); added.push({ signature: row.signature, element });
  }
  pre.insertBefore(fragment, anchor);
  terminalRows.splice(start, oldEnd - start, ...added); terminalValue = value; terminalAppearanceKey = appearanceKey;
  const selection = window.getSelection();
  const selecting = selection && !selection.isCollapsed && pre.contains(selection.anchorNode);
  pre.scrollTop = $('follow').checked && !selecting && selectedItem?.session.terminal !== 'tmux' ? pre.scrollHeight : scrollTop; pre.scrollLeft = scrollLeft;
  return true;
}
function feedback(message, error = false) {
  clearTimeout(feedbackTimer); text($('feedback'), message); $('feedback').dataset.error = String(error); show($('feedback'), true);
  feedbackTimer = setTimeout(() => show($('feedback'), false), error ? 14000 : 5500);
}
function endpoint(path, nodeID, sessionID) {
  const query = new URLSearchParams({ node: nodeID });
  if (sessionID) query.set('session', sessionID);
  return `${path}?${query}`;
}
async function action(nodeID, payload, message) {
  if (mutation) return;
  mutation = true; updateControls(); renderMachines();
  try {
    await api(endpoint('/api/action', nodeID), { ...payload, requestID: uuid() });
    if (message) feedback(message);
    await refreshNetwork(); return true;
  } catch (error) { feedback(error.message, true); }
  finally { mutation = false; if (selectedItem) $('automatic').checked = selectedItem.session.automatic; updateControls(); renderMachines(); }
}
function beginQuestionEditing(key, nodeID, payload) {
  if (questionEditing.has(key)) return;
  // Holding an automatic reply is not a form submission. Do not disable every
  // Send button or swallow a tap while this independently acknowledged POST runs.
  const pending = api(endpoint('/api/action', nodeID), {...payload, requestID:uuid()}).catch(error => {
    const state = questionDeliveries.get(key) || {};
    if (!state.busy) { state.error = error.message; questionDeliveries.set(key, state); updateInteractionControls(); }
  });
  questionEditing.set(key, pending);
}
async function sendQuestionAnswer(key, nodeID, payload, message) {
  const previous = questionDeliveries.get(key);
  if (previous?.busy || previous?.sent || previous?.uncertain) return false;
  const state = {busy:true, error:'', uncertain:false}; questionDeliveries.set(key, state); updateInteractionControls();
  try {
    await questionEditing.get(key);
    await api(endpoint('/api/action', nodeID), {...payload, requestID:uuid()});
    state.sent = true; state.finishedAt = performance.now(); state.message = message; state.error = ''; void refreshNetwork();
    if (selectedItem?.session.agent === 'codex' && $('interaction-dialog').open) void refreshCodexQueue();
    return true;
  } catch (error) {
    state.error = error.message; state.uncertain = !error.status || error.status >= 500; state.failedAt = performance.now();
    if (state.uncertain) state.error += ' 전달 여부를 확인한 뒤 진행해주세요. 작성한 답변은 보관합니다.';
    void refreshNetwork(); return false;
  } finally { state.busy = false; updateInteractionControls(); }
}

async function refreshNetwork() {
  clearTimeout(networkTimer);
  if (loadingNetwork) return;
  loadingNetwork = true; $('refresh').disabled = true; $('refresh').setAttribute('aria-busy', 'true');
  const startedAt = performance.now();
  try {
    const result = await api('/api/network');
    connected = true; nodes = result.nodes; lastNetworkStartedAt = startedAt;
    allSessions = reconcilePTYInventory(nodes.flatMap(node => node.online ? (node.state?.sessions || []).map(view => ({ node, view, session: view.session, key: keyFor(node, view.session, view) })) : []));
    const unavailable = nodes.find(node => node.id === selectedItem?.node.id && !node.online);
    // A peer's inventory can time out while its independently verified SSE
    // remains live. Retain only that selection; online session removal is final.
    if (unavailable && originalStreamSelected() && !allSessions.some(item => item.key === selectedKey)) {
      allSessions.push({...selectedItem, node:{...selectedItem.node, ...unavailable, state:selectedItem.node.state}});
    }
    lastNetworkUpdate = result.updatedAt;
    text($('connection'), `${nodes.filter(node => node.online).length}대 연결 · ${nowLabel(lastNetworkUpdate)} 갱신`);
    show($('network-error'), false);
    text($('discovery'), result.discovery || ''); show($('discovery'), !!result.discovery);
    updateWebVersion(result);
    renderMachines(); renderNodeFilter(); renderList();
    if (selectedKey) {
      const current = allSessions.find(item => item.key === selectedKey);
      if (current) { selectedItem = current; renderDetail(); if (!current.view.pty && (terminalStream || supportsTerminalStream(current.node))) void refreshFrame(); }
      else if (selectedItem?.view.pty) {
        // The active inventory drops closed processes before their final stream
        // bytes necessarily arrive. Keep this xterm and its retained last screen.
        const node = nodes.find(node => node.id === selectedItem.node.id);
        if (node) selectedItem.node = node;
        ptyRetained.set(selectedKey, selectedItem); renderDetail();
      }
      else if (selectedItem) { show($('session-ended'), true); latestFrame = null; frameController?.abort(); stopTerminalStream(); stopDirect(); stopPTY(); terminalState('error', currentNode()?.online ? '세션 종료' : '연결 끊김'); updateControls(); }
      else restoreSelection();
    } else restoreSelection();
    renderInteractions();
  } catch (error) {
    connected = false; text($('connection'), lastNetworkUpdate ? `연결 끊김 · 마지막 갱신 ${nowLabel(lastNetworkUpdate)}` : '연결 끊김 · 다시 연결 중');
    show($('web-update'), false);
    text($('network-error'), error.message); show($('network-error'), true);
    if (!nodes.length) text($('list-empty'), 'Mac에 연결하면 감지된 세션이 여기에 표시됩니다.');
    // Inventory and terminal connections are independent. A failed list request
    // cannot invalidate a verified original stream or close its mobile keyboard.
    if (!selectedItem?.view.pty && !terminalStream && !latestFrame) terminalState('pending', '다시 연결 중…');
    updateControls(); renderMachines();
  } finally {
    loadingNetwork = false; $('refresh').disabled = false; $('refresh').removeAttribute('aria-busy');
    if (!document.hidden) networkTimer = setTimeout(refreshNetwork, connected ? 2500 : 5000);
  }
}
function renderMachines() {
  if (nodes.length && $('machines').querySelector('.empty-inline')) $('machines').replaceChildren();
  text($('mac-count'), `${connected ? nodes.filter(node => node.online).length : 0}대`);
  for (const node of nodes) {
    let row = machineRows.get(node.id);
    if (!row) {
      row = make('article', 'machine'); const info = make('div', 'machine-info');
      info.append(make('p', 'machine-name'), make('p', 'machine-status')); row.append(info, make('button', 'secondary'));
      row.lastChild.addEventListener('click', () => {
        const current = nodes.find(item => item.id === node.id);
        if (current?.online) void action(node.id, { action: 'pause', paused: !current.state.snapshot.paused }, current.state.snapshot.paused ? '이 Mac의 자동 승인을 재개했습니다.' : '이 Mac의 자동 승인을 일시정지했습니다.');
      });
      machineRows.set(node.id, row); $('machines').append(row);
    }
    text(row.querySelector('.machine-name'), node.name + (node.local ? ' · 접속한 Mac' : ''));
    const status = row.querySelector('.machine-status');
    status.className = 'machine-status ' + (!node.online || !connected ? '' : node.state.snapshot.paused ? 'paused' : 'online');
    const activeCount = node.state?.sessions?.filter(view => !sessionEnded({session:view.session, view}) && !sessionEnded(ptyRetained.get(keyFor(node, view.session, view)))).length || 0;
    text(status, !connected ? '연결 확인 필요' : !node.online ? '연결 끊김 · 웹 접속과 네트워크 확인' : `${activeCount}개 세션 · ${node.state.snapshot.paused ? '자동 승인 일시정지' : '연결됨'}`);
    status.title = node.error || '';
    const button = row.lastChild; text(button, node.online && node.state.snapshot.paused ? '재개' : '일시정지');
    button.disabled = mutation || !connected || !node.online;
    button.setAttribute('aria-label', `${node.name} 자동 승인 ${node.online && node.state.snapshot.paused ? '재개' : '일시정지'}`);
    button.title = !node.online ? 'Mac의 웹 접속이 다시 연결되면 사용할 수 있습니다.' : '이 Mac의 자동 승인만 변경합니다. 터미널 작업은 계속됩니다.';
  }
}
function renderNodeFilter() {
  const select = $('node-filter'), value = select.value;
  for (const node of nodes) {
    let option = Array.from(select.options).find(item => item.value === node.id);
    if (!option) { option = make('option'); option.value = node.id; select.append(option); }
    text(option, node.name + (node.online ? '' : ' · 끊김'));
  }
  select.value = value;
}
function renderList() {
  const query = $('search').value.trim().toLocaleLowerCase();
  const visible = allSessions.filter(({ node, view, session }) => ($('node-filter').value === 'all' || node.id === $('node-filter').value)
    && (filter !== 'review' || needsReview(session)) && (filter !== 'automatic' || session.automatic)
    && [view.title, session.cwd, session.terminalTitle, session.customization?.note, session.gitBranch?.name, node.name, agents[session.agent]].filter(Boolean).join(' ').toLocaleLowerCase().includes(query));
  const visibleKeys = new Set(visible.map(item => item.key));
  for (const [key, row] of rows) if (!visibleKeys.has(key)) { row.remove(); rows.delete(key); }
  for (const [index, item] of visible.entries()) {
    let row = rows.get(item.key);
    if (!row) {
      row = make('li'); const button = make('button', 'session-row');
      button.append(make('span', 'row-project'), make('span', 'row-title'), make('span', 'row-meta'));
      const state = make('span', 'row-state'); state.append(make('span', 'phase'), make('span', 'row-auto')); button.append(state); row.append(button);
      button.addEventListener('click', () => selectSession(item.key, true)); rows.set(item.key, row);
    }
    const button = row.firstChild; button.setAttribute('aria-pressed', String(item.key === selectedKey));
    const project = item.session.cwd ? item.session.cwd.split('/').filter(Boolean).pop() : '프로젝트 확인 중';
    text(row.querySelector('.row-project'), project); text(row.querySelector('.row-title'), item.view.title);
    text(row.querySelector('.row-meta'), `${item.node.name} · ${agents[item.session.agent]} · ${item.session.hostName || hosts[item.session.terminal]}`);
    const phase = row.querySelector('.phase'); text(phase, item.view.phaseTitle); phase.dataset.phase = item.session.phase;
    text(row.querySelector('.row-auto'), item.session.automatic ? item.node.state.snapshot.paused ? '자동 승인 · 정지' : '자동 승인 켜짐' : '자동 승인 꺼짐');
    const atPosition = $('session-list').children[index];
    if (atPosition !== row) $('session-list').insertBefore(row, atPosition || null);
  }
  text($('session-count'), `${visible.length}개`);
  show($('list-empty'), !visible.length);
  text($('list-empty'), allSessions.length ? '검색이나 필터에 맞는 세션이 없습니다.' : nodes.some(node => node.online) ? '감지된 세션이 없습니다. Mac에서 Claude Code 또는 Codex를 실행하세요.' : '연결된 Mac이 없습니다. 네트워크와 웹 접속 설정을 확인해주세요.');
}
function selectSession(key, focus = false) {
  const item = allSessions.find(item => item.key === key) || ptyRetained.get(key); if (!item) return;
  if (selectedKey !== item.key) {
    stopPTY(); stopTerminalStream(true);
    nativeSessionKey = ''; nativeZoom = 1; clearNativeImage();
    stopDirect(); inputFailure = ''; composing = false;
    terminalFollowScroll = null;
    if (selectedKey) drafts.set(selectedKey, $('terminal-input').value);
    selectedKey = item.key; selectedItem = item; latestFrame = null; detailGeneration++;
    frameController?.abort(); quietFrames = 0; fastFrameUntil = Date.now() + 5000;
    $('detail').scrollTop = 0;
    $('terminal-input').value = drafts.get(item.key) || ''; composePreferred = !!$('terminal-input').value; sizeInput(); $('follow').checked = true; show($('jump-latest'), false); questionSignature = ''; historySignature = '';
    $('questions').replaceChildren(); $('history').replaceChildren();
    terminalPlaceholder('화면을 불러오는 중…'); terminalState('pending', '연결 중…'); text($('terminal-time'), '—'); show($('terminal-error'), false); show($('terminal-retry'), false);
  } else if (terminalStreamFailed === item.key) stopTerminalStream(true);
  selectedItem = item;
  document.body.classList.add('detail-open');
  if (window.innerWidth < 760) terminalFocus(true);
  const hash = new URLSearchParams({ node: item.node.id, session: item.session.id, ...(item.view.ptyID ? {pty: item.view.ptyID} : {}) });
  history.replaceState(null, '', `#${hash}`);
  renderList(); renderDetail();
  void refreshFrame();
  if (focus) { $(document.body.classList.contains('terminal-focus') ? 'terminal-heading' : 'session-title').focus({ preventScroll: true }); if (window.innerWidth < 760) window.scrollTo(0, 0); }
}
function restoreSelection() {
  const hash = new URLSearchParams(location.hash.slice(1));
  const nodeID = hash.get('node'), sessionID = hash.get('session'), ptyID = hash.get('pty');
  let item = allSessions.find(item => item.node.id === nodeID && item.session.id === sessionID);
  // Old continuation bookmarks include an original session plus a PTY alias.
  // Prefer that original; never silently substitute its separate copied CLI.
  if (!item && ptyID && sessionID === 'pty:' + ptyID) item = allSessions.find(item => item.node.id === nodeID && item.view.ptyID === ptyID) || ptyRetained.get(nodeID + '/pty:' + ptyID);
  if (!item && ptyID) {
    try {
      const stored = sessionStorage.getItem(retainedPTYStorage) || '[]';
      if (stored.length > 128000) throw new Error('invalid cache');
      const entry = JSON.parse(stored).slice(-24).find(entry => entry.nodeID === nodeID && entry.descriptor?.ptyID === ptyID && entry.descriptor.closed === true && (sessionID === 'pty:' + ptyID || sessionID === entry.sessionID));
      if (entry) { item = descriptorItem(nodeID, entry.descriptor); if (typeof entry.title === 'string' && entry.title.length <= 1024) item.view.title = entry.title; }
    } catch (_) {}
  }
  if (item) selectSession(item.key);
}
function renderDetail() {
  if (!selectedItem) return;
  const { node, session, view } = selectedItem;
  const isPTY = !!view.pty;
  show($('terminal-screen'), !isPTY); show($('pty-screen'), isPTY);
  show($('close-pty'), isPTY);
  show($('pty-unsent'), isPTY && !!((ptyDrafts.get(selectedKey) || '') + (ptyClient?.unsent || '')));
  document.querySelector('.terminal').dataset.mode = isPTY ? 'pty' : 'mirror';
  show($('detail-empty'), false); show($('detail-content'), true); show($('session-ended'), false);
  text($('session-meta'), `${node.name} · ${agents[session.agent]} · ${session.tty || 'TTY 없음'}`);
  text($('session-title'), view.title); text($('session-path'), session.cwd || '폴더 확인 중');
  text($('session-branch'), session.gitBranch?.name ? `브랜치 · ${session.gitBranch.name}` : session.customization?.note || '');
  const phase = $('session-phase'); text(phase, view.phaseTitle); phase.dataset.phase = session.phase;
  $('automatic').checked = session.automatic; text($('session-status'), node.state.snapshot.paused ? '이 Mac의 자동 승인이 일시정지되어 있습니다.' : session.activityDetail || session.detail);
  const terminalHost = `${node.name} · ${session.hostName || hosts[session.terminal]}`;
  text($('terminal-host'), terminalHost); $('terminal-host').title = terminalHost;
  if (document.body.classList.contains('terminal-focus')) text($('terminal-heading'), view.title);
  text($('input-help'), 'Enter로 전송하고 Shift Enter로 줄을 바꿉니다. 한글 조합을 끝낸 뒤 전송하세요.');
  if (isPTY) { ensurePTY(); } else if (!view.canRead) {
    latestFrame = null; stopTerminalStream(); stopDirect(); frameController?.abort(); terminalPlaceholder(view.inputReason || '화면 연결이 없습니다.'); terminalState('error', '화면 연결 필요'); text($('terminal-time'), '—');
  }
  renderQuestions(); renderHistory(); updateControls();
}
function updateControls() {
  updateInteractionControls();
  if (!selectedItem) return;
  renderNativeDisplay();
  const current = currentNode(), sessionPresent = allSessions.some(item => item.key === selectedKey);
  const streamLive = !!selectedItem.view.pty && !!ptyClient?.ready;
  const enabled = (connected && current?.online || streamLive) && sessionPresent && !mutation;
  const temporaryPTY = ptyTemporary.has(selectedKey);
  $('automatic').disabled = !enabled || temporaryPTY || (!selectedItem.view.canApprove && !selectedItem.session.automatic);
  $('automatic').title = temporaryPTY ? 'PTY에서 실행 중인 CLI를 확인하는 중입니다.' : !selectedItem.view.canApprove ? 'Mac에서 이 세션의 승인 연결을 먼저 설정해주세요.' : '이 세션의 다음 지원 요청부터 적용합니다.';
  $('reveal').disabled = !enabled || !selectedItem.view.canReveal;
  $('new-pty').disabled = !connected || !nodes.some(node => node.online);
  if (selectedItem.view.pty) {
    const ready = enabled && ptyClient?.ready;
    $('terminal-keyboard').disabled = true; show($('input-editor'), false); show($('compose-input-label'), false);
    $('compose-input').disabled = true; $('compose-input').checked = false;
    $('terminal-wrap').disabled = true;
    $('terminal-colors').disabled = true; $('terminal-colors').checked = true;
    text($('terminal-color-status'), 'PTY가 보낸 원본 ANSI 색상과 커서');
    $('terminal-keyboard-toggle').disabled = !ready; $('terminal-keyboard-toggle').setAttribute('aria-pressed', String(ready && document.activeElement === ptyClient?.term.textarea));
    $('terminal-keyboard-toggle').setAttribute('aria-label', 'PTY 터미널 키보드 열기');
    $('send-input').disabled = !ready; text($('send-input'), 'Enter');
    for (const button of $('input-form').querySelectorAll('button[data-key]')) { button.disabled = !ready; show(button, true); }
    $('close-pty').disabled = !enabled || !!ptyClient?.ending || sessionEnded(selectedItem);
    text($('direct-input-help'), '화면을 눌러 직접 입력합니다. Shift Tab으로 키보드 포커스를 나갑니다.');
    $('direct-input-help').dataset.required = 'false'; text($('input-reason'), ''); $('input-reason').dataset.blocked = 'false'; text($('input-help'), '');
    return;
  }
  $('terminal-wrap').disabled = false; show($('input-form').querySelector('[data-key="eof"]'), false);
  const reason = !originalTerminalConnected() || !sessionPresent ? 'Mac과 세션의 연결을 확인해주세요.' : document.hidden || terminalStreamFailed === selectedKey ? '화면을 다시 연결한 뒤 입력할 수 있습니다.' : latestFrame?.inputReason || selectedItem.view.inputReason;
  const fresh = terminalFrameFresh();
  const base = originalTerminalConnected() && sessionPresent && selectedItem.view.canRead && !reason;
  const inputEnabled = base && fresh && !mutation;
  const recovering = !!terminalStream?.reconnecting;
  const retainKeyboard = !!latestFrame && !!terminalStream && terminalStream.key === selectedKey;
  // Keep the active editor alive while its own request/refresh runs: disabling it closes mobile keyboards.
  $('terminal-input').disabled = !(base && (fresh || retainKeyboard || inputInFlight || directSending));
  const supported = inputKeys(), native = nativeTerminal();
  const composedSupported = supported.includes('text') || supported.includes('submit');
  const canDirect = supported.includes('characters') && supported.includes('backspace');
  if ((!base || !canDirect) && directMode) stopDirect();
  const wasCompose = composeMode;
  composeMode = composePreferred || !nativeConnection() && !canDirect || !!$('terminal-input').value;
  const originalDraftOnly = composeMode && !composedSupported;
  if ((native || originalDraftOnly) && composeMode) $('terminal-input').disabled = false;
  $('terminal-keyboard').disabled = !(base && canDirect && !composeMode && (fresh || retainKeyboard || inputInFlight || directSending));
  document.querySelector('.terminal').dataset.input = composeMode ? 'compose' : 'direct';
  show($('input-editor'), composeMode); show($('compose-input-label'), composeMode);
  if (composeMode && !wasCompose) sizeInput();
  $('compose-input').checked = composeMode; $('compose-input').disabled = !nativeConnection() && !canDirect || composing;
  const keyboardActive = document.activeElement === $('terminal-keyboard') && !$('terminal-keyboard').disabled;
  $('terminal-keyboard-toggle').disabled = $('terminal-keyboard').disabled;
  $('terminal-keyboard-toggle').setAttribute('aria-pressed', String(keyboardActive));
  $('terminal-keyboard-toggle').setAttribute('aria-label', keyboardActive ? '터미널 키보드 닫기' : '터미널 키보드 열기');
  const terminalSetupHelp = selectedItem.session.terminal === 'terminal' && !canDirect
    ? 'Mac의 연결 설정 → 원본 터미널 화면·입력에서 ‘직접 입력 연결’을 설정해주세요. 처음에 Mac 관리자 승인을 받습니다. 작성 후 Enter 전송은 사용할 수 있습니다.' : '';
  const draftReason = canDirect ? '이 원본 연결은 직접 키 입력만 지원합니다. 초안을 복사한 뒤 지우고 화면 설정에서 직접 입력으로 돌아가세요.' : latestFrame?.nativeDisplay?.message || reason || '원본 터미널 연결을 눌러 입력 권한을 확인해주세요. 작성 내용은 초안으로 보관합니다.';
  text($('direct-input-help'), originalDraftOnly ? draftReason : terminalSetupHelp ? reason || terminalSetupHelp
    : nativeConnection() && !canDirect ? reason || '원본 터미널 연결을 눌러 입력 권한을 확인해주세요. 작성 입력은 화면 설정에서 선택할 수 있습니다.'
    : !canDirect ? '화면 직접 입력은 Mac의 VS Code 확장을 업데이트하면 사용할 수 있습니다. 지금은 작성 후 Enter로 전송하세요.'
    : composeMode ? '작성 후 Enter로 전송합니다. 화면 설정에서 직접 입력으로 돌아갈 수 있습니다.'
    : keyboardActive ? '직접 입력 중 · 키와 완성된 한글을 기존 터미널로 전달합니다.' : '화면을 누르거나 키보드 버튼을 눌러 직접 입력하세요.');
  $('direct-input-help').dataset.required = String(!canDirect || originalDraftOnly);
  $('terminal-keyboard-toggle').title = $('direct-input-help').textContent;
  text($('input-help'), originalDraftOnly ? '이 연결은 작성 전송을 지원하지 않습니다. 작성 내용은 초안으로 보관합니다.' : composeMode ? 'Enter로 전송하고 Shift Enter로 줄을 바꿉니다. 한글 조합을 끝낸 뒤 전송하세요.' : !canDirect ? 'Mac의 원본 입력 권한을 연결한 뒤 직접 입력할 수 있습니다.' : '키보드의 문자·Enter·방향키를 직접 보냅니다. Shift Tab으로 포커스를 빠져나갑니다.');
  const nativeInput = !native || (composeMode ? composedSupported && (!!$('terminal-input').value || supported.includes('enter')) : canDirect);
  const queueEnabled = directMode && base && canDirect && !composeMode && (retainKeyboard || directSending);
  $('send-input').disabled = originalDraftOnly || !nativeInput || !(inputEnabled || queueEnabled) || composing || inputInFlight && !directMode || byteLength($('terminal-input').value) > 8000;
  text($('send-input'), inputInFlight && !directMode ? '전달 중' : 'Enter');
  const recoveryHelp = composeMode ? '원래 터미널에 재연결 중입니다. 작성 내용은 유지됩니다. 연결 확인 후 전송하세요.' : '원래 터미널에 재연결 중입니다. 작성한 입력은 보관하고 연결 확인 후 순서대로 전달합니다.';
  text($('input-reason'), inputFailure || reason || (recovering ? recoveryHelp : fresh ? '현재 화면과 대상 CLI를 확인한 뒤 입력합니다.' : '최신 화면을 연결하면 입력할 수 있습니다.'));
  $('input-reason').dataset.blocked = String(!!inputFailure || !!reason || !fresh);
  for (const button of $('input-form').querySelectorAll('button[data-key]')) {
    const available = supported.includes(button.dataset.key);
    show(button, available || native && button.dataset.key !== 'eof'); button.disabled = !available || originalDraftOnly || native && !composeMode && !canDirect || composing || !(inputEnabled || queueEnabled); button.title = reason || `현재 터미널에 ${button.textContent} 키 입력`;
  }
  scheduleCursor();
}
function mergeTerminalUpdate(update, previous, sessionID) {
  if (!update || update.sessionID !== sessionID || typeof update.revision !== 'string' || update.revision.length > 512 || typeof update.observedAt !== 'string' || !Number.isFinite(Date.parse(update.observedAt)) || !Array.isArray(update.keys) || update.keys.length > 64 || update.keys.some(key => typeof key !== 'string' || key.length > 64) || update.inputReason != null && typeof update.inputReason !== 'string' || update.streamID != null && typeof update.streamID !== 'string') throw new Error('터미널 화면 정보를 확인하지 못했습니다. 화면을 다시 연결해주세요.');
  if (update.outputReason != null && (typeof update.outputReason !== 'string' || update.outputReason.length > 4096)) throw new Error('원본 출력 상태를 확인하지 못했습니다.');
  const nativeDisplay = nativeTerminal() ? mergeNativeDisplay(update.nativeDisplay, previous?.nativeDisplay, typeof update.screen !== 'string') : undefined;
  if (typeof update.screen === 'string') return {...update, nativeDisplay};
  if (!previous || update.revision !== previous.revision || update.sessionID !== previous.sessionID) throw new Error('최신 화면을 다시 연결해주세요.');
  // A compact update carries current controls. Missing optional input fields
  // clear old locks/cursors/tokens while the unchanged screen and colors remain.
  return {...previous, ...update, screen:previous.screen, appearance:update.appearance ?? previous.appearance, inputReason:update.inputReason, outputReason:update.outputReason, cursor:update.cursor, streamID:update.streamID, nativeDisplay};
}
function applyTerminalFrame(frame, receivedAt = performance.now()) {
  const previous = latestFrame;
  if (directMode && (frame.streamID || null) !== directStreamID) {
    stopDirect(); inputFailure = '터미널 연결이 바뀌어 직접 입력을 멈췄습니다. 보존한 입력과 새 화면을 확인해주세요.';
  }
  latestFrame = frame;
  terminalFrameReceivedAt = receivedAt;
  const changed = renderTerminal(frame.screen, frame.appearance);
  quietFrames = changed ? 0 : quietFrames + 1;
  terminalState(changed && previous ? 'changed' : 'live', !frame.screen.trim() ? '연결됨 · 빈 화면' : changed && previous ? '새 출력' : '연결됨');
  if (nativeTerminal()) terminalState(frame.nativeDisplay?.state === 'live' ? 'live' : 'pending', frame.nativeDisplay?.state === 'live' ? '원본 창 화면' : '원본 연결 필요');
  text($('terminal-time'), nowLabel(frame.observedAt)); show($('terminal-error'), false); show($('terminal-retry'), false);
  updateControls();
  if (directMode && directQueue.length && !directSending) void pumpDirect();
}
function stopTerminalStream(resetFailure = false) {
  if (terminalStream) {
    terminalStream.source?.close(); clearTimeout(terminalStream.retryTimer); clearTimeout(terminalStream.watchdog);
  }
  terminalStream = null;
  if (terminalPaint) cancelAnimationFrame(terminalPaint);
  terminalPaint = 0; terminalPending = null; terminalPendingAt = -Infinity;
  if (resetFailure) terminalStreamFailed = '';
}
function failTerminalStream(stream, message) {
  if (terminalStream !== stream) return;
  stopTerminalStream(); terminalStreamFailed = stream.key; latestFrame = null; stopDirect();
  text($('terminal-error'), message); show($('terminal-error'), true); text($('terminal-retry'), '화면 다시 연결'); show($('terminal-retry'), true);
  terminalState('error', '연결 끊김'); updateControls();
}
function reconnectTerminalStream(stream) {
  if (terminalStream !== stream || document.hidden || stream.retryTimer) return;
  stream.source?.close(); clearTimeout(stream.watchdog);
  if (terminalPaint) cancelAnimationFrame(terminalPaint);
  terminalPaint = 0; terminalPending = null;
  stream.reconnecting = true;
  terminalState('pending', '재연결 중…');
  text($('terminal-error'), '네트워크 연결이 끊겨 원래 터미널에 다시 연결하고 있습니다.');
  show($('terminal-error'), false); text($('terminal-retry'), '지금 다시 연결'); show($('terminal-retry'), true);
  updateControls();
  // Retry only the read subscription. Input POSTs are never replayed here.
  const delay = Math.min(5000, 500 * 2 ** Math.min(stream.retries++, 4));
  stream.retryTimer = setTimeout(() => {
    stream.retryTimer = null;
    if (terminalStream === stream && !document.hidden) openTerminalStream(stream);
  }, delay);
}
function watchTerminalStream(stream) {
  clearTimeout(stream.watchdog);
  // The server emits current controls at least every two seconds. Recover a
  // half-open Wi-Fi/VPN connection even when EventSource emits no error.
  stream.watchdog = setTimeout(() => reconnectTerminalStream(stream), 8000);
}
function ensureTerminalStream() {
  const renderWindow = nativeTerminal();
  if (terminalStreamFailed === selectedKey || terminalStream?.key === selectedKey && terminalStream.generation === detailGeneration && terminalStream.renderWindow === renderWindow) return;
  stopTerminalStream();
  const item = selectedItem, streamURL = endpoint('/api/terminal/stream', item.node.id, item.session.id) + (renderWindow ? '&view=screen' : '');
  const stream = {key:selectedKey, generation:detailGeneration, renderWindow, url:streamURL, sessionID:item.session.id, source:null, retries:0, reconnecting:false, retryTimer:null, watchdog:null};
  terminalStream = stream;
  if (!latestFrame) { terminalState('pending', '연결 중…'); updateControls(); }
  openTerminalStream(stream);
}
function openTerminalStream(stream) {
  const source = new EventSource(stream.url); stream.source = source;
  const current = () => terminalStream === stream && stream.source === source && selectedKey === stream.key && detailGeneration === stream.generation && !document.hidden;
  watchTerminalStream(stream);
  source.addEventListener('screen', event => {
    if (!current()) return;
    try {
      if (event.data.length > 2000000 || byteLength(event.data) > 2000000) throw new Error('터미널 화면이 너무 큽니다. 화면을 다시 연결해주세요.');
      const frame = mergeTerminalUpdate(JSON.parse(event.data), terminalPending || latestFrame, stream.sessionID);
      // Observe token changes immediately, even if a later frame replaces this
      // one before painting. Pending input must never cross terminal identities.
      if (directMode && (frame.streamID || null) !== directStreamID) {
        stopDirect(); inputFailure = '터미널 연결이 바뀌어 직접 입력을 멈췄습니다. 보존한 입력과 새 화면을 확인해주세요.';
      }
      if (directMode && (!frame.keys.includes('characters') || !frame.keys.includes('backspace') || frame.inputReason)) {
        stopDirect(); inputFailure = frame.inputReason || '원본 입력 권한을 다시 연결해주세요.';
      }
      stream.reconnecting = false; stream.retries = 0; watchTerminalStream(stream);
      terminalPending = frame;
      terminalPendingAt = performance.now();
      if (terminalPaint) return;
      terminalPaint = requestAnimationFrame(() => {
        terminalPaint = 0;
        if (!current()) { terminalPending = null; return; }
        const frame = terminalPending, receivedAt = terminalPendingAt; terminalPending = null;
        try { if (frame) applyTerminalFrame(frame, receivedAt); } catch (error) { failTerminalStream(stream, error.message); }
      });
    } catch (error) { failTerminalStream(stream, error.message); }
  });
  source.addEventListener('failure', event => {
    if (!current()) return;
    let message = 'Mac의 터미널 연결이 끊겼습니다. 원래 터미널을 확인한 뒤 화면을 다시 연결해주세요.';
    try {
      if (event.data.length <= 8192) {
        const failure = JSON.parse(event.data);
        if (failure.retryable === true) { reconnectTerminalStream(stream); return; }
        if (typeof failure.error === 'string') message = failure.error;
      }
    } catch (_) {}
    failTerminalStream(stream, message);
  });
  source.onerror = () => { if (current()) reconnectTerminalStream(stream); };
}
async function refreshFrame() {
  clearTimeout(frameTimer);
  if (selectedItem?.view.pty) { ensurePTY(); return; }
  if (mutation) { frameTimer = setTimeout(refreshFrame, 100); return; }
  if (!selectedItem || !selectedItem.view.canRead || sessionEnded(selectedItem) || !allSessions.some(item => item.key === selectedKey) || document.hidden) { stopTerminalStream(); return; }
  if (supportsTerminalStream(selectedItem.node)) { frameController?.abort(); ensureTerminalStream(); return; }
  stopTerminalStream();
  if (loadingFrame) { frameTimer = setTimeout(refreshFrame, 100); return; }
  loadingFrame = true;
  const key = selectedKey, generation = detailGeneration, renderWindow = nativeTerminal(), item = selectedItem, previous = latestFrame;
  const started = performance.now(), controller = new AbortController(); frameController = controller;
  try {
    const query = new URLSearchParams({ node: item.node.id, session: item.session.id });
    if (renderWindow) query.set('view', 'screen');
    if (previous) query.set('revision', previous.revision);
    const update = await api('/api/terminal?' + query, undefined, controller.signal);
    if (selectedKey !== key || detailGeneration !== generation || renderWindow !== nativeTerminal()) return;
    applyTerminalFrame(mergeTerminalUpdate(update, previous, item.session.id));
  } catch (error) {
    if (controller.signal.aborted || selectedKey !== key || detailGeneration !== generation) return;
    latestFrame = null; stopDirect(); text($('terminal-error'), error.message); show($('terminal-error'), true); show($('terminal-retry'), true); terminalState('error', '연결 끊김');
  } finally {
    loadingFrame = false; if (frameController === controller) frameController = null; updateControls();
    clearTimeout(frameTimer);
    const active = Date.now() < fastFrameUntil || selectedItem?.session.phase === 'working' || quietFrames < 2;
    const interval = latestFrame ? directMode ? 150 : active ? 500 : Math.min(2000, 700 + quietFrames * 150) : 5000;
    if (selectedItem && !selectedItem.view.pty && !document.hidden && !supportsTerminalStream(currentNode() || selectedItem.node)) frameTimer = setTimeout(refreshFrame, controller.signal.aborted ? 0 : Math.max(100, interval - (performance.now() - started)));
  }
}
async function freshInputFrame(key) {
  const until = performance.now() + 6000;
  while (performance.now() < until && selectedKey === key && allSessions.some(item => item.key === key) && selectedItem?.view.canRead && !document.hidden && terminalStreamFailed !== key) {
    if (!mutation && terminalFrameFresh()) return !latestFrame.inputReason;
    if (!mutation && !loadingFrame) await refreshFrame();
    await new Promise(resolve => setTimeout(resolve, 40));
  }
  return false;
}
async function sendInput(kind, value = '', quiet = false) {
  if (mutation || inputInFlight || !latestFrame || !selectedItem || !inputKeys().includes(kind)) return false;
  const item = selectedItem, frame = latestFrame;
  const relay = !!frame.streamID && !composeMode && !['text', 'submit'].includes(kind);
  const consumedDraft = ['text', 'submit'].includes(kind) && $('terminal-input').value === value;
  if (consumedDraft) { $('terminal-input').value = ''; drafts.delete(item.key); sizeInput(); }
  mutation = !relay; inputInFlight = true;
  if (!relay) { detailGeneration++; frameController?.abort(); stopTerminalStream(); }
  terminalState('pending', '전달 중…'); updateControls();
  let sent = false;
  try {
    const result = await api(endpoint('/api/input', item.node.id), { sessionID: item.session.id, revision: frame.revision, kind, text: value, requestID: uuid(), ...(relay ? {relay: true, streamID: frame.streamID} : {}) });
    sent = true; if (selectedKey === item.key) inputFailure = ''; if (!quiet) feedback(result.message);
  } catch (error) {
    if (selectedKey === item.key) inputFailure = error.message;
    if (consumedDraft) {
      if (selectedKey === item.key && directMode) stopDirect(true, value);
      else restoreDirectDraft(value, item.key);
    }
    feedback(error.message, true);
  }
  finally {
    // Keep the consumed frame only as the binding for its pending successor.
    // Its invalid timestamp cannot authorize a second composed input.
    if (!relay && selectedKey === item.key) terminalFrameReceivedAt = -Infinity;
    if (!relay) mutation = false;
    quietFrames = 0; fastFrameUntil = Date.now() + 8000;
    if (!relay) await freshInputFrame(item.key);
    else if (selectedKey === item.key) { clearTimeout(frameTimer); void refreshFrame(); }
    inputInFlight = false; updateControls();
  }
  return sent;
}
function queueDirect(kind, value = '') {
  if (!directMode || $('terminal-keyboard').disabled || !inputKeys().includes(kind)) return false;
  if (directQueue.length >= 64 || byteLength(value) > 8000) { stopDirect(); inputFailure = '입력이 많아 바로 입력을 멈췄습니다. 현재 화면과 작성한 내용을 확인해주세요.'; updateControls(); return false; }
  const previous = directQueue[directQueue.length - 1];
  if (kind === 'characters' && previous?.kind === kind && byteLength(previous.value + value) <= 8000) previous.value += value;
  else directQueue.push({ key: selectedKey, kind, value, streamID: latestFrame?.streamID || null });
  clearTimeout(directTimer); directTimer = setTimeout(pumpDirect, kind === 'characters' ? 80 : 0);
  return true;
}
async function pumpDirect() {
  if (directSending || !directMode) return;
  directSending = true;
  const generation = inputGeneration;
  try {
    while (directMode && directQueue.length && inputGeneration === generation) {
      const item = directQueue[0];
      const fresh = await freshInputFrame(item.key);
      if (inputGeneration !== generation) break;
      if (selectedKey !== item.key || (latestFrame?.streamID || null) !== item.streamID) { stopDirect(); break; }
      if (!fresh) break; // Keep bounded unsent input until the same stream is verified again.
      directQueue.shift();
      const sent = await sendInput(item.kind, item.value, true);
      if (inputGeneration !== generation) {
        if (!sent && selectedKey === item.key) stopDirect(true, item.kind === 'characters' ? item.value : '');
        else if (!sent && item.kind === 'characters') restoreDirectDraft(item.value, item.key);
        break;
      }
      if (!sent) { stopDirect(true, item.kind === 'characters' ? item.value : ''); break; }
    }
  } finally {
    directSending = false; updateControls();
    if (directMode && directQueue.length) { clearTimeout(directTimer); directTimer = setTimeout(pumpDirect, 250); }
  }
}
function captureDirectText() {
  if (composing || !directMode || !keyboardText()) return;
  const value = keyboardText();
  // Let multiline paste stay editable; a user can send it as one composed Enter action.
  if (/[\x00-\x1f\x7f]/.test(value) || byteLength(value) > 8000) {
    stopDirect(); inputFailure = '여러 줄 또는 특수 문자가 포함된 입력은 내용을 확인한 뒤 Enter로 전송하세요.'; updateControls();
    $('terminal-input').focus({ preventScroll: true }); return;
  }
  if (queueDirect('characters', value)) resetKeyboard();
}
async function submitInput() {
  if (composing || $('send-input').disabled) return;
  if (!composeMode && inputKeys().includes('characters')) { armDirect(); captureDirectText(); if (directMode) { queueDirect('enter'); return; } }
  const value = $('terminal-input').value, key = selectedKey;
  if (!value) { await sendInput('enter'); return; }
  if (inputKeys().includes('submit')) { await sendInput('submit', value); return; }
  // Old bridges keep their original text contract; send Return only after confirmed delivery and a new frame.
  if (await sendInput('text', value) && selectedKey === key && selectedItem?.session.terminal !== 'terminal') await sendInput('enter');
}
function renderQuestions() {
  const { session, node } = selectedItem;
  const sources = [session, ...(session.backgroundSessions || [])];
  const signature = JSON.stringify(sources.map(source => [source.id, source.claudeApprovals, source.queuedQuestions, source.pendingSummary, source.capacityResume]));
  if (signature === questionSignature) return;
  // Capture every draft before status-driven rerender; never discard a typed answer on a polling tick.
  for (const form of $('questions').querySelectorAll('form')) {
    if (form.dataset.structured === 'true') continue;
    questionDrafts.set(form.dataset.questionKey, { answer: form.querySelector('textarea').value, choices: Array.from(form.querySelectorAll('input:checked')).map(input => input.value) });
  }
  const active = document.activeElement, activeQuestion = active?.closest('#questions form')?.dataset.questionKey;
  const wasText = active?.tagName === 'TEXTAREA', selectionStart = wasText ? active.selectionStart : null, selectionEnd = wasText ? active.selectionEnd : null;
  const fieldIndex = wasText && activeQuestion ? Array.from(active.closest('form').querySelectorAll('textarea')).indexOf(active) : 0;
  $('questions').replaceChildren(); questionSignature = signature;
  let count = 0;
  for (const source of sources) {
    for (const approval of source.claudeApprovals || []) {
      if (approval.questions?.length) {
        count++; $('questions').append(structuredQuestionForm(`${node.id}/${source.id}/${approval.id}`, approval.questions, {
          nodeID: node.id, title: source.id === session.id ? 'Claude의 질문' : 'Claude 백그라운드 질문', unavailable: approval.sending,
          status: approval.sending ? 'Claude에 답변을 전달하고 있습니다.' : approval.automaticAt ? '자동 응답 예약 · 답변을 작성하면 예약을 멈춥니다.' : '',
          begin: () => beginQuestionEditing(`${node.id}/${source.id}/${approval.id}`, node.id, {action:'beginClaudeQuestion', sessionID:source.id, requestIDForApproval:approval.id}),
          send: answers => sendQuestionAnswer(`${node.id}/${source.id}/${approval.id}`, node.id, {action:'replyClaudeQuestions', sessionID:source.id, requestIDForApproval:approval.id, answers}, 'Claude에 답변을 전달했습니다.')
        })); continue;
      }
      count++; const section = make('div', 'question'); section.append(make('h4', '', approval.summary));
      if (source.id !== session.id) section.append(make('p', 'muted small', 'Claude 백그라운드 요청'));
      if (approval.automaticAt) section.append(make('p', 'muted small', '자동 응답 예약 · ' + nowLabel(approval.automaticAt)));
      const actions = make('div', 'question-actions');
      for (const [label, actionName] of [[approval.isQuestion ? approval.answer : '이번 요청 허용', 'claudeApprove'], ['터미널에서 답하기', 'claudeRelease']]) {
        const button = make('button', actionName === 'claudeRelease' ? 'secondary' : '', label); button.dataset.unavailable = String(approval.sending);
        button.addEventListener('click', () => void action(node.id, { action: actionName, sessionID: source.id, requestIDForApproval: approval.id }, '요청을 처리했습니다.'));
        actions.append(button);
      }
      section.append(actions); $('questions').append(section);
    }
    for (const question of source.queuedQuestions || []) {
      count++; const questionKey = `${node.id}/${source.id}/${question.id}`, draft = questionDrafts.get(questionKey) || { answer: '', choices: [] };
      if (['failed','cancelled'].includes(question.reply?.phase) && !questionDeliveries.get(questionKey)?.busy && lastNetworkStartedAt > (questionDeliveries.get(questionKey)?.failedAt ?? questionDeliveries.get(questionKey)?.finishedAt ?? -Infinity)) {
        const state = questionDeliveries.get(questionKey) || {}; state.uncertain = false; state.sent = false;
        state.error = question.reply.phase === 'failed' ? question.reply.message : ''; state.message = question.reply.phase === 'cancelled' ? question.reply.message : ''; questionDeliveries.set(questionKey,state);
      }
      const form = make('form', 'question'); form.dataset.questionKey = questionKey; form.append(make('h4', '', question.title));
      const unavailable = ['sending', 'queued', 'uncertain'].includes(question.reply?.phase);
      form.dataset.readOnly = String(unavailable);
      if (question.reply?.phase) form.append(make('p', 'muted small', { sending: '답변을 전달하고 있습니다.', queued: '답변이 대기열에 등록되었습니다.', uncertain: '전달 결과를 확인하지 못했습니다. 터미널에서 확인해주세요.', failed: '답변 전달에 실패했습니다.', cancelled: '대기 입력을 삭제해 답변 전달을 취소했습니다.' }[question.reply.phase] || question.reply.phase));
      const options = make('div', 'question-options');
      for (const option of question.options || []) {
        const label = make('label', 'question-option'), checkbox = make('input'); checkbox.type = 'checkbox'; checkbox.value = option; checkbox.checked = draft.choices.includes(option); checkbox.disabled = unavailable;
        label.append(checkbox, make('span', '', option)); options.append(label);
      }
      form.append(options);
      const answerID = 'answer-' + uuid(), label = make('label', 'question-label', '직접 답변 또는 추가 설명'); label.htmlFor = answerID;
      const answer = make('textarea'); answer.id = answerID; answer.name = 'question-answer'; answer.autocomplete = 'off'; answer.rows = 2; answer.value = draft.answer; answer.disabled = unavailable; answer.maxLength = 8000;
      form.append(label, answer);
      const actions = make('div', 'question-actions'), send = make('button', '', '답변 보내기'); send.type = 'submit'; send.dataset.unavailable = String(unavailable || (!draft.answer.trim() && !draft.choices.length));
      function saveDraft() {
        const choices = Array.from(options.querySelectorAll('input:checked')).map(input => input.value);
        questionDrafts.set(questionKey, { answer: answer.value, choices });
        send.dataset.unavailable = String(unavailable || (!answer.value.trim() && !choices.length)); updateControls();
      }
      form.addEventListener('input', saveDraft); form.addEventListener('change', saveDraft);
      let editing = false;
      form.addEventListener('focusin', () => { if (!editing && !unavailable && ['scheduled', 'paused'].includes(question.automation?.phase)) { editing = true; beginQuestionEditing(questionKey, node.id, { action: 'beginQuestion', sessionID: source.id, questionID: question.id }); } });
      form.addEventListener('submit', event => {
        event.preventDefault(); saveDraft();
        const current = questionDrafts.get(questionKey); const value = [...current.choices, current.answer.trim()].filter(Boolean).join('\n');
        if (value && !unavailable && !send.disabled) void sendQuestionAnswer(questionKey, node.id, { action: 'replyQuestion', sessionID: source.id, questionID: question.id, answer: value }, '답변을 Codex 대기열에 등록했습니다.');
      });
      actions.append(send);
      if (['scheduled', 'paused', 'unavailable'].includes(question.automation?.phase)) {
        const cancel = make('button', 'secondary', '자동 응답 취소'); cancel.type = 'button';
        cancel.addEventListener('click', () => void action(node.id, { action: 'cancelQuestion', sessionID: source.id, questionID: question.id }, '이 질문의 자동 응답을 취소했습니다.')); actions.append(cancel);
      }
      appendQuestionDelivery(form); form.append(actions); $('questions').append(form);
    }
    if (source.pendingSummary && !(source.claudeApprovals || []).length && !(source.queuedQuestions || []).length) {
      count++; const section = make('div', 'question'); section.append(make('h4', '', source.pendingSummary), make('p', 'muted small', '이 요청은 터미널 화면에서 직접 답해주세요.')); $('questions').append(section);
    }
    if (source.capacityResume) {
      count++; const section = make('div', 'question'); section.append(make('h4', '', 'Codex 이어서 진행'), make('p', 'muted small', `${source.capacityResume.attempt}/${source.capacityResume.limit} · ${source.capacityResume.message}`));
      if (['scheduled', 'paused'].includes(source.capacityResume.phase)) { const button = make('button', 'secondary', '이어서 진행 취소'); button.addEventListener('click', () => void action(node.id, { action: 'cancelCapacity', sessionID: source.id }, '이어서 진행을 취소했습니다.')); section.append(button); }
      $('questions').append(section);
    }
  }
  show($('questions-section'), count > 0);
  text($('question-count'), count || '');
  if (activeQuestion && wasText) {
    const form = Array.from($('questions').querySelectorAll('form')).find(form => form.dataset.questionKey === activeQuestion);
    const answer = form?.querySelectorAll('textarea')[fieldIndex]; if (answer && !answer.disabled) { answer.focus({ preventScroll: true }); answer.setSelectionRange(selectionStart, selectionEnd); }
  }
}
function structuredQuestionForm(key, fields, config) {
  const form = make('form', 'question'); form.dataset.questionKey = key; form.dataset.structured = 'true'; form.dataset.nodeID = config.nodeID;
  form.dataset.readOnly = String(!!config.unavailable);
  form.append(make('h3', '', config.title));
  if (config.status) form.append(make('p', 'muted small', config.status));
  const draft = structuredDrafts.get(key) || {}, controls = [];
  const send = make('button', '', '답변 보내기'); send.type = 'submit';
  for (const field of fields) {
    const group = make('fieldset', 'question-field'); group.disabled = !!config.unavailable;
    group.append(make('legend', '', field.question));
    const choices = make('div', 'question-options'), current = draft[field.id] || {choices:[], text:''};
    for (const option of field.options || []) {
      const label = make('label', 'question-option'), input = make('input'); input.type = field.multiSelect ? 'checkbox' : 'radio';
      input.name = 'question-' + key + '-' + field.id; input.value = option.label; input.checked = current.choices.includes(option.label);
      const description = make('span', '', option.label); if (option.description) description.append(make('span', 'option-description', option.description));
      label.append(input, description); choices.append(label);
    }
    const answerID = 'answer-' + uuid(), label = make('label', 'question-label', field.options?.length ? '직접 답변 또는 추가 설명' : '답변'); label.htmlFor = answerID;
    const answer = make('textarea'); answer.id = answerID; answer.name = 'question-answer'; answer.rows = 2; answer.maxLength = 8000; answer.value = current.text;
    group.append(choices, label, answer); form.append(group); controls.push({id:field.id, choices, answer});
  }
  function save() {
    const answers = Object.fromEntries(controls.map(({id,choices,answer}) => [id, {choices:Array.from(choices.querySelectorAll('input:checked')).map(input=>input.value), text:answer.value}]));
    structuredDrafts.set(key, answers);
    send.dataset.unavailable = String(!!config.unavailable || !Object.values(answers).every(answer => answer.choices.length || answer.text.trim()));
    updateInteractionControls(); return answers;
  }
  form.addEventListener('input', save); form.addEventListener('change', save); let editing = false;
  form.addEventListener('focusin', () => { if (!editing && !config.unavailable && config.begin) { editing = true; void config.begin(); } });
  form.addEventListener('submit', async event => {
    event.preventDefault(); const answers = save();
    if (send.disabled || mutation) return;
    const success = await config.send(answers);
    if (success) structuredDrafts.delete(key);
  });
  const actions = make('div', 'question-actions'); actions.append(send); appendQuestionDelivery(form); form.append(actions); save(); return form;
}
function appendQuestionDelivery(form) {
  const status = make('p', 'muted small'); status.dataset.deliveryStatus = 'true'; status.setAttribute('role','status'); status.hidden = true;
  const error = make('p','error-text'); error.dataset.deliveryError = 'true'; error.setAttribute('role','alert'); error.hidden = true;
  form.append(status, error);
}
function interactionSources() { return selectedItem ? [selectedItem.session, ...(selectedItem.session.backgroundSessions || [])] : []; }
function renderInteractions() {
  const pending = interactionSources().reduce((count, source) => count + (source.claudeApprovals || []).filter(item => !item.sending).length
    + (source.queuedQuestions || []).filter(item => !['sending','queued'].includes(item.reply?.phase)).length
    + (source.pendingSummary && !(source.claudeApprovals || []).length && !(source.queuedQuestions || []).length ? 1 : 0), 0);
  const forms = nodes.flatMap(node => (node.state?.questionForms || []).map(request => ({node, request})));
  const signature = JSON.stringify(forms.map(({node,request})=>[node.id,node.online,request]));
  if (signature !== webFormSignature) {
    webFormSignature = signature;
    // Inputs save their draft on every change; retain the focused field across network updates.
    const active = document.activeElement, key = active?.closest('#web-question-forms form')?.dataset.questionKey;
    const fieldIndex = key ? Array.from(active.closest('form').querySelectorAll('textarea')).indexOf(active) : -1;
    const selection = fieldIndex >= 0 ? [active.selectionStart, active.selectionEnd] : null;
    $('web-question-forms').replaceChildren();
    for (const {node,request} of forms) $('web-question-forms').append(structuredQuestionForm(`${node.id}/mcp/${request.id}`, request.questions, {
      nodeID:node.id, title:`${request.title} · ${node.name}`, unavailable:!node.online,
      send:answers=>sendQuestionAnswer(`${node.id}/mcp/${request.id}`, node.id, {action:'replyWebQuestion', questionID:request.id, answers}, '질문에 답변했습니다.')
    }));
    if (key && selection) { const form = Array.from($('web-question-forms').querySelectorAll('form')).find(item=>item.dataset.questionKey===key); const field=form?.querySelectorAll('textarea')[fieldIndex]; if (field && !field.disabled) { field.focus({preventScroll:true}); field.setSelectionRange(...selection); } }
  }
  text($('question-count'), pending + forms.length || '');
  text($('global-questions'), `질문 ${forms.length}`); show($('global-questions'), forms.length > 0);
  show($('interaction-empty'), !pending && !forms.length);
  text($('interaction-session'), selectedItem ? `${selectedItem.node.name} · ${agents[selectedItem.session.agent]} · ${selectedItem.view.title}` : '터미널을 선택하면 새 메시지를 보낼 수 있습니다.');
  renderTestScreenList(); updateInteractionControls();
  const link = new URLSearchParams(location.hash.slice(1));
  if (!interactionLinkOpened && link.has('request') && forms.some(({request})=>request.id===link.get('request'))) { interactionLinkOpened=true; openInteraction(); }
  if (!interactionLinkOpened && link.has('share')) {
    const found = nodes.flatMap(node=>(node.state?.screenShares || []).map(share=>({node,share}))).find(item=>item.share.id===link.get('share'));
    if (found) { interactionLinkOpened=true; void openTestScreens(false,found); }
  }
}
function updateInteractionControls() {
  const replies = new Map(interactionSources().flatMap(source => (source.queuedQuestions || []).map(question => [`${selectedItem.node.id}/${source.id}/${question.id}`, question.reply])));
  for (const form of document.querySelectorAll('#interaction-dialog form.question')) {
    const node = nodes.find(item=>item.id===(form.dataset.nodeID || selectedItem?.node.id));
    const state = questionDeliveries.get(form.dataset.questionKey) || {};
    const reply = replies.get(form.dataset.questionKey);
    if (!state.busy && state.uncertain && lastNetworkStartedAt > state.failedAt && ['failed','cancelled'].includes(reply?.phase)) { state.uncertain = false; state.error = reply.phase === 'failed' ? reply.message : ''; }
    const available = connected && node?.online || node?.id === selectedItem?.node.id && originalStreamSelected();
    for (const button of form.querySelectorAll('button')) button.disabled = mutation || state.busy || state.sent || state.uncertain || !available || button.dataset.unavailable === 'true';
    for (const control of form.querySelectorAll('fieldset,input,textarea')) control.disabled = form.dataset.readOnly === 'true' || !!state.busy || !!state.sent || !!state.uncertain;
    if (state.busy) form.setAttribute('aria-busy','true'); else form.removeAttribute('aria-busy');
    const submit = form.querySelector('button[type=submit]'); if (submit) text(submit, state.busy ? '전달 중…' : state.sent ? '전달 완료' : '답변 보내기');
    const status = form.querySelector('[data-delivery-status]'), error = form.querySelector('[data-delivery-error]');
    if (status) { text(status,state.message || ''); show(status,!!state.message); }
    if (error) { text(error,state.error || ''); show(error,!!state.error); }
  }
  const present = selectedItem && allSessions.some(item=>item.key===selectedKey), codex = selectedItem?.session.agent === 'codex';
  const terminal = present && !['approval','input'].includes(selectedItem.session.phase) && !selectedItem.session.pendingInTerminal;
  const queueSupported = codex && supportsRelease(selectedItem.node,[0,2,46,57]);
  const available = present && connected && selectedItem.node.online && (queueSupported || !codex && terminal && (inputKeys().includes('submit') || latestFrame?.streamID && inputKeys().includes('characters')));
  const uncertain = messageUncertain.has(selectedKey);
  show($('new-message'), uncertain); $('new-message').disabled = messageSending;
  $('message-input').disabled = !present || messageSending || uncertain;
  $('send-message').disabled = !available || mutation || messageSending || uncertain || !$('message-input').value.trim();
  text($('send-message'), messageSending ? '전달 중…' : '메시지 보내기');
  text($('message-help'), !present ? '목록에서 메시지를 보낼 터미널을 선택해주세요.' : uncertain ? '전달 결과가 불확실합니다. 같은 내용을 다시 보내기 전에 원본 터미널의 접수를 확인해주세요.' : codex && !queueSupported ? '메시지 전송은 이 Mac을 AutoApprove 0.2.46 이상으로 업데이트하면 사용할 수 있습니다.' : codex ? '작업 중에도 같은 Codex 대화의 메시지 대기열로 전달합니다.' : !terminal ? '현재 터미널의 질문에 먼저 답변한 뒤 새 메시지를 보내주세요.' : !available ? '원본 터미널 입력 연결을 확인해주세요. 초안은 보관합니다.' : inputKeys().includes('submit') ? '같은 원본 터미널의 입력창에 메시지를 보냅니다.' : '이 원본 연결에서는 한 줄 메시지를 지원합니다.');
  updateQueueControls();
}
function openInteraction() {
  text($('message-status'),''); show($('message-error'),false);
  if (selectedItem) { renderQuestions(); $('message-input').value=messageDrafts.get(selectedKey) || ''; }
  else { show($('questions-section'),false); $('message-input').value=''; }
  renderInteractions(); if (!$('interaction-dialog').open) $('interaction-dialog').showModal();
  void refreshCodexQueue();
  if (!$('questions-section').hidden || $('web-question-forms').childElementCount) $('close-interaction').focus();
}
async function submitMessage(event) {
  event.preventDefault(); if ($('send-message').disabled || !selectedItem) return;
  const item = selectedItem, key = selectedKey, value=$('message-input').value; messageDrafts.set(key,value);
  messageSending=true; updateInteractionControls(); show($('message-error'),false); text($('message-status'),'');
  try {
    if (item.session.agent==='codex') {
      const result=await api(endpoint('/api/action',item.node.id), {action:'sendMessage', sessionID:item.session.id, text:value, requestID:uuid()});
      if(selectedKey===key)text($('message-status'),result.message || '메시지 대기열에 등록했습니다.');
    } else {
      if (inputKeys().includes('submit')) {
        if (!await sendInput('submit',value,true)) throw new Error('메시지 전달 결과를 확인하지 못했습니다. 원본 터미널을 확인해주세요.');
      } else {
        if (/[\r\n]/.test(value) || byteLength(value)>8000) throw Object.assign(new Error('이 원본 연결에는 8,000바이트 이내의 한 줄 메시지를 입력해주세요.'), {unsent:true});
        if (!await sendInput('characters',value,true)) throw new Error('메시지 전달 결과를 확인하지 못했습니다. 원본 터미널을 확인해주세요.');
        if (selectedKey!==key || !await freshInputFrame(key) || !await sendInput('enter','',true)) throw new Error('문자는 전달했지만 Enter 전달 결과를 확인하지 못했습니다. 원본 터미널을 확인해주세요.');
      }
      if(selectedKey===key)text($('message-status'),'원본 터미널에 메시지를 전달했습니다.');
    }
    messageDrafts.delete(key); if (selectedKey===key) { $('message-input').value=''; void refreshCodexQueue(); } await refreshNetwork();
  } catch (error) {
    if (!error.unsent && ![400,404].includes(error.status)) messageUncertain.add(key);
    if(selectedKey===key){text($('message-error'),error.message); show($('message-error'),true);}
  } finally { messageSending=false; updateControls(); }
}
function renderTestScreenList() {
  const shares=nodes.flatMap(node=>(node.state?.screenShares || []).map(share=>({node,share})));
  text($('screen-count'),shares.length || ''); text($('global-screens'),`공유 ${shares.length}`); show($('global-screens'),shares.length>0);
  const signature=JSON.stringify(shares.map(({node,share})=>[node.id,node.online,share])); if(signature===screenListSignature)return;
  screenListSignature=signature; $('test-screen-list').replaceChildren();
  if(!shares.length)$('test-screen-list').append(make('p','muted','공유 중인 테스트 화면이 없습니다. 화면 공유를 시작하면 여기에 표시됩니다.'));
  for(const {node,share} of shares){const row=make('div','test-screen-row'),info=make('div');info.append(make('strong','',share.title),make('p','muted small',`${node.name} · ${share.source.scope==='display'?'Mac 전체 화면':'Mac 창'} · ${nowLabel(share.expiresAt)}까지`));const open=make('button','secondary','화면 보기');open.disabled=!node.online;open.addEventListener('click',()=>selectTestScreen(node,share));row.append(info,open);$('test-screen-list').append(row);}
  // The selected capture endpoint authoritatively reports expiry/revocation.
  // An inventory timeout must not close a still-authorized image viewer.
}
async function openTestScreens(start = false, requested = null) {
  renderTestScreenList(); if (!$('test-screen-dialog').open) $('test-screen-dialog').showModal();
  screenStartNode = requested?.node || currentNode() || nodes.find(node => node.local && node.online) || nodes.find(node => node.online);
  text($('test-screen-source'), screenStartNode ? `${screenStartNode.name} · Mac 전체 화면 · 10분 동안 공유` : '화면을 공유할 Mac에 연결해주세요.');
  const shares = nodes.flatMap(node => (node.state?.screenShares || []).map(share => ({node,share}))).filter(item => item.node.online);
  const existing = requested || shares.find(item => item.node.id === screenStartNode?.id) || (!start ? shares[0] : null);
  show($('screen-start-error'),false); text($('screen-start-status'),'');
  show($('start-test-screen'),!existing); $('start-test-screen').disabled = screenStarting || !screenStartNode?.online || !supportsRelease(screenStartNode,[0,2,50,61]);
  if (existing) { selectTestScreen(existing.node, existing.share); return; }
  show($('test-screen-viewer'),false);
  if (screenStartNode && !supportsRelease(screenStartNode,[0,2,50,61])) text($('screen-start-status'),'이 Mac을 AutoApprove 0.2.50 이상으로 업데이트하면 버튼으로 화면 공유를 시작할 수 있습니다.');
  else if (start) await startTestScreen();
}
async function startTestScreen() {
  const node = screenStartNode; if (screenStarting || !node?.online || !supportsRelease(node,[0,2,50,61])) return;
  screenStarting = true; $('start-test-screen').disabled = true; show($('screen-start-error'),false); text($('screen-start-status'),'Mac 화면 공유를 시작하고 있습니다…');
  try {
    const result = await api(endpoint('/api/action', node.id), {action:'startScreenShare',requestID:uuid()});
    if (!result.share?.id || result.share.source?.scope !== 'display') throw new Error('Mac의 화면 공유 정보를 확인하지 못했습니다.');
    text($('screen-start-status'),''); void refreshNetwork();
    if ($('test-screen-dialog').open && screenStartNode?.id === node.id) { show($('start-test-screen'),false); selectTestScreen(node,result.share); }
  } catch (error) { text($('screen-start-error'),error.message); show($('screen-start-error'),true); text($('screen-start-status'),'화면 공유를 시작하지 못했습니다. Mac의 권한과 연결을 확인한 뒤 다시 시도해주세요.'); }
  finally { screenStarting = false; $('start-test-screen').disabled = !screenStartNode?.online; }
}
function updateQueueControls() {
  const codex = selectedItem?.session.agent === 'codex'; show($('codex-queue'),codex);
  if (!codex) return;
  if (queueSessionKey !== selectedKey) {
    queueSessionKey = selectedKey; queueGeneration++; queueSnapshot = null; queueLoading = false;
    $('queued-inputs').replaceChildren(); text($('queue-count'),''); text($('queue-status'),'목록을 갱신하면 현재 Codex 대기 입력을 확인합니다.'); show($('queue-error'),false); show($('queue-confirm'),false);
    show($('queue-conversation-picker'),false); show($('connect-queue-conversation'),false);
  }
  const supported = supportsRelease(selectedItem.node,[0,2,50,61]), online = connected && currentNode()?.online;
  $('refresh-queue').disabled = !online || !supported || queueLoading;
  text($('refresh-queue'), queueLoading ? '확인 중…' : '목록 갱신');
  $('clear-queue').disabled = !online || queueLoading || !queueSnapshot?.items.length;
  $('confirm-clear-queue').disabled = $('clear-queue').disabled;
  $('cancel-clear-queue').disabled = queueLoading;
  $('connect-queue-conversation').disabled = !online || !supported || queueLoading;
  $('queue-conversation').disabled = queueLoading;
  $('use-queue-conversation').disabled = !online || queueLoading || !$('queue-conversation').value;
  if (!supported) text($('queue-status'),'이 Mac을 AutoApprove 0.2.50 이상으로 업데이트하면 대기 입력을 확인하고 비울 수 있습니다.');
}
async function refreshCodexQueue() {
  updateQueueControls(); if (!selectedItem || $('refresh-queue').disabled) return;
  const item = selectedItem, key = selectedKey, generation = ++queueGeneration;
  queueLoading = true; queueSnapshot = null; show($('queue-confirm'),false); show($('queue-error'),false); text($('queue-status'),'Codex 대기 입력을 확인하고 있습니다…'); updateQueueControls();
  try {
    const chosen = queueConversations.get(key);
    const result = await api(endpoint('/api/codex/queue',item.node.id,item.session.id)+(chosen ? '&thread='+encodeURIComponent(chosen.id) : ''));
    if (generation !== queueGeneration || selectedKey !== key) return;
    if (result.sessionID !== item.session.id || typeof result.threadID !== 'string' || !Array.isArray(result.items) || result.items.some(entry => typeof entry.id !== 'string' || typeof entry.text !== 'string')) throw new Error('이 세션의 대기 입력 목록을 확인하지 못했습니다.');
    queueSnapshot = result; $('queued-inputs').replaceChildren();
    for (const entry of result.items) { const row = make('li','',entry.text || '첨부 입력'); if (entry.attachments) row.append(make('span','muted small',` · 첨부 ${entry.attachments}개`)); $('queued-inputs').append(row); }
    text($('queue-count'),result.items.length || ''); text($('queue-status'),(chosen ? `${chosen.title} · ` : '')+(result.items.length ? '아직 처리하지 않은 후속 입력입니다. 실행 중인 작업은 계속됩니다.' + (result.items.length > 100 ? ' 한 번에 100개씩 비웁니다.' : '') : '대기 입력이 없습니다.'));
    show($('queue-conversation-picker'),false); show($('connect-queue-conversation'),!!chosen);
  } catch (error) { if (generation === queueGeneration && selectedKey === key) { text($('queue-error'),error.message); show($('queue-error'),true); text($('queue-status'),'대기 입력을 확인하지 못했습니다. 대화 기록을 직접 열지 않는 Codex는 실행 중인 대화를 선택해 연결할 수 있습니다.'); show($('connect-queue-conversation'),true); } }
  finally { if (generation === queueGeneration) { queueLoading = false; updateQueueControls(); } }
}
async function chooseQueueConversation() {
  if ($('connect-queue-conversation').disabled || !selectedItem) return;
  const item = selectedItem, key = selectedKey, generation = ++queueGeneration;
  queueLoading = true; queueSnapshot = null; show($('queue-confirm'),false); show($('queue-error'),false); show($('queue-conversation-picker'),false); text($('queue-status'),'같은 작업 폴더의 실행 중인 Codex 대화를 확인하고 있습니다…'); updateQueueControls();
  try {
    const result = await api(endpoint('/api/codex/conversations',item.node.id,item.session.id));
    if (generation !== queueGeneration || selectedKey !== key) return;
    if (result.sessionID !== item.session.id || !Array.isArray(result.items) || result.items.some(entry=>typeof entry.id!=='string'||typeof entry.title!=='string')) throw new Error('Codex 대화 목록을 확인하지 못했습니다.');
    $('queue-conversation').replaceChildren(new Option('연결할 대화를 선택해주세요.',''));
    for (const entry of result.items) { const option = new Option(`${entry.title || 'Codex 대화'} · ${entry.id}`,entry.id); option.dataset.title = entry.title || 'Codex 대화'; $('queue-conversation').append(option); }
    show($('queue-conversation-picker'),result.items.length>0); text($('queue-status'),result.items.length ? '원본 Codex의 대화와 일치하는 항목을 선택해주세요. 선택한 대화의 대기 입력만 관리합니다.' : '이 작업 폴더에서 실행 중인 Codex 대화를 찾지 못했습니다. Mac에서 Codex 연결을 확인해주세요.');
  } catch (error) { if (generation === queueGeneration && selectedKey === key) { text($('queue-error'),error.message); show($('queue-error'),true); } }
  finally { if (generation === queueGeneration) { queueLoading = false; updateQueueControls(); } }
}
async function clearCodexQueue() {
  if ($('confirm-clear-queue').disabled || !queueSnapshot) return;
  const item = selectedItem, key = selectedKey, snapshot = queueSnapshot, generation = ++queueGeneration;
  queueLoading = true; updateQueueControls(); show($('queue-error'),false); text($('queue-status'),'선택한 대기 입력을 삭제하고 있습니다…');
  let status = '', errorMessage = '';
  try {
    const result = await api(endpoint('/api/action',item.node.id),{action:'clearQueuedInputs',sessionID:item.session.id,threadID:snapshot.threadID,queueIDs:snapshot.items.slice(0,100).map(entry=>entry.id),requestID:uuid()});
    status = `대기 입력 ${result.removed}개를 삭제했습니다.`;
  } catch (error) { errorMessage = error.message; }
  finally {
    if (generation === queueGeneration) {
      queueLoading = false; queueSnapshot = null; show($('queue-confirm'),false); updateQueueControls(); await refreshCodexQueue();
      if (selectedKey === key) {
        if (errorMessage) { text($('queue-error'),errorMessage); show($('queue-error'),true); }
        else if (status) text($('queue-status'),status + ' ' + $('queue-status').textContent);
      }
    }
  }
}
function stopTestScreenRead(){clearTimeout(sharedScreenTimer);sharedScreenController?.abort();sharedScreenController=null;}
function selectTestScreen(node,share){stopTestScreenRead();sharedScreen={node,share};$('test-screen-image').removeAttribute('src');$('test-screen-image').dataset.zoom='false';$('test-screen-zoom').setAttribute('aria-pressed','false');$('test-screen-zoom').setAttribute('aria-label','공유 화면 확대');$('test-screen-zoom').disabled=true;$('stop-test-screen').disabled=false;show($('test-screen-viewer'),true);show($('test-screen-error'),false);void readTestScreen();}
async function readTestScreen(){
  if(!sharedScreen||document.hidden||!$('test-screen-dialog').open)return;
  const current=sharedScreen,controller=new AbortController();sharedScreenController=controller;
  try{const result=await api(endpoint('/api/test-screen',current.node.id)+`&share=${encodeURIComponent(current.share.id)}`,undefined,controller.signal);
    if(sharedScreen!==current||controller.signal.aborted)return;
    const image=result.image;if(result.shareID!==current.share.id||typeof image?.data!=='string'||image.data.length>1000000||!Number.isInteger(image.width)||!Number.isInteger(image.height)||image.width<1||image.height<1||image.width>2048||image.height>2048)throw new Error('공유 화면의 형식이나 크기를 확인하지 못했습니다.');
    $('test-screen-image').width=image.width;$('test-screen-image').height=image.height;$('test-screen-image').src='data:image/jpeg;base64,'+image.data;text($('test-screen-status'),`${current.share.title} · ${nowLabel(result.observedAt)} 갱신 · 누르면 확대`);show($('test-screen-error'),false);show($('retry-test-screen'),false);
    sharedScreenTimer=setTimeout(readTestScreen,750);
  }catch(error){if(error.name==='AbortError')return;text($('test-screen-error'),error.message);show($('test-screen-error'),true);show($('retry-test-screen'),error.status!==410);if(error.status===410){$('test-screen-image').removeAttribute('src');$('stop-test-screen').disabled=true;}}
  finally{if(sharedScreenController===controller)sharedScreenController=null;}
}

$('global-questions').addEventListener('click',openInteraction);$('terminal-questions').addEventListener('click',openInteraction);
$('close-interaction').addEventListener('click',()=>$('interaction-dialog').close());
$('connect-queue-conversation').addEventListener('click',()=>void chooseQueueConversation());
$('queue-conversation').addEventListener('change',updateQueueControls);
$('use-queue-conversation').addEventListener('click',()=>{
  if ($('use-queue-conversation').disabled || !selectedItem) return;
  const option = $('queue-conversation').selectedOptions[0]; queueConversations.set(selectedKey,{id:option.value,title:option.dataset.title}); void refreshCodexQueue();
});
$('message-form').addEventListener('submit',submitMessage);$('message-input').addEventListener('input',()=>{if(selectedKey)messageDrafts.set(selectedKey,$('message-input').value);updateInteractionControls();});
$('new-message').addEventListener('click',()=>{if(!selectedKey||messageSending)return;messageUncertain.delete(selectedKey);messageDrafts.delete(selectedKey);$('message-input').value='';show($('message-error'),false);text($('message-status'),'이전 전달 결과는 원본 터미널에서 확인해주세요.');updateInteractionControls();$('message-input').focus();});
$('global-screens').addEventListener('click',()=>void openTestScreens());$('terminal-screens').addEventListener('click',()=>void openTestScreens(true));
$('start-test-screen').addEventListener('click',()=>void startTestScreen());
$('refresh-queue').addEventListener('click',()=>void refreshCodexQueue());
$('clear-queue').addEventListener('click',()=>{if($('clear-queue').disabled)return;show($('queue-confirm'),true);text($('confirm-clear-queue'),`${Math.min(100,queueSnapshot.items.length)}개 삭제`);text($('queue-status'),'현재 목록의 대기 입력을 삭제합니다. 삭제 후 복원할 수 없습니다. 새로 들어오는 입력은 유지합니다.');$('confirm-clear-queue').focus();});
$('cancel-clear-queue').addEventListener('click',()=>{show($('queue-confirm'),false);text($('queue-status'),'삭제를 취소했습니다.');$('clear-queue').focus();});
$('confirm-clear-queue').addEventListener('click',()=>void clearCodexQueue());
$('close-test-screen').addEventListener('click',()=>$('test-screen-dialog').close());$('test-screen-dialog').addEventListener('close',()=>{stopTestScreenRead();$('test-screen-image').removeAttribute('src');});
$('retry-test-screen').addEventListener('click',()=>void readTestScreen());
$('test-screen-image').addEventListener('load',()=>{$('test-screen-zoom').disabled=false;});
$('test-screen-image').addEventListener('error',()=>{if(!$('test-screen-image').hasAttribute('src'))return;stopTestScreenRead();$('test-screen-zoom').disabled=true;text($('test-screen-error'),'공유 이미지를 표시하지 못했습니다. 화면을 다시 연결해주세요.');show($('test-screen-error'),true);show($('retry-test-screen'),true);});
$('test-screen-zoom').addEventListener('click',()=>{const zoom=$('test-screen-image').dataset.zoom!=='true';$('test-screen-image').dataset.zoom=String(zoom);$('test-screen-zoom').setAttribute('aria-pressed',String(zoom));$('test-screen-zoom').setAttribute('aria-label',zoom?'공유 화면 맞춤':'공유 화면 확대');});
$('stop-test-screen').addEventListener('click',async()=>{if(!sharedScreen||mutation)return;const current=sharedScreen;stopTestScreenRead();if(await action(current.node.id,{action:'stopScreenShare',shareID:current.share.id},'화면 공유를 종료했습니다.')){$('test-screen-image').removeAttribute('src');sharedScreen=null;text($('test-screen-status'),'화면 공유가 종료되었습니다.');$('stop-test-screen').disabled=true;}});
document.addEventListener('visibilitychange',()=>{if(document.hidden){stopTestScreenRead();$('test-screen-image').removeAttribute('src');}else if(sharedScreen&&$('test-screen-dialog').open)void readTestScreen();});
function renderHistory() {
  const members = new Set([selectedItem.session.id, ...(selectedItem.session.backgroundSessions || []).map(item => item.id)]);
  const events = (selectedItem.node.state.snapshot.events || []).filter(event => members.has(event.sessionID) || members.has(event.originSessionID)).slice(0, 12);
  const signature = JSON.stringify(events); if (signature === historySignature) return; historySignature = signature;
  const expanded = new Set(Array.from($('history').querySelectorAll('details[open]')).map(item => item.dataset.id));
  $('history').replaceChildren();
  if (!events.length) { $('history').append(make('p', 'muted small', '아직 처리 내역이 없습니다.')); return; }
  for (const event of events) {
    const detail = make('details', 'history-item'); detail.dataset.id = event.id; detail.open = expanded.has(event.id);
    detail.append(make('summary', '', `${nowLabel(event.date)} · ${event.outcome}`), make('pre', '', [event.request || event.summary, event.answer ? `답변: ${event.answer}` : '', event.source].filter(Boolean).join('\n\n'))); $('history').append(detail);
  }
}

$('search').addEventListener('input', renderList); $('node-filter').addEventListener('change', renderList);
for (const button of document.querySelectorAll('[data-filter]')) button.addEventListener('click', () => {
  filter = button.dataset.filter; for (const option of document.querySelectorAll('[data-filter]')) option.setAttribute('aria-pressed', String(option === button)); renderList();
});
$('automatic').addEventListener('change', () => { const enabled = $('automatic').checked; void action(selectedItem.node.id, { action: 'automatic', sessionID: selectedItem.session.id, enabled }, enabled ? '자동 승인을 켰습니다.' : '자동 승인을 껐습니다.'); });
$('reveal').addEventListener('click', () => void action(selectedItem.node.id, { action: 'reveal', sessionID: selectedItem.session.id }, 'Mac에서 대상 터미널을 열었습니다.'));
$('terminal-input').addEventListener('input', () => { drafts.set(selectedKey, $('terminal-input').value); sizeInput(); updateControls(); });
$('terminal-input').addEventListener('compositionstart', () => { composing = true; updateControls(); });
$('terminal-input').addEventListener('compositionend', () => { composing = false; updateControls(); });
$('terminal-input').addEventListener('keydown', event => {
  if (composing || event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); void submitInput(); }
});
$('terminal-keyboard').addEventListener('focus', () => { if (!$('terminal-keyboard').disabled) armDirect(); updateControls(); });
$('terminal-keyboard').addEventListener('blur', () => { if (composing) stopDirect(); updateControls(); });
$('terminal-keyboard').addEventListener('input', event => {
  if (composing || event.isComposing) { text($('terminal-composition'), keyboardText()); show($('terminal-composition'), !!keyboardText()); scheduleCursor(); }
  else captureDirectText();
  updateControls();
});
$('terminal-keyboard').addEventListener('compositionstart', () => { composing = true; updateControls(); });
$('terminal-keyboard').addEventListener('compositionend', () => {
  composing = false; const generation = inputGeneration;
  setTimeout(() => { if (!composing && generation === inputGeneration) { captureDirectText(); show($('terminal-composition'), false); updateControls(); } }, 0);
  updateControls();
});
$('terminal-keyboard').addEventListener('beforeinput', event => {
  if (!directMode || composing || event.isComposing) return;
  if (['deleteContentBackward', 'deleteContentForward'].includes(event.inputType)) {
    event.preventDefault(); captureDirectText(); queueDirect(event.inputType === 'deleteContentBackward' ? 'backspace' : 'delete'); resetKeyboard();
  }
  if (['insertLineBreak', 'insertParagraph'].includes(event.inputType) && !event.defaultPrevented) { event.preventDefault(); void submitInput(); }
});
$('terminal-keyboard').addEventListener('keydown', event => {
  if (composing || event.isComposing || event.keyCode === 229) return;
  if (event.key === 'Enter') { event.preventDefault(); void submitInput(); return; }
  const keys = { Escape: 'escape', ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', Home: 'home', End: 'end', Delete: 'delete', Backspace: 'backspace', Tab: 'tab' };
  const kind = event.ctrlKey && event.key.toLowerCase() === 'c' ? 'interrupt' : keys[event.key];
  if (kind && !event.shiftKey && inputKeys().includes(kind)) {
    event.preventDefault(); captureDirectText(); queueDirect(kind);
  }
});
$('terminal-keyboard').addEventListener('paste', event => {
  if (!directMode || composing || !event.clipboardData) return;
  event.preventDefault(); $('terminal-keyboard').value = keyboardMarker + event.clipboardData.getData('text/plain'); captureDirectText(); updateControls();
});
$('input-form').addEventListener('submit', event => { event.preventDefault(); if (ptyClient) ptyClient.key('enter'); else void submitInput(); });
for (const button of $('input-form').querySelectorAll('button[data-key]')) button.addEventListener('click', () => {
  if (ptyClient) { ptyClient.key(button.dataset.key); return; }
  if (!composeMode) { armDirect(); captureDirectText(); queueDirect(button.dataset.key); } else void sendInput(button.dataset.key);
});
for (const button of $('input-form').querySelectorAll('button')) button.addEventListener('pointerdown', event => {
  if ((['terminal-input', 'terminal-keyboard'].includes(document.activeElement?.id) || document.activeElement === ptyClient?.term.textarea) && !document.activeElement.disabled) event.preventDefault();
});
$('compose-input').addEventListener('change', () => {
  const enabled = $('compose-input').checked; stopDirect(); composePreferred = enabled || !!$('terminal-input').value;
  if (!enabled && $('terminal-input').value) inputFailure = '먼저 작성한 내용을 전송하거나 지운 뒤 직접 입력으로 돌아가세요.';
  else inputFailure = '';
  updateControls(); $('terminal-settings').open = false;
  if (composeMode) $('terminal-input').focus({ preventScroll: true }); else focusKeyboard();
});
$('terminal-keyboard-toggle').addEventListener('click', () => {
  if (ptyClient) { ptyClient.focus(); return; }
  if (document.activeElement === $('terminal-keyboard')) { $('terminal-keyboard').blur(); updateControls(); } else focusKeyboard();
});
let screenPointer;
$('terminal-screen').addEventListener('pointerdown', event => {
  screenPointer = { x: event.clientX, y: event.clientY, at: event.timeStamp };
  if (composing && document.activeElement === $('terminal-keyboard')) event.preventDefault();
});
$('terminal-screen').addEventListener('click', event => {
  const selection = window.getSelection();
  const selecting = selection && !selection.isCollapsed && $('terminal-screen').contains(selection.anchorNode);
  const dragged = screenPointer && (Math.hypot(event.clientX - screenPointer.x, event.clientY - screenPointer.y) > 8 || event.timeStamp - screenPointer.at > 500);
  if (!selecting && !dragged && event.detail <= 1) focusKeyboard();
  screenPointer = null;
});
$('terminal-screen').addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); focusKeyboard(); } });
let nativePointer = null;
$('native-screen').addEventListener('pointerdown', event => {
  nativePointer = {x:event.clientX,y:event.clientY,at:event.timeStamp,left:$('native-screen').scrollLeft,top:$('native-screen').scrollTop,dragged:false};
  if (composing && document.activeElement === $('terminal-keyboard')) event.preventDefault();
  if (event.pointerType === 'mouse' && event.button === 0) $('native-screen').setPointerCapture(event.pointerId);
});
$('native-screen').addEventListener('pointermove', event => {
  if (!nativePointer || event.pointerType !== 'mouse' || event.buttons !== 1) return;
  const dx = event.clientX - nativePointer.x, dy = event.clientY - nativePointer.y;
  if (Math.hypot(dx, dy) > 8) nativePointer.dragged = true;
  if (nativePointer.dragged) { $('native-screen').scrollLeft = nativePointer.left - dx; $('native-screen').scrollTop = nativePointer.top - dy; event.preventDefault(); }
});
$('native-screen').addEventListener('click', event => {
  const viewport = $('native-screen');
  const dragged = nativePointer && (nativePointer.dragged || Math.hypot(event.clientX - nativePointer.x, event.clientY - nativePointer.y) > 8 || event.timeStamp - nativePointer.at > 500 || Math.abs(viewport.scrollLeft - nativePointer.left) + Math.abs(viewport.scrollTop - nativePointer.top) > 8);
  if (!dragged && event.detail <= 1) focusKeyboard(); nativePointer = null;
});
$('native-screen').addEventListener('pointercancel', () => { nativePointer = null; });
$('native-screen').addEventListener('keydown', event => { if (event.key === 'Enter') { event.preventDefault(); focusKeyboard(); } });
$('native-zoom-in').addEventListener('click', () => { nativeZoom = Math.min(nativeZoomLimit, nativeZoom * 1.5); fitNativeImage(); });
$('native-zoom-out').addEventListener('click', () => { nativeZoom = Math.max(1, nativeZoom / 1.5); fitNativeImage(); });
$('native-fit').addEventListener('click', () => { nativeZoom = 1; fitNativeImage(); });
$('native-view').addEventListener('change', () => {
  nativeSessionKey = $('native-view').checked ? selectedKey : ''; nativeZoom = 1; clearNativeImage();
  if (latestFrame) latestFrame = {...latestFrame, nativeDisplay:undefined};
  frameController?.abort(); stopTerminalStream(true); $('terminal-settings').open = false;
  renderTerminal(latestFrame?.screen || '', latestFrame?.appearance); updateControls(); scheduleCursor(); void refreshFrame();
});
function failNativeImage() {
  if (!nativeTerminal() || !nativeImageValue || !$('native-image').hasAttribute('src')) return;
  latestFrame = {...latestFrame, nativeDisplay:{state:'unavailable', message:'Mac 창 이미지를 표시하지 못했습니다. Mac 창 보기를 다시 켜주세요. 원본 입력은 유지됩니다.'}};
  clearNativeImage(); updateControls();
}
$('native-image').addEventListener('error', failNativeImage);
$('native-image').addEventListener('load', () => {
  const image = latestFrame?.nativeDisplay?.image;
  if (!image || !nativeTerminal()) return;
  if ($('native-image').naturalWidth !== image.width || $('native-image').naturalHeight !== image.height) { failNativeImage(); return; }
  fitNativeImage();
});
$('native-connect').addEventListener('click', async () => {
  if ($('native-connect').disabled || !nativeConnection()) return;
  const item = selectedItem, key = selectedKey, generation = detailGeneration;
  nativeConnectingKey = key; stopDirect(); frameController?.abort(); stopTerminalStream(true); latestFrame = null; updateControls();
  try {
    const result = await api(endpoint('/api/terminal/connect', item.node.id), {sessionID:item.session.id, requestID:uuid(), ...(nativeTerminal() ? {view:'screen'} : {})});
    if (selectedKey !== key || detailGeneration !== generation || document.hidden) return;
    if (typeof result.screen === 'string' && typeof result.revision === 'string') applyTerminalFrame(mergeTerminalUpdate(result, null, item.session.id));
    void refreshFrame(); void refreshNetwork();
  } catch (error) {
    if (selectedKey !== key || detailGeneration !== generation) return;
    terminalStreamFailed = key; text($('terminal-error'), error.message); show($('terminal-error'), true); show($('terminal-retry'), true); terminalState('error', '원본 연결 확인 필요');
  } finally { if (nativeConnectingKey === key) nativeConnectingKey = ''; if (selectedKey === key) updateControls(); }
});
$('terminal-focus').addEventListener('click', () => { terminalFocus(!document.body.classList.contains('terminal-focus')); if (!document.body.classList.contains('terminal-focus')) $('session-title').focus({ preventScroll: true }); });
$('terminal-back').addEventListener('click', () => $('back').click());
$('terminal-wrap').addEventListener('change', () => { $('terminal-screen').dataset.wrap = String($('terminal-wrap').checked); scheduleCursor(); });
$('terminal-screen').dataset.wrap = 'true';
$('font-smaller').addEventListener('click', () => setFontSize(terminalFontSize - 1));
$('font-larger').addEventListener('click', () => setFontSize(terminalFontSize + 1));
try { const saved = Number(localStorage.getItem('terminal-font-size')); if (saved >= 12 && saved <= 20) terminalFontSize = saved; } catch (_) {}
setFontSize(terminalFontSize);
window.visualViewport?.addEventListener('resize', updateViewport);
window.visualViewport?.addEventListener('scroll', updateViewport);
window.addEventListener('resize', updateViewport); updateViewport();
new ResizeObserver(scheduleCursor).observe($('terminal-screen'));
new ResizeObserver(fitNativeImage).observe($('native-screen'));
$('terminal-screen').addEventListener('scroll', scheduleCursor, { passive: true });
document.addEventListener('keydown', event => { if (event.key === 'Escape' && $('terminal-settings').open) { $('terminal-settings').open = false; $('terminal-settings').querySelector('summary').focus(); event.preventDefault(); } });
document.addEventListener('click', event => { if ($('terminal-settings').open && !$('terminal-settings').contains(event.target)) $('terminal-settings').open = false; });
$('terminal-retry').addEventListener('click', () => {
  text($('terminal-retry'), '화면 다시 연결');
  if (selectedItem?.view.pty) { stopPTY(); ensurePTY(); }
  else { stopTerminalStream(true); frameController?.abort(); void refreshFrame(); }
});
try { $('terminal-colors').checked = localStorage.getItem('terminal-colors') !== 'false'; } catch (_) {}
document.querySelector('.terminal').dataset.colored = String($('terminal-colors').checked);
$('terminal-colors').addEventListener('change', () => {
  document.querySelector('.terminal').dataset.colored = String($('terminal-colors').checked);
  try { localStorage.setItem('terminal-colors', String($('terminal-colors').checked)); } catch (_) {}
});
function followTerminal() {
  if (selectedItem?.session.terminal === 'tmux') scheduleCursor();
  else $('terminal-screen').scrollTop = $('terminal-screen').scrollHeight;
}
$('follow').addEventListener('change', () => { if ($('follow').checked) followTerminal(); show($('jump-latest'), !$('follow').checked); });
$('terminal-screen').addEventListener('scroll', () => {
  const pre = $('terminal-screen'), expected = terminalFollowScroll;
  const followingCursor = selectedItem?.session.terminal === 'tmux';
  const sameLayout = expected && expected.width === pre.clientWidth && expected.height === pre.clientHeight
    && expected.contentWidth === pre.scrollWidth && expected.contentHeight === pre.scrollHeight;
  // Browser reflow can adjust scroll offsets when the phone keyboard or viewport changes.
  if (followingCursor ? expected?.key === selectedKey && sameLayout && (expected.top !== pre.scrollTop || expected.left !== pre.scrollLeft) : pre.scrollHeight - pre.scrollTop - pre.clientHeight > 40) $('follow').checked = false;
  show($('jump-latest'), !$('follow').checked);
}, { passive: true });
$('jump-latest').addEventListener('click', () => { $('follow').checked = true; followTerminal(); show($('jump-latest'), false); });
$('back').addEventListener('click', () => {
  stopPTY(); stopTerminalStream(true);
  nativeSessionKey = ''; clearNativeImage();
  stopDirect(); composing = false; terminalFocus(false);
  drafts.set(selectedKey, $('terminal-input').value); const previous = rows.get(selectedKey)?.firstChild;
  selectedKey = ''; selectedItem = null; latestFrame = null; detailGeneration++; frameController?.abort(); clearTimeout(frameTimer);
  document.body.classList.remove('detail-open'); history.replaceState(null, '', location.pathname); show($('detail-content'), false); show($('detail-empty'), true); renderList(); previous?.focus();
});
$('refresh').addEventListener('click', () => { void refreshNetwork(); void refreshFrame(); });
$('add-mac').addEventListener('click', () => { show($('add-error'), false); $('add-dialog').showModal(); $('mac-address').focus(); });
$('close-dialog').addEventListener('click', () => $('add-dialog').close());
$('add-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = $('connect-mac'); if (button.disabled) return;
  button.disabled = true; text(button, '연결 중…'); show($('add-error'), false);
  try { const result = await api('/api/peers', { address: $('mac-address').value }); $('add-dialog').close(); feedback(`${result.name}에 연결했습니다.`); await refreshNetwork(); }
  catch (error) { text($('add-error'), error.message); show($('add-error'), true); $('mac-address').focus(); }
  finally { button.disabled = false; text(button, 'Mac 연결'); }
});
document.addEventListener('visibilitychange', () => {
  clearTimeout(networkTimer); clearTimeout(frameTimer);
  if (document.hidden) { nativeSessionKey = ''; clearNativeImage(); frameController?.abort(); stopTerminalStream(); latestFrame = null; stopDirect(); stopPTY(); updateControls(); }
  if (!document.hidden) { void refreshNetwork(); void refreshFrame(); }
});
window.addEventListener('hashchange', restoreSelection);
function openPTYDialog() {
  $('pty-node').replaceChildren(...nodes.filter(node => node.online).map(node => { const option = make('option', '', node.name); option.value = node.id; return option; }));
  if (selectedItem) $('pty-node').value = selectedItem.node.id;
  $('pty-directory').value = selectedItem?.session.cwd || '';
  $('pty-automatic').checked = false; show($('pty-error'), false);
  $('pty-dialog').showModal(); $('start-pty').focus();
}
$('new-pty').addEventListener('click', () => openPTYDialog());
$('close-pty-dialog').addEventListener('click', () => $('pty-dialog').close());
$('pty-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = $('start-pty'); if (button.disabled) return;
  const nodeID = $('pty-node').value;
  const payload = {cwd:$('pty-directory').value,program:$('pty-program').value};
  button.disabled = true; text(button, '터미널 여는 중…'); show($('pty-error'), false);
  try {
    const result = await api(endpoint('/api/pty', nodeID), {...payload, automatic:$('pty-automatic').checked, columns:80, rows:24, requestID:uuid()});
    $('pty-dialog').close();
    selectPTYDescriptor(nodeID, result, $('pty-automatic').checked, true);
  } catch (error) { text($('pty-error'), error.status === 404 ? '이 Mac에서 PTY를 지원하지 않습니다. AutoApprove 0.2.41 이상으로 업데이트해주세요.' : error.message); show($('pty-error'), true); }
  finally { button.disabled = false; text(button, '터미널 열기'); }
});
$('close-pty').addEventListener('click', async () => {
  if (!ptyClient || $('close-pty').disabled) return;
  if (!confirm('이 PTY에서 실행 중인 프로세스를 종료할까요? 브라우저만 닫으면 터미널은 계속 실행됩니다.')) return;
  const client = ptyClient; client.ending = true; client.ready = false; client.term.options.disableStdin = true; updateControls();
  try {
    await client.post('/api/pty/close', {});
    if (client === ptyClient) {
      selectedItem.view.pty.closed = true; retainEndedPTY(selectedItem); renderDetail(); renderList(); renderMachines();
      if (client.descriptor.exitCode == null) terminalState('pending', 'PTY 종료 중…');
    }
  } catch (error) { client.fail(error); }
});
resetKeyboard();
void refreshNetwork();
