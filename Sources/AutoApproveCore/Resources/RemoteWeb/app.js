'use strict';
const $ = id => document.getElementById(id);
const text = (element, value) => { const next = String(value ?? ''); if (element.textContent !== next) element.textContent = next; };
const show = (element, visible) => { element.hidden = !visible; };
const make = (tag, className, value) => { const element = document.createElement(tag); if (className) element.className = className; if (value !== undefined) text(element, value); return element; };
const uuid = () => typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, c => (Number(c) ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> Number(c) / 4).toString(16));
const agents = { codex: 'Codex', claude: 'Claude Code', shell: '셸' };
const hosts = { terminal: 'Terminal', iterm: 'iTerm2', orca: 'Orca', pty: 'PTY', vscode: 'VS Code', claudeBackground: 'Claude 백그라운드', unknown: '터미널 미확인' };
let nodes = [], allSessions = [], selectedKey = '', selectedItem = null, filter = 'all', latestFrame = null;
let connected = false, loadingNetwork = false, loadingFrame = false, mutation = false, networkTimer, frameTimer, feedbackTimer;
let detailGeneration = 0, questionSignature = '', historySignature = '';
let frameController = null, quietFrames = 0, fastFrameUntil = 0;
let terminalValue = null, terminalRows = [], terminalAppearanceKey = null;
let lastNetworkUpdate = null;
let directMode = false, composing = false, directSending = false, inputInFlight = false, directTimer, inputFailure = '';
let composePreferred = false, composeMode = false;
const keyboardMarker = '\u200b';
let inputGeneration = 0, terminalFontSize = 14;
let directStreamID = null;
let cursorLayoutPending = false;
const directQueue = [];
const rows = new Map(), machineRows = new Map(), drafts = new Map(), questionDrafts = new Map();
const keyFor = (node, session, view) => `${node.id}/${view?.ptyID ? 'pty:' + view.ptyID : session.id}`;
let ptyClient = null, continueItem = null, selectedOrigin = null;
const ptyDrafts = new Map();
const ptyTemporary = new Map(), ptyRetained = new Map(), ptyAttachments = new Map();
const sessionEnded = item => item?.session.phase === 'ended' || item?.view.pty?.exitCode != null || item?.view.pty?.closed === true;
function retainEndedPTY(item) {
  item.session.phase = 'ended'; item.session.automatic = false;
  item.session.detail = 'PTY가 종료되었습니다. 마지막 출력은 계속 볼 수 있습니다.';
  item.view.phaseTitle = '종료'; item.view.canApprove = false;
  ptyRetained.set(item.key, item); ptyTemporary.delete(item.key);
  allSessions = allSessions.filter(row => row.key !== item.key);
}
const supportsPTYAttach = node => {
  const version = versionNumbers(node.state?.release);
  if (!version) return false;
  const minimum = [0, 2, 41, 48];
  for (let i = 0; i < minimum.length; i++) if (version[i] !== minimum[i]) return version[i] > minimum[i];
  return true;
};
const canAttachPTY = item => !item.view.pty && supportsPTYAttach(item.node) && ['codex', 'claude'].includes(item.session.agent) && item.session.phase !== 'ended' && item.session.terminal !== 'claudeBackground';
const selectedAttachment = () => !selectedItem?.view.pty && ptyAttachments.get(selectedItem?.key);
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
function descriptorItem(nodeID, descriptor, source, automatic = false) {
  if (!descriptor || !descriptor.ptyID || !descriptor.streamID || typeof descriptor.cwd !== 'string' || !['shell','codex','claude'].includes(descriptor.program) || !Number.isInteger(descriptor.pid) || descriptor.pid < 1 || !Number.isInteger(descriptor.columns) || descriptor.columns < 20 || descriptor.columns > 240 || !Number.isInteger(descriptor.rows) || descriptor.rows < 5 || descriptor.rows > 100) throw new Error('PTY 연결 정보를 확인하지 못했습니다. 화면을 다시 연결해주세요.');
  const node = nodes.find(node => node.id === nodeID) || source?.node;
  if (!node) throw new Error('Mac 연결을 확인한 뒤 터미널을 다시 선택해주세요.');
  const session = {id:'pty:' + descriptor.ptyID, agent:descriptor.program, pid:descriptor.pid, started:descriptor.streamID, tty:descriptor.tty, cwd:descriptor.cwd, terminal:'pty', hostName:'PTY', phase:descriptor.exitCode != null ? 'ended' : 'idle', automatic, detail:'화면을 눌러 직접 입력하세요.'};
  const view = {session, title:source?.view.title || 'PTY · ' + descriptor.cwd.split('/').filter(Boolean).pop(), phaseTitle:descriptor.exitCode != null ? '종료' : '입력 대기', canApprove:false, canReveal:false, canRead:true, keys:[], ptyID:descriptor.ptyID, pty:descriptor};
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
function selectPTYDescriptor(nodeID, descriptor, source = null, automatic = false, focus = false) {
  const item = descriptorItem(nodeID, descriptor, source, automatic);
  const origin = source && {key:source.key, nodeID:source.node.id, sessionID:source.session.id};
  selectSession(item.key, focus, false, origin);
  // A slow peer inventory cannot hold up this already-created terminal.
  void refreshNetwork();
}
function renderAttachmentState() {
  const attachment = selectedAttachment();
  if (!attachment) return;
  if (attachment.state === 'pending') {
    terminalState('pending', '터미널 연결 중…'); terminalPlaceholder('직접 입력 터미널에 연결하는 중…');
    show($('terminal-error'), false); show($('terminal-retry'), false);
  } else if (attachment.state === 'error') {
    terminalState('error', '터미널 연결 확인 필요'); text($('terminal-error'), attachment.error);
    text($('terminal-retry'), '터미널 연결 다시 시도'); show($('terminal-error'), true); show($('terminal-retry'), true);
  }
}
async function attachPTY(item, focus = false, retry = false) {
  if (!canAttachPTY(item) || ptyAttachments.get(item.key)?.state === 'pending' || !retry && ptyAttachments.get(item.key)?.state === 'error') return;
  ptyAttachments.set(item.key, {state:'pending'}); stopDirect(); clearTimeout(frameTimer); frameController?.abort();
  if (selectedItem?.key === item.key) { renderAttachmentState(); updateControls(); }
  try {
    const descriptor = await api(endpoint('/api/pty', item.node.id), {sessionID:item.session.id, reuse:true, automatic:!!item.session.automatic, columns:80, rows:24, requestID:uuid()});
    const created = descriptorItem(item.node.id, descriptor, item, !!item.session.automatic);
    ptyAttachments.delete(item.key);
    if (selectedOrigin?.key === item.key && selectedItem?.key === item.key) selectSession(created.key, focus, false, selectedOrigin);
    void refreshNetwork();
  } catch (error) {
    ptyAttachments.set(item.key, {state:'error', error:error.status === 404 ? '이 Mac에서 PTY를 지원하지 않습니다. AutoApprove 0.2.41 이상으로 업데이트해주세요.' : error.message});
    if (selectedItem?.key === item.key) { renderAttachmentState(); updateControls(); void refreshFrame(); }
  }
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
  const streaming = supportsPTYAttach(item.node);
  if (ptyClient?.sessionKey === item.key && ptyClient.streaming === streaming) return;
  stopPTY();
  ptyClient = new AutoApprovePTY($('pty-screen'), {...item.view.pty}, item.node.id, api, uuid, ptyReport, terminalFontSize, streaming);
  ptyClient.sessionKey = item.key;
}
const currentNode = () => nodes.find(node => node.id === selectedItem?.node.id);
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
  pre.scrollTop = $('follow').checked && !selecting ? pre.scrollHeight : scrollTop; pre.scrollLeft = scrollLeft;
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
    await refreshNetwork();
  } catch (error) { feedback(error.message, true); }
  finally { mutation = false; if (selectedItem) $('automatic').checked = selectedItem.session.automatic; updateControls(); renderMachines(); }
}

async function refreshNetwork() {
  clearTimeout(networkTimer);
  if (loadingNetwork) return;
  loadingNetwork = true; $('refresh').disabled = true; $('refresh').setAttribute('aria-busy', 'true');
  try {
    const result = await api('/api/network');
    connected = true; nodes = result.nodes;
    allSessions = reconcilePTYInventory(nodes.flatMap(node => node.online ? (node.state?.sessions || []).map(view => ({ node, view, session: view.session, key: keyFor(node, view.session, view) })) : []));
    lastNetworkUpdate = result.updatedAt;
    text($('connection'), `${nodes.filter(node => node.online).length}대 연결 · ${nowLabel(lastNetworkUpdate)} 갱신`);
    show($('network-error'), false);
    text($('discovery'), result.discovery || ''); show($('discovery'), !!result.discovery);
    updateWebVersion(result);
    renderMachines(); renderNodeFilter(); renderList();
    if (selectedKey) {
      const current = allSessions.find(item => item.key === selectedKey);
      if (current) { selectedItem = current; renderDetail(); }
      else if (selectedItem?.view.pty) {
        // The active inventory drops closed processes before their final stream
        // bytes necessarily arrive. Keep this xterm and its retained last screen.
        const node = nodes.find(node => node.id === selectedItem.node.id);
        if (node) selectedItem.node = node;
        ptyRetained.set(selectedKey, selectedItem); renderDetail();
      }
      else if (selectedItem) { show($('session-ended'), true); latestFrame = null; stopDirect(); stopPTY(); terminalState('error', '세션 종료'); updateControls(); }
      else restoreSelection();
    } else restoreSelection();
  } catch (error) {
    connected = false; text($('connection'), lastNetworkUpdate ? `연결 끊김 · 마지막 갱신 ${nowLabel(lastNetworkUpdate)}` : '연결 끊김 · 다시 연결 중');
    show($('web-update'), false);
    text($('network-error'), error.message); show($('network-error'), true);
    if (!nodes.length) text($('list-empty'), 'Mac에 연결하면 감지된 세션이 여기에 표시됩니다.');
    latestFrame = null; stopDirect();
    if (!selectedItem?.view.pty) terminalState('error', '연결 끊김');
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
  const highlighted = selectedOrigin && allSessions.some(row => row.key === selectedOrigin.key) ? selectedOrigin.key : selectedKey;
  for (const [key, row] of rows) if (!visibleKeys.has(key)) { row.remove(); rows.delete(key); }
  for (const [index, item] of visible.entries()) {
    let row = rows.get(item.key);
    if (!row) {
      row = make('li'); const button = make('button', 'session-row');
      button.append(make('span', 'row-project'), make('span', 'row-title'), make('span', 'row-meta'));
      const state = make('span', 'row-state'); state.append(make('span', 'phase'), make('span', 'row-auto')); button.append(state); row.append(button);
      button.addEventListener('click', () => selectSession(item.key, true)); rows.set(item.key, row);
    }
    const button = row.firstChild; button.setAttribute('aria-pressed', String(item.key === highlighted));
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
function selectSession(key, focus = false, deliberate = focus, origin = null) {
  const source = allSessions.find(item => item.key === key) || ptyRetained.get(key); if (!source) return;
  // Revalidate every deliberate original-session selection: a CLI can change
  // conversations without changing PID/TTY. Only the Mac can verify that ID.
  const item = source;
  if (!source.view.pty) origin = {key:source.key, nodeID:source.node.id, sessionID:source.session.id};
  else if (!origin && selectedKey === item.key) origin = selectedOrigin;
  selectedOrigin = origin;
  if (selectedKey !== item.key) {
    stopPTY();
    stopDirect(); inputFailure = ''; composing = false;
    if (selectedKey) drafts.set(selectedKey, $('terminal-input').value);
    selectedKey = item.key; selectedItem = item; latestFrame = null; detailGeneration++;
    frameController?.abort(); quietFrames = 0; fastFrameUntil = Date.now() + 5000;
    $('detail').scrollTop = 0;
    $('terminal-input').value = drafts.get(item.key) || ''; composePreferred = !!$('terminal-input').value; sizeInput(); $('follow').checked = true; show($('jump-latest'), false); questionSignature = ''; historySignature = '';
    $('questions').replaceChildren(); $('history').replaceChildren();
    terminalPlaceholder('화면을 불러오는 중…'); terminalState('pending', '연결 중…'); text($('terminal-time'), '—'); show($('terminal-error'), false); show($('terminal-retry'), false);
  }
  document.body.classList.add('detail-open');
  if (window.innerWidth < 760) terminalFocus(true);
  const hash = new URLSearchParams({ node: item.node.id, session: selectedOrigin?.sessionID || item.session.id, ...(item.view.ptyID ? {pty: item.view.ptyID} : {}) });
  history.replaceState(null, '', `#${hash}`);
  renderList(); renderDetail();
  if (deliberate && canAttachPTY(item) && selectedAttachment()?.state !== 'error') void attachPTY(item, focus);
  else void refreshFrame();
  if (focus) { $(document.body.classList.contains('terminal-focus') ? 'terminal-heading' : 'session-title').focus({ preventScroll: true }); if (window.innerWidth < 760) window.scrollTo(0, 0); }
}
function restoreSelection() {
  const hash = new URLSearchParams(location.hash.slice(1));
  const item = allSessions.find(item => item.node.id === hash.get('node') && item.session.id === hash.get('session'))
    || allSessions.find(item => item.node.id === hash.get('node') && hash.get('pty') && item.view.ptyID === hash.get('pty'))
    || ptyRetained.get(hash.get('node') + '/pty:' + hash.get('pty'));
  if (item) selectSession(item.key, false, true);
}
function renderDetail() {
  if (!selectedItem) return;
  const { node, session, view } = selectedItem;
  const isPTY = !!view.pty;
  show($('terminal-screen'), !isPTY); show($('pty-screen'), isPTY);
  show($('pty-upgrade'), !isPTY && !supportsPTYAttach(node) && ['codex', 'claude'].includes(session.agent) && session.terminal !== 'claudeBackground'); show($('close-pty'), isPTY);
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
    latestFrame = null; terminalPlaceholder(view.inputReason || '화면 연결이 없습니다.'); terminalState('error', '화면 연결 필요'); text($('terminal-time'), '—');
  }
  renderAttachmentState(); renderQuestions(); renderHistory(); updateControls();
}
function updateControls() {
  if (!selectedItem) return;
  const current = currentNode(), sessionPresent = allSessions.some(item => item.key === selectedKey);
  const attaching = selectedAttachment()?.state === 'pending';
  const streamLive = !!selectedItem.view.pty && !!ptyClient?.ready;
  const enabled = (connected && current?.online || streamLive) && sessionPresent && !mutation && !attaching;
  const temporaryPTY = ptyTemporary.has(selectedKey);
  $('automatic').disabled = !enabled || temporaryPTY || (!selectedItem.view.canApprove && !selectedItem.session.automatic);
  $('automatic').title = temporaryPTY ? 'PTY에서 실행 중인 CLI를 확인하는 중입니다.' : !selectedItem.view.canApprove ? 'Mac에서 이 세션의 승인 연결을 먼저 설정해주세요.' : '이 세션의 다음 지원 요청부터 적용합니다.';
  $('reveal').disabled = !enabled || !selectedItem.view.canReveal;
  $('new-pty').disabled = !connected || !nodes.some(node => node.online);
  $('continue-pty').disabled = !enabled;
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
    text($('direct-input-help'), selectedOrigin ? '원래 터미널 유지 · 이어받은 대화에 직접 입력합니다. Shift Tab으로 포커스를 나갑니다.' : '화면을 눌러 직접 입력합니다. Shift Tab으로 키보드 포커스를 나갑니다.');
    $('direct-input-help').dataset.required = 'false'; text($('input-reason'), ''); $('input-reason').dataset.blocked = 'false'; text($('input-help'), '');
    return;
  }
  $('terminal-wrap').disabled = false; show($('input-form').querySelector('[data-key="eof"]'), false);
  const reason = !connected || !current?.online || !sessionPresent ? 'Mac과 세션의 연결을 확인해주세요.' : latestFrame?.inputReason || selectedItem.view.inputReason;
  const fresh = latestFrame && Date.now() - new Date(latestFrame.observedAt).getTime() < 10000;
  const base = connected && current?.online && sessionPresent && !reason && !attaching;
  const inputEnabled = enabled && fresh && !reason;
  // Keep the active editor alive while its own request/refresh runs: disabling it closes mobile keyboards.
  $('terminal-input').disabled = !(base && (fresh || inputInFlight || directSending));
  const supported = inputKeys(), canDirect = supported.includes('characters') && supported.includes('backspace');
  if ((!base || !canDirect) && directMode) stopDirect();
  const wasCompose = composeMode;
  composeMode = composePreferred || !canDirect || !!$('terminal-input').value;
  $('terminal-keyboard').disabled = !(base && canDirect && !composeMode && (fresh || inputInFlight || directSending));
  document.querySelector('.terminal').dataset.input = composeMode ? 'compose' : 'direct';
  show($('input-editor'), composeMode); show($('compose-input-label'), composeMode);
  if (composeMode && !wasCompose) sizeInput();
  $('compose-input').checked = composeMode; $('compose-input').disabled = !canDirect || composing;
  const keyboardActive = document.activeElement === $('terminal-keyboard') && !$('terminal-keyboard').disabled;
  $('terminal-keyboard-toggle').disabled = !(base && (fresh || inputInFlight || directSending)) || !canDirect || composeMode;
  $('terminal-keyboard-toggle').setAttribute('aria-pressed', String(keyboardActive));
  $('terminal-keyboard-toggle').setAttribute('aria-label', keyboardActive ? '터미널 키보드 닫기' : '터미널 키보드 열기');
  text($('direct-input-help'), !canDirect ? selectedItem.session.terminal === 'terminal'
    ? '화면 직접 입력은 Mac의 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 AutoApprove를 허용해야 합니다. 작성 후 Enter 전송은 사용할 수 있습니다.'
    : '화면 직접 입력은 Mac의 VS Code 확장을 업데이트하면 사용할 수 있습니다. 지금은 작성 후 Enter로 전송하세요.'
    : composeMode ? '작성 후 Enter로 전송합니다. 화면 설정에서 직접 입력으로 돌아갈 수 있습니다.'
    : keyboardActive ? '직접 입력 중 · 키와 완성된 한글을 기존 터미널로 전달합니다.' : '화면을 누르거나 키보드 버튼을 눌러 직접 입력하세요.');
  $('direct-input-help').dataset.required = String(!canDirect);
  $('terminal-keyboard-toggle').title = $('direct-input-help').textContent;
  text($('input-help'), composeMode ? 'Enter로 전송하고 Shift Enter로 줄을 바꿉니다. 한글 조합을 끝낸 뒤 전송하세요.' : '키보드의 문자·Enter·방향키를 직접 보냅니다. Shift Tab으로 포커스를 빠져나갑니다.');
  $('send-input').disabled = !(inputEnabled || directMode && base && directSending) || composing || inputInFlight && !directMode || byteLength($('terminal-input').value) > 8000;
  text($('send-input'), inputInFlight && !directMode ? '전달 중' : 'Enter');
  text($('input-reason'), inputFailure || reason || (fresh ? '현재 화면과 대상 CLI를 확인한 뒤 입력합니다.' : '최신 화면을 연결하면 입력할 수 있습니다.'));
  $('input-reason').dataset.blocked = String(!!inputFailure || !!reason || !fresh);
  for (const button of $('input-form').querySelectorAll('button[data-key]')) {
    const available = supported.includes(button.dataset.key);
    show(button, available); button.disabled = composing || !(base && (inputEnabled || directMode && directSending)); button.title = reason || `현재 터미널에 ${button.textContent} 키 입력`;
  }
  for (const button of $('questions').querySelectorAll('button')) button.disabled = !enabled || button.dataset.unavailable === 'true';
  scheduleCursor();
}
async function refreshFrame() {
  clearTimeout(frameTimer);
  if (selectedItem?.view.pty) { ensurePTY(); return; }
  if (selectedAttachment()?.state === 'pending') return;
  if (mutation) { frameTimer = setTimeout(refreshFrame, 100); return; }
  if (!selectedItem || !selectedItem.view.canRead || !connected || !currentNode()?.online || document.hidden) return;
  if (loadingFrame) { frameTimer = setTimeout(refreshFrame, 100); return; }
  loadingFrame = true;
  const key = selectedKey, generation = detailGeneration, item = selectedItem, previous = latestFrame;
  const started = performance.now(), controller = new AbortController(); frameController = controller;
  try {
    const query = new URLSearchParams({ node: item.node.id, session: item.session.id });
    if (previous) query.set('revision', previous.revision);
    const update = await api('/api/terminal?' + query, undefined, controller.signal);
    if (selectedKey !== key || detailGeneration !== generation) return;
    if (typeof update.screen !== 'string' && (!previous || update.revision !== previous.revision || update.sessionID !== previous.sessionID)) throw new Error('최신 화면을 다시 연결해주세요.');
    // Optional inputReason is omitted when a lock clears, even in an unchanged-screen response.
    const frame = typeof update.screen === 'string' ? update : { ...previous, ...update, inputReason: update.inputReason, cursor: update.cursor, streamID: update.streamID };
    if (directMode && (frame.streamID || null) !== directStreamID) {
      stopDirect(); inputFailure = '터미널 연결이 바뀌어 직접 입력을 멈췄습니다. 보존한 입력과 새 화면을 확인해주세요.';
    }
    latestFrame = frame;
    const changed = renderTerminal(frame.screen, frame.appearance);
    quietFrames = changed ? 0 : quietFrames + 1;
    terminalState(changed && previous ? 'changed' : 'live', !frame.screen.trim() ? '연결됨 · 빈 화면' : changed && previous ? '새 출력' : '연결됨');
    text($('terminal-time'), nowLabel(frame.observedAt)); show($('terminal-error'), false); show($('terminal-retry'), false);
  } catch (error) {
    if (controller.signal.aborted || selectedKey !== key || detailGeneration !== generation) return;
    latestFrame = null; stopDirect(); text($('terminal-error'), error.message); show($('terminal-error'), true); show($('terminal-retry'), true); terminalState('error', '연결 끊김');
  } finally {
    loadingFrame = false; frameController = null; renderAttachmentState(); updateControls();
    clearTimeout(frameTimer);
    const active = Date.now() < fastFrameUntil || selectedItem?.session.phase === 'working' || quietFrames < 2;
    const interval = latestFrame ? directMode ? 150 : active ? 500 : Math.min(2000, 700 + quietFrames * 150) : 5000;
    if (selectedItem && !document.hidden) frameTimer = setTimeout(refreshFrame, controller.signal.aborted ? 0 : Math.max(100, interval - (performance.now() - started)));
  }
}
async function freshInputFrame(key) {
  const until = Date.now() + 6000;
  while (Date.now() < until && selectedKey === key && connected && currentNode()?.online && selectedItem?.view.canRead && !document.hidden) {
    if (!mutation && latestFrame && Date.now() - new Date(latestFrame.observedAt).getTime() < 10000) return !latestFrame.inputReason;
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
  if (!relay) { detailGeneration++; frameController?.abort(); }
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
    if (!relay && selectedKey === item.key) latestFrame = null;
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
      if (selectedKey !== item.key || !fresh || (latestFrame?.streamID || null) !== item.streamID) { stopDirect(); break; }
      directQueue.shift();
      const sent = await sendInput(item.kind, item.value, true);
      if (inputGeneration !== generation) {
        if (!sent && selectedKey === item.key) stopDirect(true, item.kind === 'characters' ? item.value : '');
        else if (!sent && item.kind === 'characters') restoreDirectDraft(item.value, item.key);
        break;
      }
      if (!sent) { stopDirect(true, item.kind === 'characters' ? item.value : ''); break; }
    }
  } finally { directSending = false; updateControls(); if (directMode && directQueue.length) void pumpDirect(); }
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
    questionDrafts.set(form.dataset.questionKey, { answer: form.querySelector('textarea').value, choices: Array.from(form.querySelectorAll('input:checked')).map(input => input.value) });
  }
  const active = document.activeElement, activeQuestion = active?.closest('#questions form')?.dataset.questionKey;
  const wasText = active?.tagName === 'TEXTAREA', selectionStart = wasText ? active.selectionStart : null, selectionEnd = wasText ? active.selectionEnd : null;
  $('questions').replaceChildren(); questionSignature = signature;
  let count = 0;
  for (const source of sources) {
    for (const approval of source.claudeApprovals || []) {
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
      const form = make('form', 'question'); form.dataset.questionKey = questionKey; form.append(make('h4', '', question.title));
      const unavailable = ['sending', 'queued', 'uncertain'].includes(question.reply?.phase);
      if (question.reply?.phase) form.append(make('p', 'muted small', { sending: '답변을 전달하고 있습니다.', queued: '답변이 대기열에 등록되었습니다.', uncertain: '전달 결과를 확인하지 못했습니다. 터미널에서 확인해주세요.', failed: '답변 전달에 실패했습니다.' }[question.reply.phase] || question.reply.phase));
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
      form.addEventListener('input', saveDraft);
      let editing = false;
      form.addEventListener('focusin', () => { if (!editing && !unavailable && ['scheduled', 'paused'].includes(question.automation?.phase)) { editing = true; void action(node.id, { action: 'beginQuestion', sessionID: source.id, questionID: question.id }); } });
      form.addEventListener('submit', event => {
        event.preventDefault(); saveDraft();
        const current = questionDrafts.get(questionKey); const value = [...current.choices, current.answer.trim()].filter(Boolean).join('\n');
        if (value && !unavailable) void action(node.id, { action: 'replyQuestion', sessionID: source.id, questionID: question.id, answer: value }, '답변을 전달했습니다.');
      });
      actions.append(send);
      if (['scheduled', 'paused', 'unavailable'].includes(question.automation?.phase)) {
        const cancel = make('button', 'secondary', '자동 응답 취소'); cancel.type = 'button';
        cancel.addEventListener('click', () => void action(node.id, { action: 'cancelQuestion', sessionID: source.id, questionID: question.id }, '이 질문의 자동 응답을 취소했습니다.')); actions.append(cancel);
      }
      form.append(actions); $('questions').append(form);
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
  if (activeQuestion && wasText) {
    const form = Array.from($('questions').querySelectorAll('form')).find(form => form.dataset.questionKey === activeQuestion);
    const answer = form?.querySelector('textarea'); if (answer && !answer.disabled) { answer.focus({ preventScroll: true }); answer.setSelectionRange(selectionStart, selectionEnd); }
  }
}
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
$('terminal-screen').addEventListener('scroll', scheduleCursor, { passive: true });
document.addEventListener('keydown', event => { if (event.key === 'Escape' && $('terminal-settings').open) { $('terminal-settings').open = false; $('terminal-settings').querySelector('summary').focus(); event.preventDefault(); } });
document.addEventListener('click', event => { if ($('terminal-settings').open && !$('terminal-settings').contains(event.target)) $('terminal-settings').open = false; });
$('terminal-retry').addEventListener('click', () => {
  text($('terminal-retry'), '화면 다시 연결');
  if (selectedItem?.view.pty) { stopPTY(); ensurePTY(); }
  else if (selectedAttachment()?.state === 'error' && canAttachPTY(selectedItem)) void attachPTY(selectedItem, false, true);
  else void refreshFrame();
});
try { $('terminal-colors').checked = localStorage.getItem('terminal-colors') !== 'false'; } catch (_) {}
document.querySelector('.terminal').dataset.colored = String($('terminal-colors').checked);
$('terminal-colors').addEventListener('change', () => {
  document.querySelector('.terminal').dataset.colored = String($('terminal-colors').checked);
  try { localStorage.setItem('terminal-colors', String($('terminal-colors').checked)); } catch (_) {}
});
$('follow').addEventListener('change', () => { if ($('follow').checked) $('terminal-screen').scrollTop = $('terminal-screen').scrollHeight; show($('jump-latest'), !$('follow').checked); });
$('terminal-screen').addEventListener('scroll', () => { const pre = $('terminal-screen'); if (pre.scrollHeight - pre.scrollTop - pre.clientHeight > 40) $('follow').checked = false; show($('jump-latest'), !$('follow').checked); }, { passive: true });
$('jump-latest').addEventListener('click', () => { $('follow').checked = true; $('terminal-screen').scrollTop = $('terminal-screen').scrollHeight; show($('jump-latest'), false); });
$('back').addEventListener('click', () => {
  stopPTY();
  stopDirect(); composing = false; terminalFocus(false);
  drafts.set(selectedKey, $('terminal-input').value); const previous = rows.get(selectedOrigin?.key || selectedKey)?.firstChild;
  selectedKey = ''; selectedItem = null; selectedOrigin = null; latestFrame = null; detailGeneration++; frameController?.abort(); clearTimeout(frameTimer);
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
  if (document.hidden) { frameController?.abort(); stopDirect(); stopPTY(); }
  if (!document.hidden) { void refreshNetwork(); void refreshFrame(); }
});
window.addEventListener('hashchange', restoreSelection);
function openPTYDialog(item = null) {
  continueItem = item;
  $('pty-node').replaceChildren(...nodes.filter(node => node.online).map(node => { const option = make('option', '', node.name); option.value = node.id; return option; }));
  if (item) $('pty-node').value = item.node.id;
  else if (selectedItem) $('pty-node').value = selectedItem.node.id;
  $('pty-node').disabled = !!item; $('pty-directory').required = !item;
  $('pty-directory').value = selectedItem?.session.cwd || '';
  $('pty-automatic').checked = !!item?.session.automatic;
  text($('pty-title'), item ? 'PTY에서 대화 이어가기' : '새 PTY 터미널');
  text($('pty-description'), item ? '선택한 대화 내용을 이어받은 새 세션을 엽니다. 원래 터미널은 유지됩니다. 대화 ID를 확인하지 못하면 CLI의 대화 선택 화면이 열립니다.' : 'Mac에서 실행되는 터미널입니다. 화면을 눌러 바로 입력할 수 있습니다.');
  text($('pty-context'), item ? `${agents[item.session.agent]} · ${item.session.cwd}` : '');
  show($('pty-context'), !!item); show($('pty-new-options'), !item); show($('pty-error'), false);
  text($('start-pty'), item ? '대화 이어가기' : '터미널 열기');
  $('pty-dialog').showModal(); $('start-pty').focus();
}
$('new-pty').addEventListener('click', () => openPTYDialog());
$('continue-pty').addEventListener('click', () => { if (canAttachPTY(selectedItem)) void attachPTY(selectedItem, false, true); else openPTYDialog(selectedItem); });
$('close-pty-dialog').addEventListener('click', () => $('pty-dialog').close());
$('pty-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = $('start-pty'); if (button.disabled) return;
  const item = continueItem, nodeID = $('pty-node').value;
  const payload = item ? {sessionID:item.session.id,reuse:true} : {cwd:$('pty-directory').value,program:$('pty-program').value};
  button.disabled = true; text(button, item ? '대화 확인 중…' : '터미널 여는 중…'); show($('pty-error'), false);
  try {
    const result = await api(endpoint('/api/pty', nodeID), {...payload, automatic:$('pty-automatic').checked, columns:80, rows:24, requestID:uuid()});
    $('pty-dialog').close();
    selectPTYDescriptor(nodeID, result, item, $('pty-automatic').checked, true);
  } catch (error) { text($('pty-error'), error.status === 404 ? '이 Mac에서 PTY를 지원하지 않습니다. AutoApprove 0.2.41 이상으로 업데이트해주세요.' : error.message); show($('pty-error'), true); }
  finally { button.disabled = false; text(button, item ? '대화 이어가기' : '터미널 열기'); }
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
