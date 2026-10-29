'use strict';
let terminalHistoryViewer=null,terminalHistoryLoading=null;
async function openTerminalHistory() {
  const item=selectedItem,key=selectedKey;
  if(!item||$('terminal-history-open').disabled)return;
  $('terminal-settings').open=false;$('terminal-history-open').disabled=true;
  try {
    if(!window.AutoApproveTerminalHistory){
      if(!terminalHistoryLoading)terminalHistoryLoading=new Promise((resolve,reject)=>{
        const script=document.createElement('script');script.src='/terminal-history.js';
        const timer=setTimeout(()=>{script.remove();terminalHistoryLoading=null;reject(Error('전체 기록 화면을 받지 못했습니다. 다시 열어주세요.'));},8000);
        script.onload=()=>{clearTimeout(timer);resolve();};script.onerror=()=>{clearTimeout(timer);script.remove();terminalHistoryLoading=null;reject(Error('전체 기록 화면을 불러오지 못했습니다. 다시 열어주세요.'));};
        document.head.append(script);
      });
      await terminalHistoryLoading;
    }
    if(selectedKey!==key)return;
    if(!terminalHistoryViewer)terminalHistoryViewer=new window.AutoApproveTerminalHistory({api,endpoint});
    await terminalHistoryViewer.open(item);
  }catch(error){feedback(error.message,true);}
  finally{updateControls();}
}
const tunnelAccess=document.querySelector('meta[name="autoapprove-tunnel"]')?.content || '';
let tunnelAuthExpired=false;
if(tunnelAccess){
  const clearSharedKey=()=>{const fragment=new URLSearchParams(location.hash.slice(1));if(fragment.has('access')){fragment.delete('access');history.replaceState(null,'',location.pathname+location.search+(fragment.size?'#'+fragment.toString():''));}};
  window.addEventListener('hashchange',clearSharedKey);clearSharedKey();
}
const $ = id => document.getElementById(id);
const text = (element, value) => { const next = String(value ?? ''); if (element.textContent !== next) element.textContent = next; };
const show = (element, visible) => { const hidden = !visible; if (element.hidden !== hidden) element.hidden = hidden; };
const setBusy = (element, value) => { const busy = String(!!value); if (element.getAttribute('aria-busy') !== busy) element.setAttribute('aria-busy',busy); };
const make = (tag, className, value) => { const element = document.createElement(tag); if (className) element.className = className; if (value !== undefined) text(element, value); return element; };
if(tunnelAccess){
  show($('tunnel-access'),true);text($('tunnel-access-state'),tunnelAccess==='polling'?'외부 접속 · 임시 터널 화면 조회':'외부 접속 · 실시간 터널');
  $('tunnel-logout').addEventListener('click',async()=>{
    const button=$('tunnel-logout');button.disabled=true;
    try{await api('/auth/logout',{});location.replace('/auth');}
    catch(error){text($('tunnel-access-state'),error.message);button.disabled=false;}
  });
}
const uuid = () => typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : '10000000-1000-4000-8000-100000000000'.replace(/[018]/g, c => (Number(c) ^ crypto.getRandomValues(new Uint8Array(1))[0] & 15 >> Number(c) / 4).toString(16));
const agents = { codex: 'Codex', claude: 'Claude Code', shell: '셸' };
const hosts = { terminal: 'Terminal', iterm: 'iTerm2', orca: 'Orca', tmux: 'tmux', pty: 'PTY', vscode: 'VS Code', claudeBackground: 'Claude 백그라운드', unknown: '터미널 미확인' };
let nodes = [], allSessions = [], selectedKey = '', selectedItem = null, filter = 'all', latestFrame = null;
let gatewayTerminalWireVersion = null;
let gatewayNetworkWaitVersion = null;
let connected = false, loadingNetwork = false, loadingFrame = false, mutation = false, networkTimer, frameTimer, feedbackTimer;
let partialNetwork = false, partialNetworkRefreshes = 0;
let detailGeneration = 0, questionSignature = '', historySignature = '';
let frameController = null, quietFrames = 0, fastFrameUntil = 0;
let terminalStream = null, terminalPending = null, terminalPaint = 0, terminalPaintTimer = null, terminalStreamFailed = '';
let terminalFrameReceivedAt = -Infinity, terminalPendingAt = -Infinity;
const terminalFrameFresh = () => !document.hidden && !!latestFrame && !terminalStream?.reconnecting && performance.now() - terminalFrameReceivedAt < 10000;
// One short-lived text basis in page memory. Never stores terminal data on disk
// or carries permission/freshness across a phone background transition.
let terminalWarm = null, terminalWarmTimer = null;
const terminalOriginalIdentity = item => JSON.stringify([item?.node.id,item?.session.id,item?.session.pid,item?.session.started,item?.session.tty,item?.session.terminal,item?.session.bridgeID,item?.session.terminalID,item?.session.orcaHandle,item?.session.tmuxHandle]);
function clearTerminalWarm() { clearTimeout(terminalWarmTimer); terminalWarmTimer = null; terminalWarm = null; }
function rememberTerminalWarm() {
  clearTerminalWarm();
  if (!selectedItem || selectedItem.view.pty || nativeTerminal() || !latestFrame?.streamID || sessionEnded(selectedItem)) return;
  terminalWarm = {key:selectedKey,identity:terminalOriginalIdentity(selectedItem),frame:latestFrame,until:performance.now()+30000};
  terminalWarmTimer = setTimeout(clearTerminalWarm,30000);
}
function restoreTerminalWarm() {
  const saved = terminalWarm;
  if (!saved || saved.key !== selectedKey || saved.identity !== terminalOriginalIdentity(selectedItem) || performance.now() >= saved.until || !selectedItem?.view.canRead || sessionEnded(selectedItem)) { clearTerminalWarm(); return false; }
  latestFrame = saved.frame; terminalFrameReceivedAt = -Infinity;
  terminalState('pending','연결 확인 중…'); updateControls(); return true;
}
let nativeSessionKey = '', nativeZoom = 1, nativeZoomLimit = 4, nativeImageValue = null, nativeConnectingKey = '';
const nativeTerminal = () => !!selectedItem && !selectedItem.view.pty && nativeSessionKey === selectedKey;
const nativeConnection = () => !!selectedItem && !selectedItem.view.pty && selectedItem.session.terminal !== 'tmux' && (supportsNativeTerminal(selectedItem.node) || !!latestFrame?.nativeDisplay);
let terminalValue = null, terminalRows = [], terminalAppearanceKey = null;
let terminalFollowScroll = null;
let lastNetworkUpdate = null;
let lastNetworkStartedAt = -Infinity;
// One page-local inventory only; no disk/browser cache of terminal or input data.
const networkValidation = {etag:'', value:null, notModified:false, observedAt:null};
let appliedNetworkETag = '', networkController = null;
let networkFailures = 0, networkRefreshRequested = false;
let networkGatewayID = '';
let directMode = false, composing = false, directSending = false, inputInFlight = false, directTimer = null, directTimerDue = Infinity, inputFailure = '';
let directChannel = null, directCandidate = null, directChannelState = 'idle', directChannelStreamID = null, directFreshening = false;
let directChannelRetries = 0, directChannelStableAt = 0, directChannelRetry = null;
let composePreferred = false, composeMode = false;
const keyboardMarker = '\u200b';
let inputGeneration = 0, terminalFontSize = 14;
let directStreamID = null;
let cursorLayoutPending = false, cursorLayoutTimer = null, cursorLayoutFrame = null;
const directQueue = [];
const automationResets = new Set();
let automationResetResult = null;
const automationResetNodes = new Set(), automationResetNodeErrors = new Map();
let allAutomationResetResult = null;
const rows = new Map(), machineRows = new Map(), drafts = new Map(), questionDrafts = new Map();
const interruptionRows = new Map();
// Exact saved receipts only, bounded to this page. A late inventory response
// cannot undo a successful read or revive its ended session and warning.
const interruptionReceipts = new Map();
const interruptionReceiptKey = (key,id) => JSON.stringify([key,id]);
function rememberInterruptionReceipt(key,id,date) {
  const receipt = interruptionReceiptKey(key,id);
  interruptionReceipts.delete(receipt); interruptionReceipts.set(receipt,date);
  while (interruptionReceipts.size > 1024) interruptionReceipts.delete(interruptionReceipts.keys().next().value);
}
function reconcileInterruptionReceipts(inventory) {
  for (const item of inventory) {
    const error = item.session.interruption;
    if (!error) continue;
    if (error.acknowledgedAt != null) rememberInterruptionReceipt(item.key,error.id,error.acknowledgedAt);
    else {
      const date = interruptionReceipts.get(interruptionReceiptKey(item.key,error.id));
      if (date != null) error.acknowledgedAt = date;
    }
  }
}
const safetyRows = new Map();
const sessionHistories = new Map();
// History is auxiliary: one cancelable read, and a bounded page-memory cache.
let historyRequest = null, historyInView = !('IntersectionObserver' in window);
let terminalLibraries = null;
let terminalLibraryAttempt = 0;
const structuredDrafts = new Map(), messageDrafts = new Map();
const questionDeliveries = new Map(), questionEditing = new Map();
let queueSnapshot = null, queueLoading = false, queueGeneration = 0, queueSessionKey = '';
const queueConversations = new Map();
let screenStarting = false, screenStartNode = null;
let webFormSignature = '', screenListSignature = '', sharedScreen = null, sharedScreenTimer, sharedScreenController, sharedScreenFailures = 0;
const stoppedScreenShares = new Set();
let screenControl=null,screenControlBusy=false,screenControlEpoch=0,screenControlModuleTask=null;
const screenControlDrafts=new Map();
const messageDeliveries = new Map(), messageReceiptReads = new Set();
let messageUncertain = new Set(), interactionLinkOpened = false, messageReceiptTimer;
const messageStorage = 'autoapprove-message-drafts-v1';
const cleanupStorage = 'autoapprove-web-cleanup-v1';
let cleanup = {macs:new Set(),warnings:new Set(),questions:new Set()};
let messageCleanupUndo = null, messageCleanupTimer, messageCleanupError = null;
let questionCleanupBusy=false, questionCleanupUndo=null, questionCleanupTimer, questionCleanupStatus='', questionCleanupError='';
const questionReviewKeys=new Set();
try {
  const saved = JSON.parse(localStorage.getItem(cleanupStorage) || '{}');
  for (const [kind,limit] of [['macs',128],['warnings',1024],['questions',2048]]) {
    if (Array.isArray(saved[kind])) cleanup[kind] = new Set(saved[kind].filter(value=>typeof value==='string' && value.length<=2048).slice(-limit));
  }
} catch (_) {}
// Presentation history only: a retry cannot promote a known offline Mac into
// the active region. Input and connection checks still use the current node.
const offlineMacIDs = new Set(cleanup.macs);
const displayedOfflineMac = node => !node.online && (!node.loading || offlineMacIDs.has(node.id));
function updateMacPlacement(incoming) {
  const present = new Set(incoming.map(node=>node.id));
  for (const id of offlineMacIDs) if (!present.has(id)) offlineMacIDs.delete(id);
  for (const node of incoming) {
    if (node.local || node.online) offlineMacIDs.delete(node.id);
    else if (!node.loading) offlineMacIDs.add(node.id);
  }
}
function saveCleanup(changes) {
  const value = Object.fromEntries(Object.entries(cleanup).map(([kind,entries])=>[kind,[...(changes[kind] || entries)].slice(-({macs:128,warnings:1024,questions:2048}[kind]))]));
  try { localStorage.setItem(cleanupStorage,JSON.stringify(value)); }
  catch (_) {
    const message='표시 정리를 저장하지 못했습니다. 브라우저 저장 공간을 확인한 뒤 다시 시도해주세요.';
    if($('interaction-dialog').open){messageCleanupError={sessionKey:selectedKey,message};updateInteractionControls();}
    feedback(message,true);return false;
  }
  messageCleanupError=null;
  cleanup = Object.fromEntries(Object.entries(value).map(([kind,entries])=>[kind,new Set(entries)]));
  appliedNetworkETag = ''; updateCleanupControls(); return true;
}
const warningKey = (item,source,kind) => JSON.stringify([kind,item.node.id,source.id,kind==='safety' ? source.systemSafety?.id : source.interruption?.id]);
const warningHidden = (item,source,kind) => cleanup.warnings.has(warningKey(item,source,kind));
const pastQuestionKey = (node,source,question) => JSON.stringify([node.id,source.id,question.id,question.reply?.queueID || '']);
const questionKeyFor = (node,source,question) => `${node.id}/${source.id}/${question.id}`;
const questionReviewKey = (node,source,question) => questionKeyFor(node,source,question)+'/'+(question.cleanupToken || question.title);
function pastQuestionEligible(node,source,question) {
  if (!(question.hasLaterUserMessage || question.reply?.phase==='queued') || ['sending','uncertain'].includes(question.reply?.phase)) return false;
  const key=questionKeyFor(node,source,question),draft=questionDrafts.get(key),delivery=questionDeliveries.get(key);
  const composed=[...(draft?.choices || []),draft?.answer?.trim() || ''].filter(Boolean).join('\n');
  const unsubmitted=composed && !(question.reply?.phase==='queued' && composed===question.reply.answer);
  return !unsubmitted && !delivery?.busy && !delivery?.uncertain && (question.reply?.phase==='queued' || !questionReviewKeys.has(questionReviewKey(node,source,question)));
}
function pastQuestionRecords() {
  const result=new Map();
  for(const item of allSessions)for(const source of [item.session,...(item.session.backgroundSessions || [])])for(const question of source.queuedQuestions || []) {
    if(pastQuestionEligible(item.node,source,question)) {
      const key=pastQuestionKey(item.node,source,question);
      if(!question.cleanupToken && cleanup.questions.has(key))continue;
      result.set(key,{key,node:item.node,source,question});
    }
  }
  return [...result.values()];
}
function updateQuestionCleanupControls() {
  const records=pastQuestionRecords(),count=records.filter(v=>v.node.online || !v.question.cleanupToken).length;
  text($('clean-all-past-questions'),questionCleanupBusy ? '질문 정리 중…' : `지난 질문${count ? ' '+count+'개' : ''} 정리`);
  $('clean-all-past-questions').disabled=questionCleanupBusy || !count;
  for(const prefix of ['global-question-cleanup','question-cleanup']) {
    show($(prefix+'-result'),!!questionCleanupStatus || !!questionCleanupError);
    text($(prefix+'-status'),[questionCleanupStatus,questionCleanupError].filter(Boolean).join(' '));
    $(prefix+'-status').className=questionCleanupError ? 'error-text small' : 'muted small';
    show($(prefix+'-undo'),!!questionCleanupUndo);$(prefix+'-undo').disabled=questionCleanupBusy;
  }
  $('clear-past-questions').disabled=questionCleanupBusy || records.some(r=>r.node.id===selectedItem?.node.id && r.source.id===selectedItem?.session.id && r.question.cleanupToken && !r.node.online);
}
async function cleanQuestionRecords(records) {
  if(questionCleanupBusy || !records.length)return;
  questionCleanupBusy=true;questionCleanupStatus='지난 질문을 정리하고 있습니다…';questionCleanupError='';updateQuestionCleanupControls();
  const grouped=new Map(),legacy=[],completed=[];let count=0;const errors=[];
  for(const record of records) {
    if(!record.question.cleanupToken){legacy.push(record.key);continue;}
    const key=JSON.stringify([record.node.id,record.source.id]);
    if(!grouped.has(key))grouped.set(key,{nodeID:record.node.id,sessionID:record.source.id,questions:[]});
    grouped.get(key).questions.push({id:record.question.id,token:record.question.cleanupToken});
  }
  try {
    for(const group of grouped.values())for(let i=0;i<group.questions.length;i+=512) {
      const batch={...group,questions:group.questions.slice(i,i+512)};
      try {
        const result=await api(endpoint('/api/action',batch.nodeID),{action:'cleanPastQuestions',sessionID:batch.sessionID,questions:batch.questions,requestID:uuid()});
        if(result.count!==batch.questions.length)throw new Error('정리 결과를 확인하지 못했습니다.');
        count+=result.count;completed.push(batch);
      } catch(error){errors.push(error.message);}
    }
    if(legacy.length && saveCleanup({questions:new Set([...cleanup.questions,...legacy])}))count+=legacy.length;
    else if(legacy.length)errors.push('이 브라우저의 표시 정리를 저장하지 못했습니다.');
    if(completed.length) {
      questionCleanupUndo={groups:completed,count};clearTimeout(questionCleanupTimer);
      questionCleanupTimer=setTimeout(()=>{questionCleanupUndo=null;updateQuestionCleanupControls();},60000);
    }
    questionCleanupStatus=count ? `지난 질문 ${count}개를 정리했습니다.${completed.length ? ' 1분 동안 되돌릴 수 있습니다.' : ' 이 브라우저에만 적용됩니다.'}` : '';
    questionCleanupError=errors.length ? `일부 질문은 정리하지 못했습니다. ${errors[0]} 목록을 확인한 뒤 다시 시도해주세요.` : '';
    questionSignature='';if(selectedItem)renderQuestions();await refreshNetwork(false,true);if(selectedItem)renderQuestions();
  } finally {
    questionCleanupBusy=false;updateQuestionCleanupControls();
    const focus=$('interaction-dialog').open ? (questionCleanupUndo ? $('question-cleanup-undo') : $('message-input')) : $('clean-all-past-questions');
    focus.focus({preventScroll:true});
  }
}
async function undoQuestionCleanup() {
  const undo=questionCleanupUndo;if(!undo || questionCleanupBusy)return;
  questionCleanupBusy=true;questionCleanupError='';updateQuestionCleanupControls();const failed=[];let restored=0;
  try {
    for(const group of undo.groups) {
      try {const result=await api(endpoint('/api/action',group.nodeID),{action:'restorePastQuestions',sessionID:group.sessionID,questions:group.questions,requestID:uuid()});restored+=result.count;}
      catch(error){failed.push(group);questionCleanupError=error.message;}
    }
    questionCleanupUndo=failed.length ? {...undo,groups:failed} : null;
    if(!questionCleanupUndo)clearTimeout(questionCleanupTimer);
    questionCleanupStatus=`지난 질문 ${restored}개의 표시를 복원했습니다. 다음 질문 조회에 반영됩니다.`;
    questionSignature='';await refreshNetwork();if(selectedItem)renderQuestions();
  } finally {questionCleanupBusy=false;updateQuestionCleanupControls();}
}
function offlineMacs() {
  return nodes.filter(node=>!node.local && displayedOfflineMac(node) && !(selectedItem?.node.id===node.id && (originalReadSelected() || originalStreamSelected())));
}
const unconfirmedMac = node => !node.local && !node.online && node.loading && !node.state
  && !(selectedItem?.node.id===node.id && (originalReadSelected() || originalStreamSelected()));
function displayedWarnings() {
  return allSessions.flatMap(item=>[
    ...(unreadInterruption(item.session) && !warningHidden(item,item.session,'interruption') ? [warningKey(item,item.session,'interruption')] : []),
    ...[item.session,...(item.session.backgroundSessions || [])].filter(source=>source.systemSafety && !warningHidden(item,source,'safety')).map(source=>warningKey(item,source,'safety'))
  ]);
}
function updateCleanupControls() {
  const count = offlineMacs().length;
  text($('clean-offline-macs'),`연결 끊긴 Mac${count ? ' '+count+'대' : ''} 정리`);
  $('clean-offline-macs').disabled = !connected || !count;
  $('clean-warnings').disabled = displayedWarnings().length===0;
  $('restore-cleanup').disabled = !Object.values(cleanup).some(values=>values.size);
  updateQuestionCleanupControls();
}
function cleanOfflineMacs(ids = offlineMacs().map(node=>node.id)) {
  const eligible = new Set(offlineMacs().map(node=>node.id)), chosen = ids.filter(id=>eligible.has(id));
  if (!connected || !chosen.length || !saveCleanup({macs:new Set([...cleanup.macs,...chosen])})) return;
  feedback(`연결 끊긴 Mac ${chosen.length}대의 표시를 정리했습니다.`); void refreshNetwork();
}
function cleanWarnings(keys = displayedWarnings()) {
  if (!keys.length || !saveCleanup({warnings:new Set([...cleanup.warnings,...keys])})) return;
  const focusedWarning = document.activeElement?.closest('.interruption-row, #session-safety');
  renderMachines(); renderList(); if (selectedItem) renderSessionSafety();
  if(focusedWarning && document.activeElement===document.body)($('interruption-list').querySelector('button') || $('system-safety-list').querySelector('button') || $('search')).focus({preventScroll:true});
  feedback('경고 표시를 정리했습니다. 새 경고는 다시 표시됩니다.');
}
const nonASCIIText = /[^\x00-\x7f]/;
const byteLength = (value, limit = Infinity) => {
  value = value === undefined ? '' : String(value); let bytes = 0;
  // UTF-8 uses at least one byte per UTF-16 unit. A known limit violation
  // needs no scan; long ASCII text has exactly one byte per unit.
  if (value.length > limit) return value.length;
  if (value.length > 256 && value.charCodeAt(0) < 128 && !nonASCIIText.test(value)) return value.length;
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    if (code <= 0x7f) bytes++;
    else if (code <= 0x7ff) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff && index + 1 < value.length) {
      const next = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) { bytes += 4; index++; }
      else bytes += 3; // TextEncoder replaces an unpaired surrogate with U+FFFD.
    } else bytes += 3;
    if (bytes > limit) return bytes;
  }
  return bytes;
};
try {
  const saved = JSON.parse(sessionStorage.getItem(messageStorage) || '{}');
  for (const [key,value] of Object.entries(saved.drafts || {})) if(typeof value === 'string' && byteLength(value,32000) <= 32000) messageDrafts.set(key,value);
  for (const [key,value] of Object.entries(saved.deliveries || {})) if(value && typeof value.requestID === 'string' && typeof value.text === 'string' && byteLength(value.text,32000) <= 32000 && ['busy','uncertain','failed','accepted'].includes(value.phase)) {
    if(value.phase === 'busy') value.phase = 'uncertain';
    messageDeliveries.set(key,value); if(value.phase === 'uncertain') messageUncertain.add(key);
  }
} catch (_) {}
function saveMessageDrafts() {
  const next=new Map(messageDeliveries),counts=new Map();
  // Only confirmed archived messages are bounded. Uncertain/busy/failed and
  // the current delivery are retained, as are every unsubmitted draft.
  for(const [key,record] of [...next].reverse())if(key.includes('#') && record.phase==='accepted') {
    const scope=key.slice(0,key.lastIndexOf('#')),count=(counts.get(scope)||0)+1;counts.set(scope,count);
    if(count>20)next.delete(key);
  }
  try {
    sessionStorage.setItem(messageStorage,JSON.stringify({drafts:Object.fromEntries(messageDrafts),deliveries:Object.fromEntries(next)}));
    for(const key of messageDeliveries.keys())if(!next.has(key)){messageDeliveries.delete(key);messageUncertain.delete(key);}
  } catch (_) {}
}
saveMessageDrafts();
const messageBusy = key => messageDeliveries.get(key)?.phase === 'busy';
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
  const version = versionNumbers(node?.state?.release);
  if (!version) return false;
  for (let i = 0; i < minimum.length; i++) if (version[i] !== minimum[i]) return version[i] > minimum[i];
  return true;
};
const supportsPTYStream = node => supportsRelease(node, [0, 2, 41, 48]);
const supportsTerminalStream = node => tunnelAccess !== 'polling' && supportsRelease(node, [0, 2, 42, 49]);
const supportsTerminalWire = node => {
  const owner = node?.state?.terminalWireVersion;
  return [2,3].includes(gatewayTerminalWireVersion) && [2,3].includes(owner) ? Math.min(gatewayTerminalWireVersion,owner) : 0;
};
const supportsNativeTerminal = node => supportsRelease(node, [0, 2, 43, 51]);
function reconcilePTYInventory(inventory) {
  inventory = inventory.filter(item => (!sessionEnded(item) || item.session.interruption?.recoveredAt == null && !!item.session.interruption) && !sessionEnded(ptyRetained.get(item.key)));
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
  inputQuality(null);
}
function inputQuality(value) {
  const target = $('terminal-latency'); if (!target) return;
  const valid = value && value.samples > 0 && Number.isFinite(value.medianMS);
  show(target,valid);
  const number = amount => Math.round(amount).toLocaleString();
  text(target,valid ? `${number(value.medianMS)}ms` : '');
  target.title = valid ? `입력 왕복 중앙값 · 95% ${number(value.p95MS)}ms · ${number(value.samples)}회` : '';
  target.setAttribute('aria-label',valid ? `입력 왕복 지연 중앙값 ${Math.round(value.medianMS)}밀리초` : '입력 왕복 지연 측정 전');
}
function ptyReport(state, message, client) {
  if (client !== ptyClient) return;
  if (state === 'quality') { inputQuality(client.inputQuality); return; }
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
async function loadTerminalLibraries() {
  if (!terminalLibraries) terminalLibraries = (async () => {
    const pending = new Set();
    const assets = [
      ['/vendor/xterm.css',() => !!document.querySelector('link[data-terminal-style]')?.sheet,true],
      ['/vendor/xterm.js',() => typeof window.Terminal === 'function'],
      ['/vendor/xterm-fit.js',() => typeof window.FitAddon?.FitAddon === 'function'],
      ['/pty.js',() => typeof window.AutoApprovePTY === 'function']
    ];
    try {
      // These files only define independent classes. Start their requests
      // together, then instantiate a terminal after every dependency is ready.
      await Promise.all(assets.filter(([,ready]) => !ready()).map(([src,,style]) => new Promise((resolve,reject) => {
        const element = document.createElement(style ? 'link':'script');
        // A removed script can retain a stalled browser fetch. A retry needs a
        // fresh request instead of joining that same unfinished cache entry.
        const address = terminalLibraryAttempt ? src+'?reconnect='+terminalLibraryAttempt:src;
        if (style) { element.rel = 'stylesheet'; element.href = address; element.dataset.terminalStyle = 'true'; }
        else { element.src = address; element.async = true; }
        const cleanup = remove => { clearTimeout(timer); element.onload = element.onerror = null; pending.delete(cleanup); if (remove) element.remove(); };
        const fail = () => { cleanup(true); reject(new Error('터미널 구성 요소를 받지 못했습니다. 화면 다시 연결을 눌러주세요.')); };
        const timer = setTimeout(fail,8000); pending.add(cleanup);
        element.onload = () => { cleanup(false); resolve(); }; element.onerror = fail; document.head.append(element);
      })));
      if (assets.some(([,ready]) => !ready())) throw new Error('터미널 구성 요소를 확인하지 못했습니다. 화면 다시 연결을 눌러주세요.');
    } catch (error) { for (const cleanup of [...pending]) cleanup(true); throw error; }
  })().catch(error => { terminalLibraries = null; terminalLibraryAttempt = Math.min(1000000,terminalLibraryAttempt+1); throw error; });
  return terminalLibraries;
}
async function ensurePTY() {
  const item = selectedItem; if (!item?.view.pty || document.hidden) return;
  const streaming = supportsPTYStream(item.node);
  if (ptyClient?.sessionKey === item.key && ptyClient.streaming === streaming) return;
  try { await loadTerminalLibraries(); }
  catch (error) {
    if (selectedKey === item.key) { terminalState('error','터미널 로드 실패'); text($('terminal-error'),error.message); show($('terminal-error'),true); show($('terminal-retry'),true); updateTerminalRecovery(); }
    return;
  }
  if (selectedKey !== item.key || document.hidden || ptyClient?.sessionKey === item.key) return;
  stopPTY();
  ptyClient = new AutoApprovePTY($('pty-screen'), {...item.view.pty}, item.node.id, api, uuid, ptyReport, terminalFontSize, streaming, supportsTerminalWire(item.node), tunnelAccess === 'polling');
  ptyClient.sessionKey = item.key;
}
const currentNode = () => nodes.find(node => node.id === selectedItem?.node.id);
// A subscription that has not received its first frame is still independent of
// the inventory read. Retaining it grants no input or connected capability.
const originalReadSelected = () => !!selectedItem && !selectedItem.view.pty && !sessionEnded(selectedItem)
  && terminalStreamFailed !== selectedKey && terminalStream?.key === selectedKey && terminalStream.generation === detailGeneration;
const originalStreamSelected = () => !!selectedItem && !selectedItem.view.pty && !sessionEnded(selectedItem)
  && latestFrame?.sessionID === selectedItem.session.id && terminalStreamFailed !== selectedKey
  && (terminalStream?.key === selectedKey && terminalStream.generation === detailGeneration || inputInFlight);
const originalTerminalConnected = () => !tunnelAuthExpired && (!!currentNode()?.online || originalStreamSelected());
const nowLabel = date => new Date(date).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
const unreadInterruption = session => !!session.interruption && session.interruption.recoveredAt == null && session.interruption.acknowledgedAt == null;
const retainedError = item => item.session.phase === 'ended' && !!item.session.interruption && (!unreadInterruption(item.session) || warningHidden(item,item.session,'interruption'));
const needsReview = session => unreadInterruption(session) || ['approval', 'input'].includes(session.phase) || (session.queuedQuestions || []).some(question => !['sending', 'queued'].includes(question.reply?.phase));
const interruptionReads = new Set();
const interruptionReadKey = item => item.key + '/' + item.session.interruption?.id;
const inputKeys = () => latestFrame?.keys || selectedItem?.view.keys || [];
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
  if(tunnelAccess){show($('web-update'),false);updateTunnelVersion(result);return;}
  const loaded = versionNumbers(loadedWebVersion) ? loadedWebVersion : result.gatewayRelease;
  let gateway = result.preferredGateway;
  if (!gateway && newerVersion(result.gatewayRelease, loaded)) gateway = { id: result.gatewayID, name: '이 Mac', url: location.origin + '/', release: result.gatewayRelease };
  const online = gateway && result.nodes.some(node => node.id === gateway.id && node.online);
  if (!online || !newerVersion(gateway.release, loaded)) { show($('web-update'), false); return; }
  let url;
  try {
    url = new URL(gateway.url);
    const host = url.hostname, parts = host.split('.').map(Number);
    const privateHost = host === 'localhost' || host === 'autoapprove' || parts.length === 4 && parts.every(n => Number.isInteger(n) && n >= 0 && n <= 255) && (parts[0] === 127 || parts[0] === 10 || parts[0] === 192 && parts[1] === 168 || parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31 || parts[0] === 169 && parts[1] === 254);
    if (url.protocol !== 'http:' || !privateHost || url.username || url.password || !['', '/'].includes(url.pathname)) throw new Error('invalid gateway');
    url.search = new URLSearchParams({ webNode: gateway.id }).toString(); url.hash = location.hash;
  } catch (_) { show($('web-update'), false); return; }
  text($('web-update-message'), `${gateway.name} · 웹 ${gateway.release.version} (빌드 ${gateway.release.build}). 새 탭에서 열며 초안은 여기에 남습니다.`);
  $('open-latest-web').href = url.href; show($('web-update'), true);
}
$('open-latest-web').addEventListener('click', () => { const url = new URL($('open-latest-web').href); url.hash = location.hash; $('open-latest-web').href = url.href; });

let versionSyncState = null, versionSyncHost = null, versionSyncBusy = false, versionSyncRead = false, versionSyncCompared = '', versionSyncEpoch = 0;
function renderVersionSync() {
  if (!tunnelAccess || !$('version-sync') || !versionNumbers(versionSyncHost)) return;
  const state = versionSyncState || {}, host = versionSyncHost, client = loadedWebVersion;
  const parts = [`웹 v${client?.version || '미확인'} · 호스트 v${host.version}`];
  if (state.latestVersion) parts.push(`정식 v${state.latestVersion}`);
  const update = state.update, active = ['checking','downloading','waiting','applying'].includes(update?.phase);
  if (active) parts.push(update.detail + (update.progress == null ? '' : ` ${update.progress}%`));
  else if (update?.phase === 'failed') parts.push(update.detail);
  else if (versionSyncBusy) parts.push('정식 최신 버전을 확인하고 있습니다…');
  else if (state.phase === 'failed' || state.error) parts.push(state.error || state.detail);
  else if (newerVersion(host,client)) parts.push('호스트가 더 최신입니다. 새 탭에서 열면 이 페이지의 초안을 유지합니다.');
  else if (newerVersion(client,host)) parts.push('웹이 더 최신입니다. 정식 호스트 업데이트를 확인하세요.');
  else if (state.phase === 'ready') parts.push(state.detail);
  const canSync = state.canSync && !!versionNumbers(client) && newerVersion(state.latest,host) && !newerVersion(client,state.latest);
  if (state.phase === 'ready' && newerVersion(state.latest,host) && !state.canSync) parts.push(state.update?.enabled === false ? 'Mac의 연결 설정에서 자동 업데이트를 켜주세요.' : 'Mac 설치본의 자동 업데이트 지원을 확인해주세요.');
  if (state.phase === 'ready' && newerVersion(client,host) && !canSync) parts.push('웹 버전에 맞는 정식 호스트 파일이 아직 준비되지 않았습니다.');
  if (canSync && !active) parts.push('적용할 때 잠시 재연결하며 PIN으로 다시 로그인할 수 있습니다.');
  text($('version-sync-message'),parts.join(' · ')); show($('version-sync'),true);
  $('check-version').disabled = !connected || tunnelAuthExpired || versionSyncBusy || update?.phase === 'applying';
  text($('check-version'),versionSyncBusy ? '확인 중…' : '최신 버전 확인');
  show($('sync-version'),!!canSync); $('sync-version').disabled = !connected || tunnelAuthExpired || versionSyncBusy || active;
  const latestWeb = newerVersion(host,client); show($('sync-web'),latestWeb);
  if (latestWeb) {
    const url = new URL(location.href);url.searchParams.set('version',`${host.version}-${host.build}`);
    $('sync-web').href = url.href;
  }
}
function updateTunnelVersion(result) {
  if (!$('version-sync')) return;
  versionSyncHost = result.gatewayRelease;
  const gateway = result.nodes.find(n=>n.id===result.gatewayID);
  if (versionSyncState && gateway?.state?.update) versionSyncState.update = gateway.state.update;
  renderVersionSync();
  if (!versionSyncRead) {versionSyncRead=true;void readVersionSync();}
  const key = `${loadedWebVersion?.version}:${loadedWebVersion?.build}/${versionSyncHost?.version}:${versionSyncHost?.build}`;
  if (newerVersion(loadedWebVersion,versionSyncHost) && key !== versionSyncCompared) {
    versionSyncCompared=key;void checkVersionSync();
  }
}
async function readVersionSync() {
  const epoch=versionSyncEpoch;
  try {
    const state = await api('/api/version',undefined,undefined,10000);
    if (versionSyncBusy || versionSyncEpoch!==epoch) return;
    versionSyncState=state;if(versionNumbers(state.host))versionSyncHost=state.host;renderVersionSync();
  } catch (_) { /* Older hosts remain usable; an explicit check explains support. */ }
}
async function checkVersionSync(sync=false) {
  if(versionSyncBusy || !tunnelAccess || !connected || tunnelAuthExpired)return;
  versionSyncEpoch++;
  versionSyncBusy=true;renderVersionSync();
  try {
    const state=await api(sync?'/api/version/sync':'/api/version/check',{client:loadedWebVersion},undefined,25000);
    versionSyncState=state;if(versionNumbers(state.host))versionSyncHost=state.host;
  } catch(error) {
    versionSyncState={...(versionSyncState||{}),error:error.status===404?'이 호스트는 웹 버전 맞추기를 지원하지 않습니다. Mac에 최신 버전을 한 번 설치해주세요.':error.message};
  } finally {versionSyncBusy=false;renderVersionSync();}
}
$('check-version')?.addEventListener('click',()=>void checkVersionSync());
$('sync-version')?.addEventListener('click',()=>void checkVersionSync(true));

function updateViewport() {
  const viewport = window.visualViewport;
  document.body.classList.toggle('terminal-compact', (viewport?.height || innerHeight) <= 400);
  document.documentElement.style.setProperty('--terminal-viewport-height', `${viewport?.height || innerHeight}px`);
  document.documentElement.style.setProperty('--terminal-viewport-top', `${viewport?.offsetTop || 0}px`);
  positionTerminalSettings();
}
function positionTerminalSettings() {
  const settings = $('terminal-settings');
  if (!settings.open) return;
  // Measure only an open menu on toggle/viewport/outer-scroll events. Keep it
  // inside both the visible viewport and the workspace's clipping boundary.
  const bounds = settings.getBoundingClientRect(), detail = $('detail').getBoundingClientRect(), viewport = window.visualViewport;
  const top = Math.max(viewport?.offsetTop || 0,detail.top);
  const bottom = Math.min((viewport?.offsetTop || 0) + (viewport?.height || innerHeight),detail.bottom);
  const below = Math.max(0,bottom - bounds.bottom - 12), above = Math.max(0,bounds.top - top - 12);
  const upward = below < 200 && above > below;
  settings.dataset.placement = upward ? 'above' : 'below';
  settings.style.setProperty('--terminal-settings-height',`${Math.max(88,Math.min(600,upward ? above : below))}px`);
}
function terminalFocus(enabled) {
  document.body.classList.toggle('terminal-focus', enabled);
  $('terminal-focus').setAttribute('aria-pressed', String(enabled));
  text($('terminal-focus'), enabled ? '상세 보기' : '크게 보기');
  text($('terminal-heading'), enabled && selectedItem ? selectedItem.view.title : '터미널 화면');
  $('terminal-heading').title = selectedItem?.view.title || '';
  $('terminal-settings').open = false;
  updateViewport();
  if (enabled) stopSessionHistory(); else renderHistory();
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
  cursorLayoutFrame = requestAnimationFrame(layoutCursor); cursorLayoutTimer = setTimeout(layoutCursor, 100);
}
function layoutCursor() {
  if (!cursorLayoutPending) return;
  cursorLayoutPending = false; cancelAnimationFrame(cursorLayoutFrame); clearTimeout(cursorLayoutTimer);
  cursorLayoutFrame = null; cursorLayoutTimer = null;
  positionCursor();
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
  if ($('follow').checked && cursor.visible && !selecting) {
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
  show(caret, cursor.visible === true && inView && !composing && !!latestFrame && originalTerminalConnected());
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
  clearTimeout(directTimer); directTimer = null; directTimerDue = Infinity; inputGeneration++;
  clearTimeout(directChannelRetry); directChannelRetry = null; directChannelRetries = 0;
  if (directChannel || directCandidate) { directChannel?.close(); directCandidate?.close(); directSending = false; }
  directChannel = directCandidate = null; directChannelState = 'idle'; directChannelStreamID = null; directFreshening = false; inputQuality(null);
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
  void prepareDirectChannel();
}
async function prepareDirectChannel() {
  if (directChannelState !== 'idle' || directSending || mutation || inputFailure || !window.AutoApproveInputChannel || !latestFrame?.streamID || !selectedItem || selectedItem.view.pty || composeMode || !terminalFrameFresh() || !inputKeys().includes('characters')) return;
  directChannelState = 'opening'; const generation = inputGeneration, key = selectedKey, streamID = latestFrame.streamID; directChannelStreamID = streamID;
  const candidate = new window.AutoApproveInputChannel(selectedItem.node.id,{mode:'native',sessionID:selectedItem.session.id,streamID,revision:latestFrame.revision},{
    onChange:() => {
      if (generation !== inputGeneration || directChannel !== candidate) return;
      directSending = candidate.pendingCount > 0; updateControls();
      if (directMode && directQueue.length) scheduleDirect(0);
    },
    onFailure:error => {
      if (generation !== inputGeneration || directChannel !== candidate) return;
      if (error.recoverable && !candidate.pendingCount) { recoverDirectChannel(); return; }
      stopDirect(); inputFailure = error.message; terminalState('error','입력 연결 확인 필요'); feedback(error.message,true); updateControls();
    },
    onQuality:value => { if (generation === inputGeneration && selectedKey === key) inputQuality(value); }
  });
  directCandidate = candidate;
  try {
    const channel = await candidate.open();
    if (generation !== inputGeneration || selectedKey !== key || latestFrame?.streamID !== streamID) { channel?.close(); return; }
    directChannel = channel; directCandidate = null; directChannelState = channel ? 'ready':'fallback';
    if (channel) directChannelStableAt = performance.now();
    if (directMode && directQueue.length) scheduleDirect(0);
  } catch (error) {
    if (generation === inputGeneration && selectedKey === key) { stopDirect(); inputFailure = error.message; feedback(error.message,true); updateControls(); }
  }
}
function recoverDirectChannel() {
  if (performance.now()-directChannelStableAt > 30000) directChannelRetries = 0;
  directChannelRetries++; directChannel = null; directChannelState = 'reconnecting'; directSending = false; inputQuality(null); updateControls();
  if (directChannelRetries > 3) { directChannelState = 'fallback'; if (directMode && directQueue.length) scheduleDirect(0); return; }
  const generation = inputGeneration, key = selectedKey;
  directChannelRetry = setTimeout(async () => {
    if (generation !== inputGeneration) return;
    const fresh = await freshInputFrame(key); if (generation !== inputGeneration) return;
    if (!fresh) { stopDirect(); updateControls(); return; }
    directChannelState = 'idle'; void prepareDirectChannel();
  },Math.min(2000,250*2**(directChannelRetries-1)));
}
function focusKeyboard() {
  if (composeMode) { if (!$('terminal-input').disabled) $('terminal-input').focus({ preventScroll: true }); return; }
  if ($('terminal-keyboard').disabled) return;
  if (document.activeElement === $('terminal-keyboard')) return;
  armDirect(); inputFailure = ''; captureDirectText();
  if (composePreferred) { updateControls(); return; }
  $('terminal-keyboard').focus({ preventScroll: true }); updateControls();
}

async function api(path, body, signal, timeoutMS = 20000, validation) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) controller.abort();
  const timeout = setTimeout(() => controller.abort(), timeoutMS);
  try {
    const headers = body ? {'Content-Type':'application/json'} : validation?.etag ? {'If-None-Match':validation.etag,...(validation.wait ? {Prefer:'wait=15'} : {})} : {};
    if (validation?.expectedNodeID) headers['X-AutoApprove-Node'] = validation.expectedNodeID;
    const response = await fetch(path, { method: body ? 'POST' : 'GET', headers, body: body ? JSON.stringify(body) : undefined, signal: controller.signal, cache: 'no-store', credentials: tunnelAccess ? 'same-origin' : 'omit' });
    if(response.status === 401 && tunnelAccess){
      tunnelAuthExpired=true;
      renderVersionSync();
      stopDirect();
      stopScreenControl();
      if(ptyClient && !ptyClient.blocked)ptyClient.fail(new Error('접속 시간이 끝났습니다. PIN 또는 접속 키로 다시 연결해주세요.'));
      text($('tunnel-access-state'),'접속 시간이 끝났습니다. 미전달 입력을 확인하고 다시 연결해주세요.');show($('tunnel-relogin'),true);
    }
    if (validation) validation.waitApplied = response.headers.get('Preference-Applied') === 'wait';
    if (validation) validation.notModified = false;
    if (response.status === 304) {
      if (!validation?.value || !validation.etag || response.headers.get('ETag') !== validation.etag) {
        if (validation) { validation.etag = ''; validation.value = null; }
        throw new Error('목록 갱신 응답을 확인하지 못했습니다. 상태를 새로고침해주세요.');
      }
      validation.notModified = true;
      validation.observedAt = response.headers.get('X-AutoApprove-Observed-At') || new Date().toISOString();
      return validation.value;
    }
    const result = await response.json().catch(error=>{
      if(!response.ok)return {error:response.status>=500?'Mac과 연결하지 못했습니다. 연결 상태를 확인한 뒤 다시 시도해주세요.':'요청을 처리하지 못했습니다. 다시 로그인하거나 연결 상태를 확인해주세요.'};
      throw error;
    });
    if (!response.ok) throw Object.assign(new Error(result.error || '요청을 처리하지 못했습니다. 상태를 새로고침해주세요.'), {status: response.status, failureKind:result.diagnostics?.failureKind, unsent:result.diagnostics?.delivery === 'not_started', delivery:result.diagnostics?.delivery});
    if (validation) {
      const tag = response.headers.get('ETag') || '';
      validation.etag = /^(?:W\/)?"[^"\r\n]{1,128}"$/.test(tag) ? tag : '';
      validation.value = result; validation.observedAt = result.updatedAt;
    }
    return result;
  } catch (error) {
    if (error.name === 'AbortError') {
      if (signal?.aborted) throw error;
      throw Object.assign(new Error('연결 응답이 늦습니다. 입력을 다시 보내기 전에 터미널 화면을 확인해주세요.'), {retryable: !body});
    }
    if (error instanceof TypeError) throw Object.assign(new Error(tunnelAccess ? '외부 연결이 끊겼습니다. 인터넷 연결과 Mac의 터널 설정을 확인해주세요.' : 'Mac과의 연결이 끊겼습니다. 같은 핫스팟과 Mac의 웹 접속 설정을 확인해주세요.'), {retryable: !body});
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
  pre.scrollTop = $('follow').checked && !selecting && latestFrame?.cursor?.visible !== true ? pre.scrollHeight : scrollTop; pre.scrollLeft = scrollLeft;
  return true;
}
function feedback(message, error = false) {
  clearTimeout(feedbackTimer); text($('feedback'), message); $('feedback').dataset.error = String(error); show($('feedback'), true);
  feedbackTimer = setTimeout(() => show($('feedback'), false), error ? 14000 : 5500);
}
function endpoint(path, nodeID, sessionID) {
  const url = new URL(path, location.href);
  url.searchParams.set('node', nodeID);
  if (sessionID) url.searchParams.set('session', sessionID);
  return url.pathname + url.search;
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
async function resetSelectedAutomation() {
  const item = selectedItem, key = selectedKey;
  if (!item || automationResets.has(key) || automationResetNodes.has(item.node.id) || !connected || !currentNode()?.online || sessionEnded(item) ||
      ptyTemporary.has(key) || !supportsRelease(item.node,[0,2,159,186])) return;
  automationResets.add(key); automationResetResult = null;
  // Park unsubmitted keystrokes in the existing draft. A reset never replays
  // them, sends a cancel key, or erases an uncertain manual submission.
  stopDirect(); clearTerminalWarm(); updateControls(); renderMachines();
  try {
    const result = await api(endpoint('/api/action',item.node.id),{action:'resetAutomation',sessionID:item.session.id,requestID:uuid()});
    const message = result.message || '자동화를 초기화했습니다. 현재 상태부터 다시 감지합니다.';
    automationResetResult = {key,message,error:false};
    feedback(message);
    if (selectedKey === key) {
      detailGeneration++; frameController?.abort();
      latestFrame = null; terminalFrameReceivedAt = -Infinity;
      stopTerminalStream(true); void refreshFrame();
    }
    await refreshNetwork();
  } catch (error) {
    automationResetResult = {key,message:error.message,error:true}; feedback(error.message,true);
  } finally { automationResets.delete(key); updateControls(); renderMachines(); }
}
function updateAllAutomationResetControls() {
  const online = nodes.filter(node=>node.online), old = online.filter(node=>!supportsRelease(node,[0,2,161,188]));
  const busy = automationResetNodes.size > 0;
  $('reset-all-automation').disabled = !connected || !online.length || old.length > 0 || busy || automationResets.size > 0 || mutation;
  text($('reset-all-automation'),busy ? '모든 자동화 초기화 중…' : '연결된 Mac 모두 초기화');
  setBusy($('reset-all-automation'),busy);
  text($('reset-all-automation-help'),old.length ? `Mac ${old.length}대를 0.2.161 이상으로 업데이트하면 함께 초기화할 수 있습니다.` : !connected ? '연결을 확인한 뒤 다시 시도해주세요.' : !online.length ? 'Mac이 연결되면 모든 세션의 자동화를 초기화할 수 있습니다.' : `연결된 Mac ${online.length}대의 모든 세션을 초기화합니다. 원본 터미널·초안·일시정지는 유지합니다.${nodes.some(node=>!node.online) ? ' 연결이 끊긴 Mac은 다시 연결한 뒤 초기화해주세요.' : ''}`);
  text($('reset-all-automation-result'),allAutomationResetResult?.message || '');
  $('reset-all-automation-result').className = allAutomationResetResult?.error ? 'error-text small' : 'muted small';
  show($('reset-all-automation-result'),!!allAutomationResetResult);
}
async function resetAllAutomations(nodeID = null) {
  if (!connected || mutation || automationResetNodes.size || automationResets.size) return;
  const targets = nodes.filter(node=>node.online && (nodeID === null || node.id === nodeID));
  if (!targets.length || targets.some(node=>!supportsRelease(node,[0,2,161,188]))) return;
  const ids = new Set(targets.map(node=>node.id));
  for (const id of ids) { automationResetNodes.add(id); automationResetNodeErrors.delete(id); }
  allAutomationResetResult = {message:`Mac ${targets.length}대의 자동화 대기를 비우고 있습니다…`,error:false};
  if (selectedItem && ids.has(selectedItem.node.id)) { stopDirect(); clearTerminalWarm(); automationResetResult=null; }
  updateControls(); renderMachines();
  const results = await Promise.allSettled(targets.map(node=>api(endpoint('/api/action',node.id),{action:'resetAllAutomation',requestID:uuid()})));
  let completed = 0, failed = 0;
  for (let index=0;index<results.length;index++) {
    const result=results[index],node=targets[index];
    automationResetNodes.delete(node.id);
    if (result.status === 'fulfilled') completed++;
    else { failed++; automationResetNodeErrors.set(node.id,result.reason?.message || '초기화 결과를 확인하지 못했습니다. 연결을 확인한 뒤 다시 시도해주세요.'); }
  }
  const message = failed ? `Mac ${completed}대 완료 · ${failed}대 실패. 실패한 Mac의 ‘모든 세션 초기화’로 다시 시도해주세요.` : `Mac ${completed}대의 모든 자동화를 초기화했습니다. 각 세션의 현재 상태부터 다시 감지합니다.`;
  allAutomationResetResult = {message,error:failed>0}; feedback(message,failed>0);
  if (selectedItem && ids.has(selectedItem.node.id)) {
    detailGeneration++; frameController?.abort(); latestFrame=null; terminalFrameReceivedAt=-Infinity;
    stopTerminalStream(true); void refreshFrame();
  }
  updateControls(); renderMachines();
  await refreshNetwork();
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
    const result = await api(endpoint('/api/action', nodeID), {...payload, requestID:uuid()});
    state.sent = true; state.finishedAt = performance.now(); state.message = result.message || message; state.error = ''; void refreshNetwork();
    if (selectedItem?.session.agent === 'codex' && $('interaction-dialog').open) void refreshCodexQueue();
    return true;
  } catch (error) {
    state.error = error.message; state.uncertain = error.delivery === 'unknown' || !error.status || error.status >= 500; state.failedAt = performance.now();
    if (state.uncertain) state.error += ' 전달 여부를 확인한 뒤 진행해주세요. 작성한 답변은 보관합니다.';
    if (!Array.from($('questions').querySelectorAll('form')).some(form=>form.dataset.questionKey===key)) feedback(error.message,true);
    void refreshNetwork(); return false;
  } finally { state.busy = false; updateInteractionControls(); }
}

async function readNetworkInventory(path, initial, waiting, signal) {
  const established = !initial && connected && !!networkGatewayID;
  const budget = waiting ? 20000 : 10000, deadline = performance.now() + budget;
  const read = async (wait, fresh, timeout) => {
    // A failed/misdirected response cannot replace the last verified validator.
    const validation = {...(fresh ? {etag:'',value:null} : networkValidation),wait,expectedNodeID:networkGatewayID};
    const result = await api(path,undefined,signal,timeout,validation);
    if (signal.aborted) throw new DOMException('Aborted','AbortError');
    if (typeof result?.gatewayID !== 'string' || !result.gatewayID || result.gatewayID.length > 256 || /[\u0000-\u0020\u007f]/.test(result.gatewayID) || !Array.isArray(result.nodes)) {
      throw Object.assign(new Error('Mac의 목록 응답을 확인하지 못했습니다. 상태를 새로고침해주세요.'),{failureKind:'protocol'});
    }
    if (networkGatewayID && result.gatewayID !== networkGatewayID) {
      throw Object.assign(new Error('접속 주소의 Mac이 변경되었습니다. 주소를 확인한 뒤 페이지를 다시 열어주세요.'),{status:409,failureKind:'identity'});
    }
    networkGatewayID = result.gatewayID;
    if (!initial) Object.assign(networkValidation,validation);
    return result;
  };
  try { return await read(waiting,initial,established ? budget-2000 : budget); }
  catch (error) {
    const remaining = Math.min(2000,deadline-performance.now());
    if (!established || signal.aborted || remaining <= 0 || ['identity','protocol'].includes(error.failureKind)
      || !(error.retryable === true || [502,503,504].includes(error.status))) throw error;
    // One fresh GET confirms connectivity before changing the whole dashboard
    // to offline. No input replay, stale-success fallback or extra healthy poll.
    return await read(false,true,remaining);
  }
}

async function refreshNetwork(initial = false, restart = false) {
  clearTimeout(networkTimer);
  if (document.hidden) return;
  if (loadingNetwork) {
    // Connectivity/foreground notifications supersede the old network path.
    // Let its finally block release ownership before starting one fresh GET.
    if (restart) { networkRefreshRequested = true; networkController?.abort(); }
    return;
  }
  // Recover with the small local inventory before waiting for other Macs.
  initial ||= !connected;
  const waiting = !initial && !restart && !partialNetwork && gatewayNetworkWaitVersion === 1 && !!networkValidation.etag;
  loadingNetwork = true; $('refresh').disabled = !waiting; $('refresh').setAttribute('aria-busy', String(!waiting));
  const controller = new AbortController(); networkController = controller;
  const startedAt = performance.now();
  try {
    const selectedNode = new URLSearchParams(location.hash.slice(1)).get('node');
    const result = await readNetworkInventory(initial ? '/api/network?'+new URLSearchParams({initial:'1',...(selectedNode ? {node:selectedNode} : {})}) : '/api/network', initial, waiting, controller.signal);
    if (controller.signal.aborted || document.hidden) return;
    if (!initial && networkValidation.notModified && connected && appliedNetworkETag === networkValidation.etag) {
      // Still observe liveness/history and recover streams, without replacing
      // inventory objects or invalidating the list, selected form and keyboard.
      lastNetworkStartedAt = startedAt; lastNetworkUpdate = networkValidation.observedAt;
      text($('connection'), `${nodes.filter(node => node.online).length}대 연결 · ${nowLabel(lastNetworkUpdate)} 갱신`);
      if (selectedItem) {
        renderHistory();
        if (!selectedItem.view.pty && (terminalStream || supportsTerminalStream(selectedItem.node))) void refreshFrame();
      }
      networkFailures = 0;
      return;
    }
    partialNetwork = result.partial === true;
    gatewayTerminalWireVersion = [2,3].includes(result.terminalWireVersion) ? result.terminalWireVersion : null;
    gatewayNetworkWaitVersion = result.networkWaitVersion === 1 ? 1 : null;
    if (!partialNetwork) partialNetworkRefreshes = 0;
    connected = true;
    const previousNodes = new Map(nodes.map(node => [node.id,node]));
    // Include hidden records so cleanup/restore during a retry keeps the same
    // placement. Only an actual online response restores an offline card.
    updateMacPlacement(result.nodes);
    // A pending or failed inventory read is not an authoritative empty list.
    // Keep its last presentation; the current node still controls connectivity.
    const reconnected = result.nodes.filter(node=>node.online && cleanup.macs.has(node.id));
    if (reconnected.length) {
      for (const node of reconnected) cleanup.macs.delete(node.id);
      // Reconnection always restores the real Mac, even if browser persistence is unavailable.
      try { localStorage.setItem(cleanupStorage,JSON.stringify(Object.fromEntries(Object.entries(cleanup).map(([kind,values])=>[kind,[...values]])))); } catch (_) {}
    }
    nodes = result.nodes.filter(node=>node.online || !cleanup.macs.has(node.id)).map(node => !node.online && !node.state && previousNodes.get(node.id)?.state
      ? {...node,state:previousNodes.get(node.id).state} : node);
    lastNetworkStartedAt = startedAt;
    // Peer completion order can change on each progressive response. Preserve
    // existing Mac groups, while respecting each Mac's current session order.
    // These IDs live only in the current inventory, not a second history cache.
    const inventoryNodes = new Map(nodes.map(node=>[node.id,node]));
    const nodeOrder = new Set([...allSessions.map(item=>item.node.id),...inventoryNodes.keys()]);
    const inventory = Array.from(nodeOrder).flatMap(id => {
      const node = inventoryNodes.get(id);
      return (node?.state?.sessions || []).map(view => ({node,view,session:view.session,key:keyFor(node,view.session,view)}));
    });
    const continuation = inventory.find(item => item.key === selectedKey)?.session.interruption?.resumedSessionID;
    const recovered = continuation && inventory.find(item => item.node.id === selectedItem?.node.id && item.session.id === continuation && !sessionEnded(item));
    const inventoryKeys = new Set(inventory.map(item=>item.key));
    for (const item of allSessions) {
      const node = nodes.find(node => node.id === item.node.id && !node.online);
      if (node && !inventoryKeys.has(item.key) && item.session.interruption?.recoveredAt == null && item.session.interruption) {
        inventory.push({...item,node:{...item.node,...node,state:item.node.state}});
        inventoryKeys.add(item.key);
      }
    }
    reconcileInterruptionReceipts(inventory);
    allSessions = reconcilePTYInventory(inventory);
    const unavailable = nodes.find(node => node.id === selectedItem?.node.id && !node.online);
    // A peer's inventory can time out before its first independent terminal
    // frame arrives. Keep that selected read; online session removal is final.
    if (unavailable && (originalReadSelected() || originalStreamSelected()) && !allSessions.some(item => item.key === selectedKey)) {
      allSessions.push({...selectedItem, node:{...selectedItem.node, ...unavailable, state:selectedItem.node.state}});
    }
    appliedNetworkETag = initial ? '' : networkValidation.etag;
    lastNetworkUpdate = !initial && networkValidation.notModified ? networkValidation.observedAt : result.updatedAt;
    text($('connection'), `${nodes.filter(node => node.online).length}대 연결 · ${nowLabel(lastNetworkUpdate)} 갱신`);
    show($('network-error'), false);
    text($('discovery'), result.discovery || ''); show($('discovery'), !!result.discovery);
    updateWebVersion(result);
    renderMachines(); renderNodeFilter(); renderList();
    if (recovered) selectSession(recovered.key, true);
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
      else if (selectedItem) {
        const ended = !!currentNode()?.online;
        show($('session-ended'), true);
        text($('session-ended'), ended ? '이 Mac에서 원본 세션이 종료되었거나 목록에서 제거됐습니다. 다른 세션을 선택해주세요.' : '원본 Mac 연결을 확인하지 못했습니다. 연결되면 같은 세션을 다시 확인합니다.');
        if (ended) { text($('session-phase'),'종료'); $('session-phase').dataset.phase='ended'; }
        latestFrame = null; frameController?.abort(); stopTerminalStream(); stopDirect(); stopPTY();
        terminalState('error', ended ? '세션 종료' : '연결 끊김'); updateControls();
      }
      else restoreSelection();
    } else restoreSelection();
    renderInteractions();
    networkFailures = 0;
  } catch (error) {
    if (controller.signal.aborted) return;
    networkFailures = Math.min(5,networkFailures+1);
    partialNetwork = false; partialNetworkRefreshes = 0;
    connected = false; text($('connection'), lastNetworkUpdate ? `연결 끊김 · 마지막 갱신 ${nowLabel(lastNetworkUpdate)}` : '연결 끊김 · 다시 연결 중');
    renderVersionSync();
    show($('web-update'), false);
    text($('network-error'), error.message); show($('network-error'), true);
    if (!nodes.length) text($('list-empty'), 'Mac에 연결하면 감지된 세션이 여기에 표시됩니다.');
    // Inventory and terminal connections are independent. A failed list request
    // cannot invalidate a verified original stream or close its mobile keyboard.
    if (!selectedItem?.view.pty && !terminalStream && !latestFrame) terminalState('pending', '다시 연결 중…');
    updateControls(); renderMachines(); renderList();
  } finally {
    if (networkController === controller) networkController = null;
    loadingNetwork = false; $('refresh').disabled = false; $('refresh').removeAttribute('aria-busy');
    const requested = networkRefreshRequested; networkRefreshRequested = false;
    if (!document.hidden) {
      const nextWait = gatewayNetworkWaitVersion === 1 && !!networkValidation.etag && !partialNetwork && (!waiting || networkValidation.waitApplied);
      let delay = requested || controller.signal.aborted || initial && connected ? 0 : connected ? nextWait ? 100 : 2500 : Math.min(5000,500*2**Math.max(0,networkFailures-1));
      // Complete a progressive inventory promptly, without leaving an offline
      // neighbour on a permanent fast poll. 304 retains the same bounded count.
      if (delay > 0 && connected && partialNetwork && partialNetworkRefreshes < 4) delay = 150 * 2 ** partialNetworkRefreshes++;
      networkTimer = setTimeout(() => void refreshNetwork(false,requested), delay);
    }
  }
}
function renderMachines() {
  updateAllAutomationResetControls();
  const live = new Set(nodes.map(node=>node.id));
  for (const id of automationResetNodeErrors.keys()) if (!live.has(id)) automationResetNodeErrors.delete(id);
  const offline = offlineMacs(), removable = new Set(offline.map(node=>node.id));
  const folded = nodes.filter(node=>removable.has(node.id) || unconfirmedMac(node));
  show($('offline-machines'),folded.length>0);text($('offline-machine-count'),`이전 연결 · Mac ${folded.length}대`);
  const removedFocus = [...machineRows].some(([id,row])=>!live.has(id) && row.contains(document.activeElement));
  for (const [id,row] of machineRows) if (!live.has(id)) { row.remove(); machineRows.delete(id); }
  if (nodes.length && $('machines').querySelector('.empty-inline')) $('machines').replaceChildren();
  text($('mac-count'), `${connected ? nodes.filter(node => node.online).length : 0}대`);
  for (const node of nodes) {
    let row = machineRows.get(node.id);
    if (!row) {
      row = make('article', 'machine'); const info = make('div', 'machine-info');
      const resetResult=make('p','error-text small machine-reset-result');resetResult.setAttribute('role','status');resetResult.hidden=true;
      info.append(make('p', 'machine-name'), make('p', 'machine-version'), make('p', 'machine-status'),resetResult);
      const actions = make('div','machine-actions'), toggle = make('button','secondary machine-toggle'), reset=make('button','secondary machine-reset','모든 세션 초기화'), clean = make('button','secondary machine-clean','목록에서 정리'), accounts=make('button','secondary machine-accounts','AI 계정');
      toggle.type = reset.type = clean.type = accounts.type = 'button'; actions.append(accounts,toggle,reset,clean); row.append(info,actions);
      accounts.addEventListener('click',()=>void openAgentAccounts(node.id));
      reset.addEventListener('click',()=>void resetAllAutomations(node.id));
      clean.addEventListener('click',()=>cleanOfflineMacs([node.id]));
      toggle.addEventListener('click', () => {
        const current = nodes.find(item => item.id === node.id);
        if (current?.online) void action(node.id, { action: 'pause', paused: !current.state.snapshot.paused }, current.state.snapshot.paused ? '이 Mac의 자동 승인을 재개했습니다.' : '이 Mac의 자동 승인을 일시정지했습니다.');
      });
      machineRows.set(node.id, row); $('machines').append(row);
    }
    text(row.querySelector('.machine-name'), node.name + (node.local ? ' · 접속한 Mac' : ''));
    text(row.querySelector('.machine-version'), machineVersionLabel(node));
    const status = row.querySelector('.machine-status');
    status.className = 'machine-status ' + (!node.online || !connected ? '' : node.state.snapshot.paused ? 'paused' : 'online');
    const activeCount = node.state?.sessions?.filter(view => !sessionEnded({session:view.session, view}) && !sessionEnded(ptyRetained.get(keyFor(node, view.session, view)))).length || 0;
    text(status, !connected ? '연결 확인 필요' : node.loading && !displayedOfflineMac(node) ? node.state ? `${activeCount}개 세션 · 갱신 중…` : '세션 확인 중…' : !node.online ? '연결 끊김 · 웹 접속과 네트워크 확인' : `${activeCount}개 세션 · ${node.state.snapshot.paused ? '자동 승인 일시정지' : '연결됨'}`);
    setBusy(row,node.loading);
    status.title = node.error || '';
    const button = row.querySelector('.machine-toggle'); text(button, node.online && node.state.snapshot.paused ? '재개' : '일시정지');
    button.disabled = mutation || !connected || !node.online;
    const accounts=row.querySelector('.machine-accounts');accounts.disabled=!connected||!node.online;accounts.setAttribute('aria-label',`${node.name} AI 계정 로그인`);show(accounts,node.online);
    button.setAttribute('aria-label', `${node.name} 자동 승인 ${node.online && node.state.snapshot.paused ? '재개' : '일시정지'}`);
    button.title = !node.online ? 'Mac의 웹 접속이 다시 연결되면 사용할 수 있습니다.' : '이 Mac의 자동 승인만 변경합니다. 터미널 작업은 계속됩니다.';
    const reset = row.querySelector('.machine-reset'), resetBusy=automationResetNodes.has(node.id), resetSupported=supportsRelease(node,[0,2,161,188]);
    text(reset,resetBusy ? '모든 자동화 초기화 중…' : '모든 세션 초기화');setBusy(reset,resetBusy);
    reset.disabled = !connected || !node.online || !resetSupported || mutation || automationResetNodes.size>0 || automationResets.size>0;
    reset.setAttribute('aria-label',`${node.name}의 모든 세션 자동화 초기화·재실행`);
    reset.title = !resetSupported ? '이 Mac을 AutoApprove 0.2.161 이상으로 업데이트해주세요.' : '이 Mac의 모든 세션에 쌓인 자동화 대기를 비우고 다시 감지합니다. 원본 터미널과 설정은 유지합니다.';
    const resetError=row.querySelector('.machine-reset-result');text(resetError,automationResetNodeErrors.get(node.id)||'');show(resetError,automationResetNodeErrors.has(node.id));
    const target = removable.has(node.id) || unconfirmedMac(node) ? $('offline-machine-list') : $('machines');
    if(row.parentElement!==target) {
      const hadFocus=row.contains(document.activeElement);target.append(row);
      if(hadFocus && target.id==='offline-machine-list' && !$('offline-machines').open)$('offline-machine-count').focus({preventScroll:true});
    }
    const clean = row.querySelector('.machine-clean'), canClean = removable.has(node.id);
    show(button,!canClean); show(clean,canClean); clean.disabled = !connected;
    clean.setAttribute('aria-label',`${node.name} 연결 끊긴 Mac 목록에서 정리`);
  }
  renderInterruptions();
  renderSystemSafety();
  updateCleanupControls();
  if(removedFocus && document.activeElement===document.body)$('list-cleanup').querySelector('summary').focus({preventScroll:true});
}
function systemSafetyTitle(risk) {
  return {persistence:'시스템 자동 실행 변경',security:'보안·접근 권한 변경',settings:'시스템 설정·파일 변경',privileged:'관리자 권한 실행'}[risk?.kind] || '시스템 변경';
}
function systemSafetyStatus(source, node) {
  const notice = source.systemSafety;
  if (notice.phase === 'detected') return node.state?.snapshot.paused ? '전체 일시정지 중 · 시스템 변경을 자동 승인하지 않습니다.' : !source.automatic ? '자동 승인 꺼짐 · 켜면 시스템 변경을 거절하고 안전한 대안을 안내합니다.' : notice.message;
  return notice.message;
}
function renderSystemSafety() {
  const active = allSessions.flatMap(item => [item.session,...(item.session.backgroundSessions || [])].filter(source =>
    source.systemSafety && !warningHidden(item,source,'safety') && (source.notices || []).some(notice => notice.isSystemSafety && !notice.isRead)
  ).map(source => ({item,source,key:item.key+'/'+source.id+'/'+source.systemSafety.id})));
  const keys = new Set(active.map(value => value.key));
  for (const [key,row] of safetyRows) if (!keys.has(key)) { row.remove(); safetyRows.delete(key); }
  show($('system-safety'),active.length > 0);
  text($('system-safety-title'),`시스템 변경 경고 · ${active.length}개 세션`);
  for (const {item,source,key} of active) {
    let row = safetyRows.get(key);
    if (!row) {
      row = make('article','interruption-row'); const info = make('div');
      info.append(make('p','interruption-name'),make('p','small interruption-state'));
      const actions = make('div','interruption-actions'), button = make('button','secondary safety-view','세션 보기'), clean = make('button','secondary','경고 표시 정리'); button.type = clean.type = 'button';
      button.addEventListener('click',()=>selectSession(item.key,true)); clean.addEventListener('click',()=>cleanWarnings([warningKey(item,source,'safety')])); actions.append(button,clean); row.append(info,actions);
      safetyRows.set(key,row); $('system-safety-list').append(row);
    }
    text(row.querySelector('.interruption-name'),`${item.node.name} · ${item.view.title} · ${systemSafetyTitle(source.systemSafety.risk)}`);
    text(row.querySelector('.interruption-state'),systemSafetyStatus(source,item.node) + (displayedOfflineMac(item.node) ? ' · Mac 연결 끊김' : ''));
    setBusy(row,item.node.loading);
    row.querySelector('.safety-view').setAttribute('aria-label',`${item.node.name}의 ${item.view.title} 시스템 변경 경고 보기`);
  }
}
function renderSessionSafety() {
  const {session,node} = selectedItem, container = $('session-safety');
  const sources = [session,...(session.backgroundSessions || [])].filter(source => source.systemSafety && !warningHidden(selectedItem,source,'safety'));
  const keys = new Set(sources.map(source=>source.id));
  for (const article of container.children) if (!keys.has(article.dataset.source)) article.remove();
  show(container,sources.length > 0);
  for (const source of sources) {
    const notice = source.systemSafety;
    let article = Array.from(container.children).find(value=>value.dataset.source === source.id);
    if (!article) {
      article = make('article'); article.dataset.source = source.id;
      article.append(make('h3'),make('p','safety-status'));
      article.querySelector('p').setAttribute('role','status');
      const details = make('details'); details.append(make('summary','','요청과 안전한 대안'),make('pre','safety-request'),make('p','safety-alternative'));
      const clean = make('button','secondary','경고 표시 정리'); clean.type = 'button';
      clean.addEventListener('click',()=>cleanWarnings([article.dataset.warningKey]));
      article.append(details,clean);container.append(article);
    }
    text(article.querySelector('h3'),systemSafetyTitle(notice.risk) + (source.id !== session.id ? ' · 백그라운드 실행' : ''));
    article.dataset.warningKey = warningKey(selectedItem,source,'safety');
    text(article.querySelector('.safety-status'),systemSafetyStatus(source,node));
    text(article.querySelector('.safety-request'),notice.request);
    text(article.querySelector('.safety-alternative'),'이미 실행 중인 프로그램의 타이머나 프로젝트 내부 작업으로 계속합니다. 시스템 자동 실행 등록·관리자 권한 상승·보안 설정 변경이나 우회는 하지 않습니다.');
  }
}
function interruptionStatus(session) {
  if (session.phase === 'ended') return (session.capacityResume?.phase === 'paused' ? '자동 복구 일시정지 · ' : '') + (session.interruption?.recoveryDetail || 'CLI 종료 · Mac에서 원본 대화 확인 필요');
  const recovery = session.capacityResume;
  if (!recovery) return session.automatic ? '원본 연결 확인 필요' : '자동 승인 꺼짐 · 직접 이어가기';
  const states = {scheduled:'자동 이어가기 대기',sending:'이어서 진행 요청 중…',awaiting:'작업 재개 확인 중…',paused:'자동 이어가기 일시정지',unavailable:'원본 입력 연결 필요',review:'입력 확인 필요',exhausted:'자동 이어가기 확인 필요',cancelled:'자동 이어가기 취소됨'};
  return `${states[recovery.phase] || '복구 상태 확인 중'}${recovery.deadline ? ` · ${nowLabel(recovery.deadline)} 다시 시도` : ''}`;
}
function renderInterruptions() {
  const active = allSessions.filter(item => unreadInterruption(item.session) && !warningHidden(item,item.session,'interruption'));
  const keys = new Set(active.map(item => item.key));
  for (const [key,row] of interruptionRows) if (!keys.has(key)) { row.remove(); interruptionRows.delete(key); }
  show($('session-interruptions'), active.length > 0);
  text($('interruption-title'), `중단된 세션 ${active.length}개`);
  for (const item of active) {
    let row = interruptionRows.get(item.key);
    if (!row) {
      row = make('article','interruption-row'); const info = make('div');
      info.append(make('p','interruption-name'),make('p','small interruption-state'));
      const details = make('details'); details.append(make('summary','','오류 내용'),make('p','small interruption-detail')); info.append(details);
      const actions = make('div','interruption-actions');
      const button = make('button','secondary','세션 보기'); button.addEventListener('click',()=>selectSession(item.key,true));
      const read = make('button','secondary interruption-read','확인했음'); read.addEventListener('click',()=>void acknowledgeInterruption(allSessions.find(value=>value.key===item.key)));
      actions.append(button,read); row.append(info,actions); interruptionRows.set(item.key,row); $('interruption-list').append(row);
    }
    text(row.querySelector('.interruption-name'), `${item.node.name} · ${item.view.title} · ${agents[item.session.agent]}`);
    text(row.querySelector('.interruption-state'), interruptionStatus(item.session) + (displayedOfflineMac(item.node) ? ' · Mac 연결 끊김' : ''));
    setBusy(row,item.node.loading);
    text(row.querySelector('.interruption-detail'), item.session.interruption.detail);
    const [view,read] = row.querySelectorAll('button');
    view.setAttribute('aria-label',`${item.node.name}의 중단된 ${item.view.title} 세션 보기`);
    const pending = interruptionReads.has(interruptionReadKey(item));
    const supportsReceipt = supportsRelease(item.node,[0,2,84,108]);
    const localCleanup = !connected || !item.node.online || !supportsReceipt;
    read.setAttribute('aria-label',`${item.node.name}의 ${item.view.title} 오류 ${localCleanup ? '표시 정리' : '확인했음'}`);
    text(read,pending ? '확인 중…' : localCleanup ? '표시 정리' : '확인했음'); read.disabled = pending;
    read.setAttribute('aria-busy',String(pending));
    read.title = localCleanup ? '이 브라우저에서 이 오류의 표시를 정리합니다. 목록 정리에서 다시 볼 수 있습니다.' : '오류 알림을 정리합니다. 자동 이어가기는 유지됩니다.';
  }
}
async function acknowledgeInterruption(item) {
  if (!item || !unreadInterruption(item.session)) return;
  if (!item.node.online || !connected || !supportsRelease(item.node,[0,2,84,108])) { cleanWarnings([warningKey(item,item.session,'interruption')]); return; }
  const key = interruptionReadKey(item), errorID = item.session.interruption.id;
  if (interruptionReads.has(key)) return;
  const restoreFocus = interruptionRows.get(item.key)?.querySelector('.interruption-read') === document.activeElement;
  interruptionReads.add(key); renderInterruptions();
  try {
    await api(endpoint('/api/action',item.node.id),{action:'read',sessionID:item.session.id,interruptionID:errorID,requestID:uuid()});
    const readAt = new Date().toISOString();
    rememberInterruptionReceipt(item.key,errorID,readAt);
    // Reflect only the successfully saved receipt for this exact episode. A
    // newer error received while the POST ran must still attract attention.
    for (const current of [...allSessions,selectedItem].filter(Boolean)) {
      if (current.key === item.key && current.session.interruption?.id === errorID) current.session.interruption.acknowledgedAt = readAt;
    }
    renderInterruptions(); renderList();
    if (restoreFocus && document.activeElement === document.body && !interruptionRows.has(item.key)) ($('interruption-list').querySelector('button') || $('session-list').querySelector('button') || $('search')).focus({preventScroll:true});
    if ($('feedback').dataset.error === 'true' && $('feedback').textContent.startsWith('오류 확인 상태를 저장하지 못했습니다.')) feedback('오류 확인 상태를 저장했습니다.');
    void refreshNetwork();
  } catch (error) { feedback('오류 확인 상태를 저장하지 못했습니다. '+error.message+' Mac 연결을 확인한 뒤 다시 눌러주세요.',true); }
  finally { interruptionReads.delete(key); renderInterruptions(); }
}
function machineVersionLabel(node) {
  const release = [node.state?.release, node.release].find(value => versionNumbers(value));
  if (!release) return '버전 미확인';
  return `${connected && node.online ? '' : '마지막 확인 · '}v${release.version} · 빌드 ${release.build}`;
}
function renderNodeFilter() {
  const select = $('node-filter'), value = select.value;
  for (const node of nodes) {
    let option = Array.from(select.options).find(item => item.value === node.id);
    if (!option) { option = make('option'); option.value = node.id; select.append(option); }
    const release = [node.state?.release, node.release].find(value => versionNumbers(value));
    text(option, node.name + (release ? ` · v${release.version}` : '') + (node.loading ? ' · 확인 중' : node.online ? '' : ' · 끊김'));
    option.title = `${node.name} · ${machineVersionLabel(node)}`;
  }
  select.value = value;
}
function renderList() {
  const query = $('search').value.trim().toLocaleLowerCase();
  const available = allSessions.filter(item => !retainedError(item));
  const visible = available.filter(({ node, view, session }) => ($('node-filter').value === 'all' || node.id === $('node-filter').value)
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
    const phase = row.querySelector('.phase'), unavailable = !connected || !item.node.online;
    text(phase, unavailable ? item.node.loading ? '갱신 중…' : '연결 끊김' : item.view.phaseTitle);
    phase.dataset.phase = unavailable ? 'unknown' : item.session.interruption && item.session.interruption.recoveredAt == null ? 'error' : item.session.phase;
    phase.title = unavailable ? '마지막 확인: '+item.view.phaseTitle : '';
    text(row.querySelector('.row-auto'), item.session.automatic ? item.node.state.snapshot.paused ? '자동 승인 · 정지' : '자동 승인 켜짐' : '자동 승인 꺼짐');
    const atPosition = $('session-list').children[index];
    if (atPosition !== row) $('session-list').insertBefore(row, atPosition || null);
  }
  text($('session-count'), `${visible.length}개`);
  show($('list-empty'), !visible.length);
  text($('list-empty'), available.length ? '검색이나 필터에 맞는 세션이 없습니다.' : nodes.some(node => node.online) ? '감지된 세션이 없습니다. Mac에서 Claude Code 또는 Codex를 실행하세요.' : '연결된 Mac이 없습니다. 네트워크와 웹 접속 설정을 확인해주세요.');
}
function selectSession(key, focus = false) {
  const item = allSessions.find(item => item.key === key) || ptyRetained.get(key); if (!item) return;
  if (selectedKey !== item.key) {
    terminalHistoryViewer?.close();
    clearTerminalWarm();
    stopSessionHistory();
    stopPTY(); stopTerminalStream(true);
    nativeSessionKey = ''; nativeZoom = 1; clearNativeImage();
    stopDirect(); inputFailure = ''; composing = false;
    terminalFollowScroll = null;
    if (selectedKey) drafts.set(selectedKey, $('terminal-input').value);
    if (selectedKey && $('interaction-dialog').open) { messageDrafts.set(selectedKey,$('message-input').value); saveMessageDrafts(); }
    selectedKey = item.key; selectedItem = item; latestFrame = null; detailGeneration++;
    $('message-input').value = messageDrafts.get(selectedKey) || '';
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
  void refreshFrame();
  renderList(); renderDetail();
  if (focus) void acknowledgeInterruption(item);
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
  const phase = $('session-phase'); text(phase, view.phaseTitle); phase.dataset.phase = session.interruption && session.interruption.recoveredAt == null ? 'error' : session.phase;
  if (session.phase === 'ended' && session.interruption) {
    show($('session-ended'),true);
    text($('session-ended'),`${interruptionStatus(session)}. 오류 내용과 복구 상태를 아래에서 확인해주세요.`);
    terminalPlaceholder(session.interruption.detail); terminalState('error','CLI 종료');
  }
  $('automatic').checked = session.automatic; text($('session-status'), node.state.snapshot.paused ? '이 Mac의 자동 승인이 일시정지되어 있습니다.' : session.activityDetail || session.detail);
  renderSessionSafety();
  renderCodexProgress(selectedItem);
  renderOSPermissions(selectedItem);
  const terminalHost = `${node.name} · ${session.hostName || hosts[session.terminal]}`;
  text($('terminal-host'), terminalHost); $('terminal-host').title = terminalHost;
  if (document.body.classList.contains('terminal-focus')) text($('terminal-heading'), view.title);
  text($('input-help'), 'Enter로 전송하고 Shift Enter로 줄을 바꿉니다. 한글 조합을 끝낸 뒤 전송하세요.');
  if (isPTY) { ensurePTY(); } else if (!view.canRead) {
    latestFrame = null; stopTerminalStream(); stopDirect(); frameController?.abort(); terminalPlaceholder(view.inputReason || '화면 연결이 없습니다.'); terminalState('error', '화면 연결 필요'); text($('terminal-time'), '—');
  }
  renderQuestions(); renderHistory(); updateControls();
}
function originalPageURL(item, pageURL = location.href) {
  if(tunnelAccess)return null;
  if (!item || item.node.local || item.view.pty || sessionEnded(item)) return null;
  const current = (()=>{try{return new URL(pageURL);}catch(_){return null;}})();
  const localPage = current && (current.hostname === 'localhost' || current.hostname.startsWith('127.'));
  const candidates = [];
  for (const address of item.node.state?.webURLs || []) {
    try {
      const url = new URL(address), parts = url.hostname.split('.').map(Number);
      const numeric = /^\d+\.\d+\.\d+\.\d+$/.test(url.hostname) && parts.every(n=>Number.isInteger(n)&&n>=0&&n<=255);
      const privateHost = numeric && (parts[0]===10 || parts[0]===192&&parts[1]===168 || parts[0]===172&&parts[1]>=16&&parts[1]<=31 || parts[0]===169&&parts[1]===254 || localPage&&parts[0]===127);
      if (url.protocol!=='http:' || !privateHost || url.username || url.password || !['','/'].includes(url.pathname)
        || !Number.isInteger(item.node.state?.webPort) || Number(url.port||80)!==item.node.state.webPort) continue;
      url.search = new URLSearchParams({webNode:item.node.id}).toString();
      url.hash = new URLSearchParams({node:item.node.id,session:item.session.id}).toString();
      const sharedSubnet = current?.hostname.split('.').slice(0,3).join('.')===url.hostname.split('.').slice(0,3).join('.');
      candidates.push({url,sharedSubnet});
    } catch (_) {}
  }
  return candidates.sort((a,b)=>Number(b.sharedSubnet)-Number(a.sharedSubnet))[0]?.url || null;
}
function updateTerminalRecovery() {
  const link = $('terminal-direct-page'), url = originalPageURL(selectedItem);
  const available = !!url && allSessions.some(item=>item.key===selectedKey) && (!latestFrame || terminalStream?.reconnecting || !currentNode()?.online || document.activeElement===link);
  show(link,available);show($('terminal-direct-help'),available);
  show($('tunnel-terminal-relogin'),!!tunnelAccess&&tunnelAuthExpired);
  if (available) { link.href=url.href;link.setAttribute('aria-label',`${selectedItem.node.name}의 같은 세션을 새 탭에서 열기`); }
  else link.removeAttribute('href');
  show($('terminal-recovery-actions'),!$('terminal-retry').hidden || available || !!tunnelAccess&&tunnelAuthExpired);
}
function updateControls() {
  updateAllAutomationResetControls();
  updateInteractionControls();
  updateTerminalRecovery();
  if (!selectedItem) return;
  renderNativeDisplay();
  const current = currentNode(), sessionPresent = allSessions.some(item => item.key === selectedKey);
  const streamLive = !!selectedItem.view.pty && !!ptyClient?.ready;
  const resetBusy = automationResets.has(selectedKey) || automationResetNodes.has(selectedItem.node.id);
  const enabled = (connected && current?.online || streamLive) && sessionPresent && !mutation && !resetBusy;
  const historySupported=!selectedItem.view.pty&&selectedItem.session.terminal==='terminal'&&supportsRelease(selectedItem.node,[0,2,204,231]);
  show($('terminal-history-open'),historySupported);
  $('terminal-history-open').disabled=!enabled||sessionEnded(selectedItem);
  const temporaryPTY = ptyTemporary.has(selectedKey);
  const resetSupported = supportsRelease(selectedItem.node,[0,2,159,186]);
  $('reset-automation').disabled = !connected || !current?.online || !sessionPresent || sessionEnded(selectedItem) || temporaryPTY || !resetSupported || resetBusy;
  text($('reset-automation'),resetBusy ? '자동화 초기화 중…' : '자동화 초기화·재실행'); setBusy($('reset-automation'),resetBusy);
  text($('reset-automation-help'),!resetSupported ? '이 Mac을 AutoApprove 0.2.159 이상으로 업데이트하면 자동화를 초기화할 수 있습니다.' : '이 세션의 자동 입력 대기를 비우고 현재 상태부터 다시 감지합니다. 원본 터미널과 작성 중인 초안은 유지합니다.');
  const resetResult = automationResetResult?.key === selectedKey ? automationResetResult : null;
  text($('reset-automation-result'),resetBusy ? '대기 중인 자동화를 비우고 있습니다…' : resetResult?.message || '');
  $('reset-automation-result').className = resetResult?.error ? 'error-text small' : 'muted small';
  show($('reset-automation-result'),resetBusy || !!resetResult);
  $('automatic').disabled = !enabled || sessionEnded(selectedItem) || temporaryPTY || (!selectedItem.view.canApprove && !selectedItem.session.automatic);
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
  const inputEnabled = base && fresh && !mutation && !messageBusy(selectedKey);
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
  $('terminal-keyboard').disabled = !(base && canDirect && !composeMode && !messageBusy(selectedKey) && (fresh || retainKeyboard || inputInFlight || directSending));
  document.querySelector('.terminal').dataset.input = composeMode ? 'compose' : 'direct';
  show($('input-editor'), composeMode); show($('compose-input-label'), composeMode);
  if (composeMode && !wasCompose) sizeInput();
  $('compose-input').checked = composeMode; $('compose-input').disabled = !nativeConnection() && !canDirect || composing;
  const keyboardActive = document.activeElement === $('terminal-keyboard') && !$('terminal-keyboard').disabled;
  $('terminal-keyboard-toggle').disabled = $('terminal-keyboard').disabled;
  $('terminal-keyboard-toggle').setAttribute('aria-pressed', String(keyboardActive));
  $('terminal-keyboard-toggle').setAttribute('aria-label', keyboardActive ? '터미널 키보드 닫기' : '터미널 키보드 열기');
  const terminalSetupHelp = selectedItem.session.terminal === 'terminal' && !canDirect
    ? '접속한 Mac의 AutoApprove 앱에서 연결 설정 → 원본 터미널 화면·입력 → 직접 입력 연결을 설정해주세요. 각 Mac에서 처음 한 번 관리자 승인으로 설치합니다. 휴대폰에는 설치하지 않습니다. 작성 후 Enter 전송은 사용할 수 있습니다.' : '';
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
  $('send-input').disabled = originalDraftOnly || !nativeInput || !(inputEnabled || queueEnabled) || composing || inputInFlight && !directMode || byteLength($('terminal-input').value,8000) > 8000;
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
const terminalResyncError = () => Object.assign(new Error('최신 원본 화면을 다시 연결합니다.'), {terminalResync:true});
let terminalNetworkOffline = false;
function terminalDeltaTextValid(text) {
  const high = code => code >= 0xd800 && code <= 0xdbff, low = code => code >= 0xdc00 && code <= 0xdfff;
  for (let i=0;i<text.length;i++) {
    const code = text.charCodeAt(i);
    if (high(code)) { if (!low(text.charCodeAt(++i))) return false; }
    else if (low(code)) return false;
  }
  return true;
}
function terminalPatchScreen(update, previous) {
  const patch = update.screenPatch;
  if (!patch || typeof patch !== 'object' || !previous || typeof previous.screen !== 'string' || previous.sessionID !== update.sessionID || !update.streamID || update.streamID !== previous.streamID || patch.baseRevision !== previous.revision || update.revision === previous.revision || patch.baseLength !== previous.screen.length || typeof patch.text !== 'string' || update.screen != null) throw terminalResyncError();
  for (const value of [patch.baseLength,patch.prefix,patch.suffix,patch.length]) if (!Number.isSafeInteger(value) || value < 0 || value > 2000000) throw terminalResyncError();
  if (patch.prefix + patch.suffix > patch.baseLength || patch.prefix + patch.text.length + patch.suffix !== patch.length) throw terminalResyncError();
  const high = code => code >= 0xd800 && code <= 0xdbff, low = code => code >= 0xdc00 && code <= 0xdfff;
  const boundary = offset => !offset || offset === patch.baseLength || !(high(previous.screen.charCodeAt(offset-1)) && low(previous.screen.charCodeAt(offset)));
  if (!boundary(patch.prefix) || !boundary(patch.baseLength-patch.suffix)) throw terminalResyncError();
  if (!terminalDeltaTextValid(patch.text)) throw terminalResyncError();
  const screen = previous.screen.slice(0,patch.prefix) + patch.text + previous.screen.slice(patch.baseLength-patch.suffix);
  if (screen.length * 3 > 2000000 && byteLength(screen,2000000) > 2000000) throw terminalResyncError();
  return screen;
}
function terminalCopyScreen(update, previous) {
  const copy = update.screenCopy;
  if (!copy || typeof copy !== 'object' || !previous || typeof previous.screen !== 'string' || previous.sessionID !== update.sessionID || !update.streamID || update.streamID !== previous.streamID || copy.baseRevision !== previous.revision || update.revision === previous.revision || copy.baseLength !== previous.screen.length || typeof copy.head !== 'string' || typeof copy.tail !== 'string' || update.screen != null || update.screenPatch != null) throw terminalResyncError();
  for (const value of [copy.baseLength,copy.start,copy.count,copy.length]) if (!Number.isSafeInteger(value) || value < 0 || value > 2000000) throw terminalResyncError();
  if (!copy.count || copy.start + copy.count > copy.baseLength || copy.head.length + copy.count + copy.tail.length !== copy.length || !terminalDeltaTextValid(copy.head) || !terminalDeltaTextValid(copy.tail)) throw terminalResyncError();
  const boundary = offset => !offset || offset === copy.baseLength || !(previous.screen.charCodeAt(offset-1) >= 0xd800 && previous.screen.charCodeAt(offset-1) <= 0xdbff && previous.screen.charCodeAt(offset) >= 0xdc00 && previous.screen.charCodeAt(offset) <= 0xdfff);
  if (!boundary(copy.start) || !boundary(copy.start+copy.count)) throw terminalResyncError();
  const screen = copy.head + previous.screen.slice(copy.start,copy.start+copy.count) + copy.tail;
  if (screen.length * 3 > 2000000 && byteLength(screen,2000000) > 2000000) throw terminalResyncError();
  return screen;
}
function mergeTerminalUpdate(update, previous, sessionID) {
  if (!update || update.sessionID !== sessionID || typeof update.revision !== 'string' || update.revision.length > 512 || typeof update.observedAt !== 'string' || !Number.isFinite(Date.parse(update.observedAt)) || !Array.isArray(update.keys) || update.keys.length > 64 || update.keys.some(key => typeof key !== 'string' || key.length > 64) || update.inputReason != null && typeof update.inputReason !== 'string' || update.streamID != null && typeof update.streamID !== 'string') throw new Error('터미널 화면 정보를 확인하지 못했습니다. 화면을 다시 연결해주세요.');
  if (update.outputReason != null && (typeof update.outputReason !== 'string' || update.outputReason.length > 4096)) throw new Error('원본 출력 상태를 확인하지 못했습니다.');
  if (update.sequence != null && (!Number.isSafeInteger(update.sequence) || update.sequence < 0)) throw new Error('원본 화면 순서를 확인하지 못했습니다.');
  if (update.question != null && (typeof update.question.id !== 'string' || update.question.id.length > 512 || typeof update.question.question !== 'string' || update.question.question.length > 4000 || !Array.isArray(update.question.options) || update.question.options.length < 2 || update.question.options.length > 20 || update.question.options.some(option=>typeof option!=='string'||!option||option.length>4000) || !Number.isInteger(update.question.selected) || update.question.selected<0 || update.question.selected>=update.question.options.length)) throw new Error('원본 질문의 선택지를 확인하지 못했습니다.');
  const {screenPatch,screenCopy,appearanceUnchanged,...fields} = update;
  const nativeDisplay = nativeTerminal() ? mergeNativeDisplay(update.nativeDisplay, previous?.nativeDisplay, typeof update.screen !== 'string' && !screenPatch && !screenCopy) : undefined;
  if (screenPatch != null || screenCopy != null) {
    if (screenPatch != null && screenCopy != null) throw terminalResyncError();
    if (appearanceUnchanged != null && appearanceUnchanged !== true) throw terminalResyncError();
    const screen = screenCopy != null ? terminalCopyScreen(update,previous) : terminalPatchScreen(update,previous);
    return {...fields,screen,appearance:appearanceUnchanged ? previous.appearance : update.appearance,nativeDisplay};
  }
  if (appearanceUnchanged != null) throw terminalResyncError();
  if (typeof update.screen === 'string') return {...fields, nativeDisplay};
  if (!previous || update.revision !== previous.revision || update.sessionID !== previous.sessionID) throw new Error('최신 화면을 다시 연결해주세요.');
  // A compact update carries current controls. Missing optional input fields
  // clear old locks/cursors/tokens while the unchanged screen and colors remain.
  return {...previous, ...fields, screen:previous.screen, appearance:update.appearance ?? previous.appearance, inputReason:update.inputReason, outputReason:update.outputReason, cursor:update.cursor, streamID:update.streamID, question:update.question, nativeDisplay};
}
function terminalUpdateIsOlder(update, previous) {
  if (!previous || update.sessionID !== previous.sessionID || !previous.streamID || update.streamID !== previous.streamID) return false;
  if (Number.isSafeInteger(update.sequence) && Number.isSafeInteger(previous.sequence)) return update.sequence < previous.sequence;
  return false; // Legacy Mac clocks can change; observation time is not an ordering token.
}
function applyTerminalFrame(frame, receivedAt = performance.now()) {
  clearTerminalWarm();
  const previous = latestFrame;
  if (!directMode && directChannelStreamID && frame.streamID !== directChannelStreamID) stopDirect();
  if (directMode && (frame.streamID || null) !== directStreamID) {
    stopDirect(); inputFailure = '터미널 연결이 바뀌어 직접 입력을 멈췄습니다. 보존한 입력과 새 화면을 확인해주세요.';
  }
  if (directMode && (!frame.keys.includes('characters') || !frame.keys.includes('backspace') || frame.inputReason)) {
    stopDirect(); inputFailure = frame.inputReason || '원본 입력 권한을 다시 연결해주세요.';
  }
  latestFrame = frame;
  terminalFrameReceivedAt = receivedAt;
  const changed = renderTerminal(frame.screen, frame.appearance);
  quietFrames = changed ? 0 : quietFrames + 1;
  terminalState(changed && previous ? 'changed' : 'live', !frame.screen.trim() ? '연결됨 · 빈 화면' : changed && previous ? '새 출력' : '연결됨');
  if (nativeTerminal()) terminalState(frame.nativeDisplay?.state === 'live' ? 'live' : 'pending', frame.nativeDisplay?.state === 'live' ? '원본 창 화면' : '원본 연결 필요');
  text($('terminal-time'), nowLabel(frame.observedAt)); show($('terminal-error'), false); show($('terminal-retry'), false);
  if (selectedItem) renderQuestions();
  updateControls();
  if (!frame.inputReason) void prepareDirectChannel();
  if (directMode && directQueue.length && !directSending) void pumpDirect();
}
function stopTerminalStream(resetFailure = false) {
  if (terminalStream) {
    terminalStream.source?.close(); clearTimeout(terminalStream.retryTimer); clearTimeout(terminalStream.watchdog); clearTimeout(terminalStream.fallbackWatchdog);
    stopTerminalFallback(terminalStream);
  }
  terminalStream = null;
  if (terminalPaint) cancelAnimationFrame(terminalPaint);
  clearTimeout(terminalPaintTimer); terminalPaintTimer = null;
  terminalPaint = 0; terminalPending = null; terminalPendingAt = -Infinity;
  if (resetFailure) terminalStreamFailed = '';
}
function failTerminalStream(stream, message) {
  if (terminalStream !== stream) return;
  clearTerminalWarm();
  stopTerminalStream(); terminalStreamFailed = stream.key; latestFrame = null; stopDirect();
  text($('terminal-error'), message); show($('terminal-error'), true); text($('terminal-retry'), '화면 다시 연결'); show($('terminal-retry'), true);
  terminalState('error', '연결 끊김'); updateControls();
}
function terminalStreamCurrent(stream, allowOffline = false) {
  return terminalStream === stream && selectedKey === stream.key && detailGeneration === stream.generation
    && nativeTerminal() === stream.renderWindow && (allowOffline || !stream.offline) && !document.hidden;
}
function pauseTerminalNetwork(stream) {
  stream.offline = true; stream.reconnecting = true; stream.sseReady = false;
  stream.source?.close(); stream.source = null;
  clearTimeout(stream.retryTimer); stream.retryTimer = null;
  clearTimeout(stream.watchdog); clearTimeout(stream.fallbackWatchdog); stopTerminalFallback(stream);
  if (terminalPaint) cancelAnimationFrame(terminalPaint);
  clearTimeout(terminalPaintTimer); terminalPaintTimer = null; terminalPaint = 0; terminalPending = null;
  terminalState('pending', '네트워크 연결 대기'); updateControls();
  // Browser reachability is only a hint, especially on a VPN/private hotspot.
  // A bounded LAN read may recover even if an online event never arrives.
  stream.pollTimer = setTimeout(() => void readTerminalFallback(stream),1500);
}
function stopTerminalFallback(stream) {
  clearTimeout(stream.pollTimer); stream.pollTimer = null;
  stream.pollController?.abort(); stream.pollController = null;
}
async function readTerminalFallback(stream) {
  if (!terminalStreamCurrent(stream,true) || stream.pollController || stream.sseReady) return;
  clearTimeout(stream.pollTimer); stream.pollTimer = null;
  const controller = new AbortController(), started = performance.now(); stream.pollController = controller;
  try {
    const query = new URLSearchParams({node:stream.nodeID, session:stream.sessionID});
    if (stream.renderWindow) query.set('view', 'screen');
    if (latestFrame && !stream.resync) query.set('revision', latestFrame.revision); else query.set('initial', '1');
    // A short read can work when a hotspot/VPN buffers a long-lived SSE.
    // It stays on the selected original; it never creates or resumes a CLI.
    const update = await api('/api/terminal?' + query, undefined, controller.signal, 7000);
    if (!terminalStreamCurrent(stream,true) || stream.pollController !== controller || stream.sseReady) return;
    if (terminalUpdateIsOlder(update, latestFrame)) return;
    const frame = mergeTerminalUpdate(update, latestFrame, stream.sessionID);
    const elapsed = performance.now()-started;
    stream.readRTT = stream.readRTT == null ? elapsed : stream.readRTT*0.75+elapsed*0.25;
    const changedStream = latestFrame?.streamID && frame.streamID !== latestFrame.streamID;
    if (changedStream) {
      stream.source?.close(); stream.source = null; clearTimeout(stream.retryTimer); stream.retryTimer = null;
      if (terminalPaint) cancelAnimationFrame(terminalPaint);
      clearTimeout(terminalPaintTimer); terminalPaintTimer = null;
      terminalPaint = 0; terminalPending = null; terminalPendingAt = -Infinity;
    }
    const recoveredOffline = stream.offline;
    if (recoveredOffline) { stream.offline = false; terminalNetworkOffline = false; stream.retries = 0; }
    stream.reconnecting = false; stream.pollFailures = 0; stream.resync = false;
    applyTerminalFrame(frame);
    if (changedStream || recoveredOffline) openTerminalStream(stream);
  } catch (error) {
    if (!terminalStreamCurrent(stream,true) || stream.pollController !== controller || controller.signal.aborted || stream.sseReady) return;
    if ([400,401,403,404,409,410].includes(error.status) || !error.status && !error.retryable) {
      failTerminalStream(stream, error.message); return;
    }
    stream.pollFailures++; stream.reconnecting = true;
    terminalState('pending', latestFrame ? '다시 연결 중…' : '첫 화면 연결 지연');
    text($('terminal-error'), latestFrame ? '터미널 연결을 다시 확인하고 있습니다. 마지막 화면은 유지됩니다.' : '원본 Mac의 첫 화면을 아직 받지 못했습니다. 자동으로 재연결 중이며, 원본 Mac에서 직접 열 수도 있습니다.');
    show($('terminal-error'), !latestFrame); text($('terminal-retry'), '지금 다시 연결'); show($('terminal-retry'), true);
    updateControls();
  } finally {
    if (stream.pollController === controller) {
      stream.pollController = null;
      if (terminalStreamCurrent(stream,true) && !stream.sseReady) {
        const interval = stream.offline ? 3000 : stream.pollFailures ? Math.min(3000, 500 * 2 ** Math.min(stream.pollFailures,3)) : directMode || selectedItem?.session.phase === 'working' ? 250 : 750;
        stream.pollTimer = setTimeout(() => void readTerminalFallback(stream), interval);
      }
    }
  }
}
function reconnectTerminalStream(stream, resync = false) {
  if (terminalStream !== stream || stream.offline || document.hidden) return;
  if (resync) { stream.resync = true; stream.reconnecting = true; stopTerminalFallback(stream); }
  if (resync) stream.frame = null;
  if (stream.retryTimer) { updateControls(); void readTerminalFallback(stream); return; }
  stream.source?.close(); clearTimeout(stream.watchdog);
  if (terminalPaint) cancelAnimationFrame(terminalPaint);
  clearTimeout(terminalPaintTimer); terminalPaintTimer = null;
  terminalPaint = 0; terminalPending = null;
  stream.sseReady = false;
  // A failed stream must not invalidate a fresh, successful fallback read.
  stream.reconnecting ||= !latestFrame || performance.now() - terminalFrameReceivedAt >= 3000;
  if (stream.reconnecting) {
    const firstDelayed = !latestFrame && stream.pollFailures > 0;
    terminalState('pending', firstDelayed ? '첫 화면 연결 지연' : '재연결 중…');
    text($('terminal-error'), firstDelayed ? '원본 Mac의 첫 화면을 아직 받지 못했습니다. 자동으로 재연결 중이며, 원본 Mac에서 직접 열 수도 있습니다.' : '네트워크 연결이 끊겨 원래 터미널에 다시 연결하고 있습니다.');
    show($('terminal-error'), firstDelayed); text($('terminal-retry'), '지금 다시 연결'); show($('terminal-retry'), true);
  }
  updateControls();
  void readTerminalFallback(stream);
  // Retry only the read subscription. Input POSTs are never replayed here.
  const attempt = stream.retries++;
  const delay = attempt === 0 ? 0 : Math.min(5000,250*2**Math.min(attempt-1,5))*(0.8+Math.random()*0.2);
  stream.retryTimer = setTimeout(() => {
    stream.retryTimer = null;
    if (terminalStream === stream && !document.hidden) openTerminalStream(stream);
  }, delay);
}
function terminalSilenceBudget(stream) {
  // Allow two fresh-source heartbeats plus measured source/network jitter.
  // A slow VPN gets more room; a healthy LAN no longer waits a fixed 8 s.
  return Math.min(12000,Math.max(4500,2*(stream.eventGap || 2000)+Math.max(500,4*(stream.eventJitter || 0)),3*(stream.readRTT || 0)+2500));
}
function downgradeUnstartedTerminalWire(stream,error) {
  const source = stream.source;
  if (source?.version && !source.received && (!error || error.wireFormat || [406,415].includes(error.status))) stream.wireVersion = source.version === 3 ? 2 : 0;
}
function terminalEventReceived(stream) {
  const now = performance.now();
  if (stream.sourceEventAt != null) {
    const gap = now-stream.sourceEventAt, average = stream.eventGap || 2000;
    stream.eventJitter = (stream.eventJitter || 0)*0.75+Math.abs(gap-average)*0.25;
    stream.eventGap = average*0.75+gap*0.25;
  }
  stream.sourceEventAt = now;
  // A single frame from a flapping connection must not erase its backoff.
  if (now-stream.sourceOpenedAt >= 1500) stream.retries = 0;
  stream.sseReady = true; stream.reconnecting = false; stream.resync = false;
  stopTerminalFallback(stream); watchTerminalStream(stream);
}
function watchTerminalStream(stream) {
  clearTimeout(stream.watchdog); clearTimeout(stream.fallbackWatchdog);
  // Opening includes discovery, source observation and a bounded LAN relay.
  // Keep the established-source watchdog fast without cancelling slow opens.
  const silence = Math.max(stream.sourceEventAt == null ? 10000 : 0,terminalSilenceBudget(stream));
  stream.fallbackWatchdog = setTimeout(() => {
    if (!terminalStreamCurrent(stream)) return;
    stream.sseReady = false;
    void readTerminalFallback(stream);
  // A source heartbeat can include up to one 800 ms idle observation interval.
  // Do not start a redundant GET just before a healthy heartbeat arrives.
  }, Math.min(5000,Math.max(3000,silence*0.6)));
  // Both legacy controls and compact alive events require a fresh source read.
  stream.watchdog = setTimeout(() => { downgradeUnstartedTerminalWire(stream); reconnectTerminalStream(stream); },silence);
}
function ensureTerminalStream() {
  const renderWindow = nativeTerminal();
  if (terminalStreamFailed === selectedKey || terminalStream?.key === selectedKey && terminalStream.generation === detailGeneration && terminalStream.renderWindow === renderWindow) return;
  stopTerminalStream();
  const item = selectedItem, streamURL = endpoint('/api/terminal/stream', item.node.id, item.session.id) + '&delta=1&copy=1&compact=1' + (renderWindow ? '&view=screen' : '');
  const stream = {key:selectedKey, generation:detailGeneration, renderWindow, url:streamURL, nodeID:item.node.id, sessionID:item.session.id, wireVersion:supportsTerminalWire(item.node), source:null, frame:null, resync:false, retries:0,reconnecting:!!latestFrame, retryTimer:null, watchdog:null, fallbackWatchdog:null, pollTimer:null, pollController:null, pollFailures:0, sseReady:false,offline:false};
  terminalStream = stream;
  if (!latestFrame) { terminalState('pending', '연결 중…'); updateControls(); }
  if (terminalNetworkOffline) pauseTerminalNetwork(stream);
  else { openTerminalStream(stream); void readTerminalFallback(stream); }
}
function openTerminalStream(stream) {
  if (!terminalStreamCurrent(stream)) return;
  const url = new URL(stream.url,location.href);
  let basis = !stream.renderWindow && !stream.resync ? stream.frame || latestFrame : null;
  if (basis && latestFrame && basis.streamID === latestFrame.streamID && terminalUpdateIsOlder(basis,latestFrame)) basis = latestFrame;
  stream.frame = basis;
  if (basis?.sessionID === stream.sessionID && basis.streamID) { url.searchParams.set('revision',basis.revision); url.searchParams.set('stream',basis.streamID); }
  stream.sourceEventAt = null; stream.sourceOpenedAt = performance.now();
  const version = Math.min(stream.wireVersion,supportsTerminalWire(currentNode() || selectedItem?.node));
  const source = window.AutoApproveTerminalWire?.open(url.href,version) || new EventSource(url.href); stream.source = source;
  const current = () => terminalStreamCurrent(stream) && stream.source === source;
  watchTerminalStream(stream);
  source.addEventListener('screen', event => {
    if (!current()) return;
    try {
      if (!Object.hasOwn(event,'value') && (event.data.length > 2000000 || byteLength(event.data,2000000) > 2000000)) throw new Error('터미널 화면이 너무 큽니다. 화면을 다시 연결해주세요.');
      const update = Object.hasOwn(event,'value') ? event.value : JSON.parse(event.data);
      if (terminalUpdateIsOlder(update, stream.frame)) { stream.sseReady = false; void readTerminalFallback(stream); return; }
      const frame = mergeTerminalUpdate(update, stream.frame, stream.sessionID);
      stream.frame = frame;
      if (terminalUpdateIsOlder(frame, terminalPending || latestFrame)) { stream.sseReady = false; void readTerminalFallback(stream); return; }
      // Observe token changes immediately, even if a later frame replaces this
      // one before painting. Pending input must never cross terminal identities.
      if (directMode && (frame.streamID || null) !== directStreamID) {
        stopDirect(); inputFailure = '터미널 연결이 바뀌어 직접 입력을 멈췄습니다. 보존한 입력과 새 화면을 확인해주세요.';
      }
      if (directMode && (!frame.keys.includes('characters') || !frame.keys.includes('backspace') || frame.inputReason)) {
        stopDirect(); inputFailure = frame.inputReason || '원본 입력 권한을 다시 연결해주세요.';
      }
      terminalEventReceived(stream);
      terminalPending = frame;
      terminalPendingAt = performance.now();
      if (terminalPaint) return;
      const paint = () => {
        if (!terminalPaint) return;
        cancelAnimationFrame(terminalPaint); clearTimeout(terminalPaintTimer); terminalPaintTimer = null;
        terminalPaint = 0;
        if (!current()) { terminalPending = null; return; }
        const frame = terminalPending, receivedAt = terminalPendingAt; terminalPending = null;
        try {
          if (frame) { applyTerminalFrame(frame, receivedAt); layoutCursor(); }
        } catch (error) { failTerminalStream(stream, error.message); }
      };
      terminalPaint = requestAnimationFrame(paint);
      // A suspended animation callback must not freeze an otherwise live read.
      terminalPaintTimer = setTimeout(paint, 100);
    } catch (error) {
      if (error.terminalResync) reconnectTerminalStream(stream,true);
      else failTerminalStream(stream,error.message);
    }
  });
  source.addEventListener('alive', event => {
    if (!current()) return;
    try {
      if (!Object.hasOwn(event,'value') && event.data.length > 2048) throw terminalResyncError();
      const pulse = Object.hasOwn(event,'value') ? event.value : JSON.parse(event.data), basis = stream.frame;
      if (!pulse || typeof pulse.streamID !== 'string' || pulse.streamID.length > 512 || typeof pulse.revision !== 'string' || pulse.revision.length > 512 || !Number.isSafeInteger(pulse.sequence) || pulse.sequence < 0 || typeof pulse.observedAt !== 'string' || !Number.isFinite(Date.parse(pulse.observedAt)) || !basis || pulse.streamID !== basis.streamID || pulse.revision !== basis.revision) throw terminalResyncError();
      if (terminalUpdateIsOlder({...pulse,sessionID:stream.sessionID},basis)) return;
      stream.frame = {...basis,sequence:pulse.sequence,observedAt:pulse.observedAt};
      if (terminalUpdateIsOlder(stream.frame,latestFrame)) return;
      terminalEventReceived(stream);
      // No parsing, diffing, question rebuild or terminal repaint while idle.
      // Controls are inherited only from the exact freshly confirmed basis.
      if (latestFrame?.streamID === pulse.streamID && latestFrame.revision === pulse.revision) {
        latestFrame = {...latestFrame,sequence:pulse.sequence,observedAt:pulse.observedAt}; terminalFrameReceivedAt = performance.now();
        terminalState('live',latestFrame.screen.trim() ? '연결됨' : '연결됨 · 빈 화면');
        show($('terminal-error'),false); show($('terminal-retry'),false);
        text($('terminal-time'),nowLabel(pulse.observedAt)); updateControls();
        if (directMode && directQueue.length && !directSending) void pumpDirect();
      }
    } catch (_) { reconnectTerminalStream(stream,true); }
  });
  source.addEventListener('failure', event => {
    if (!current()) return;
    let message = 'Mac의 터미널 연결이 끊겼습니다. 원래 터미널을 확인한 뒤 화면을 다시 연결해주세요.';
    try {
      if (Object.hasOwn(event,'value') || event.data.length <= 8192) {
        const failure = Object.hasOwn(event,'value') ? event.value : JSON.parse(event.data);
        if (failure.retryable === true) { reconnectTerminalStream(stream); return; }
        if (typeof failure.error === 'string') message = failure.error;
      }
    } catch (_) {}
    failTerminalStream(stream, message);
  });
  source.onerror = error => { if (current()) { downgradeUnstartedTerminalWire(stream,error); reconnectTerminalStream(stream); } };
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
    if (!previous) query.set('initial', '1');
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
    const message = !error.status && !error.unsent ? '입력 전달 결과를 확인하지 못했습니다. 원본 화면에서 반영 여부를 확인해주세요.' : error.message;
    if (selectedKey === item.key) inputFailure = message;
    if (consumedDraft) {
      if (selectedKey === item.key && directMode) stopDirect(true, value);
      else restoreDirectDraft(value, item.key);
    }
    feedback(message, true);
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
  if (!directMode || messageBusy(selectedKey) || $('terminal-keyboard').disabled || !inputKeys().includes(kind)) return false;
  if (directQueue.length >= 64 || byteLength(value,8000) > 8000) { stopDirect(); inputFailure = '입력이 많아 바로 입력을 멈췄습니다. 현재 화면과 작성한 내용을 확인해주세요.'; updateControls(); return false; }
  const previous = directQueue[directQueue.length - 1];
  if (kind === 'characters' && previous?.kind === kind && byteLength(previous.value + value,8000) <= 8000) previous.value += value;
  else directQueue.push({ key: selectedKey, kind, value, streamID: latestFrame?.streamID || null });
  scheduleDirect(kind === 'characters' && directQueue.length > 1 ? 4 : 0);
  return true;
}
function scheduleDirect(delay) {
  if (directSending && directChannel?.state !== 'ready' || !directMode) return;
  const due = performance.now() + delay;
  // Bound the first character's wait. Later keystrokes may accelerate a batch,
  // but must never postpone it until the user stops typing.
  if (directTimer !== null && directTimerDue <= due) return;
  clearTimeout(directTimer); directTimerDue = due;
  directTimer = setTimeout(() => { directTimer = null; directTimerDue = Infinity; void pumpDirect(); }, delay);
}
async function pumpDirect() {
  if (!directMode) return;
  if (directChannelState === 'idle' && !directSending && window.AutoApproveInputChannel) void prepareDirectChannel();
  if (directChannel?.state === 'ready') { pumpDirectChannel(); return; }
  if (['opening','reconnecting'].includes(directChannelState) || directSending) return;
  clearTimeout(directTimer); directTimer = null; directTimerDue = Infinity;
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
    // An optional input script can arrive after HTTP input has begun. Bind only
    // after its acknowledgement, so there is still exactly one ordered writer.
    if (directMode && directChannelState === 'idle') void prepareDirectChannel();
    if (directMode && directQueue.length) scheduleDirect(250);
  }
}
function pumpDirectChannel() {
  if (!directMode || directChannel?.state !== 'ready') return;
  clearTimeout(directTimer); directTimer = null; directTimerDue = Infinity;
  if (!terminalFrameFresh() || mutation) {
    if (!directFreshening) {
      directFreshening = true; const generation = inputGeneration, key = selectedKey;
      void freshInputFrame(key).then(fresh => { if (generation !== inputGeneration) return;directFreshening = false;if (fresh) pumpDirectChannel();else {stopDirect();updateControls();} });
    }
    return;
  }
  while (directMode && directQueue.length && directChannel?.state === 'ready') {
    const item = directQueue[0];
    if (item.key !== selectedKey || item.streamID !== latestFrame?.streamID || latestFrame.inputReason || !inputKeys().includes(item.kind)) { stopDirect(); updateControls(); return; }
    const index = window.AutoApproveInputChannel.keys.indexOf(item.kind);
    if (index < 0) { stopDirect(); updateControls(); return; }
    const text = new TextEncoder().encode(item.value), payload = new Uint8Array(1+text.length);payload[0] = index;payload.set(text,1);
    if (!directChannel.canSend(payload.length)) break;
    if (!directChannel.send(3,payload)) break;
    directQueue.shift();
  }
  directSending = (directChannel?.pendingCount || 0) > 0; updateControls();
}
function captureDirectText() {
  if (composing || !directMode || !keyboardText()) return;
  const value = keyboardText();
  // Let multiline paste stay editable; a user can send it as one composed Enter action.
  if (/[\x00-\x1f\x7f]/.test(value) || byteLength(value,8000) > 8000) {
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
  const terminalQuestion = latestFrame?.sessionID === session.id ? latestFrame.question : null;
  const sources = [session, ...(session.backgroundSessions || [])];
  const signature = JSON.stringify([terminalQuestion, terminalQuestion && [latestFrame.keys.includes('choice'),latestFrame.inputReason], sources.map(source => [source.id, source.claudeApprovals, source.queuedQuestions, source.pendingSummary, source.capacityResume, source.systemCommandRisk, source.systemSafety])]);
  if (signature === questionSignature) return;
  // Capture every draft before status-driven rerender; never discard a typed answer on a polling tick.
  for (const form of $('questions').querySelectorAll('form')) {
    if (form.dataset.structured === 'true') continue;
    questionDrafts.set(form.dataset.questionKey, { answer: form.querySelector('textarea').value, choices: Array.from(form.querySelectorAll('input:checked')).map(input => input.value) });
  }
  const active = document.activeElement, activeQuestion = active?.closest('#questions form')?.dataset.questionKey;
  const activeChoice = active?.tagName === 'INPUT' ? {name:active.name, value:active.value} : null;
  const wasText = active?.tagName === 'TEXTAREA', selectionStart = wasText ? active.selectionStart : null, selectionEnd = wasText ? active.selectionEnd : null;
  const fieldIndex = wasText && activeQuestion ? Array.from(active.closest('form').querySelectorAll('textarea')).indexOf(active) : 0;
  $('questions').replaceChildren(); questionSignature = signature;
  let count = 0; const past = [];
  if (terminalQuestion) {
    count++; const key = `${node.id}/${session.id}/terminal:${terminalQuestion.id}`;
    const unavailable = ['sending','queued','uncertain'].includes(terminalQuestion.reply?.phase) || !latestFrame.keys.includes('choice') || !!latestFrame.inputReason;
    $('questions').append(structuredQuestionForm(key, [{id:'choice', question:terminalQuestion.question, allowText:false,
      options:terminalQuestion.options.map((label,index)=>({label,value:String(index)}))}], {
      nodeID:node.id, title:'원본 터미널의 질문', unavailable,
      status:terminalQuestion.reply?.message || (unavailable ? latestFrame.inputReason || '이 연결에는 선택형 질문 입력이 필요합니다. Mac에서 직접 입력 연결 또는 VS Code 확장을 확인해주세요.' : '항목을 고른 뒤 답변 보내기를 누르면 같은 터미널에서 선택합니다.'),
      send:async answers=>{
        const frame = latestFrame;
        if (frame?.sessionID !== session.id || frame.question?.id !== terminalQuestion.id) { feedback('질문이 바뀌었습니다. 현재 질문을 확인해주세요.',true);return false; }
        return sendQuestionAnswer(key,node.id,{action:'replyTerminalQuestion',sessionID:session.id,questionID:terminalQuestion.id,choice:Number(answers.choice.choices[0]),revision:frame.revision},'원본 터미널에 선택을 전달했습니다.');
      }
    }));
  }
  for (const source of sources) {
    for (const approval of source.claudeApprovals || []) {
      if (!approval.systemCommandRisk && approval.questions?.length) {
        count++; $('questions').append(structuredQuestionForm(`${node.id}/${source.id}/${approval.id}`, approval.questions, {
          nodeID: node.id, title: source.id === session.id ? 'Claude의 질문' : 'Claude 백그라운드 질문', unavailable: approval.sending,
          status: approval.sending ? 'Claude에 답변을 전달하고 있습니다.' : approval.automaticAt ? '자동 응답 예약 · 답변을 작성하면 예약을 멈춥니다.' : '',
          begin: () => beginQuestionEditing(`${node.id}/${source.id}/${approval.id}`, node.id, {action:'beginClaudeQuestion', sessionID:source.id, requestIDForApproval:approval.id}),
          send: answers => sendQuestionAnswer(`${node.id}/${source.id}/${approval.id}`, node.id, {action:'replyClaudeQuestions', sessionID:source.id, requestIDForApproval:approval.id, answers}, 'Claude에 답변을 전달했습니다.')
        })); continue;
      }
      count++; const section = make('div', 'question'); section.append(make('h4', '', approval.systemCommandRisk ? systemSafetyTitle(approval.systemCommandRisk) : approval.summary));
      if (approval.systemCommandRisk) {
        section.append(make('p','notice error','이 명령을 거절하고 같은 대화에 안전한 대안을 전달합니다.'));
        const details = make('details'); details.append(make('summary','','요청 내용'),make('pre','safety-request',approval.summary)); section.append(details);
      }
      if (source.id !== session.id) section.append(make('p', 'muted small', 'Claude 백그라운드 요청'));
      if (approval.automaticAt) section.append(make('p', 'muted small', '자동 응답 예약 · ' + nowLabel(approval.automaticAt)));
      const actions = make('div', 'question-actions');
      for (const [label, actionName] of [[approval.systemCommandRisk ? '안전한 방법으로 계속' : approval.isQuestion ? approval.answer : '이번 요청 허용', 'claudeApprove'], ['터미널에서 답하기', 'claudeRelease']]) {
        const button = make('button', actionName === 'claudeRelease' ? 'secondary' : '', label); button.dataset.unavailable = String(approval.sending);
        button.addEventListener('click', () => void action(node.id, { action: actionName, sessionID: source.id, requestIDForApproval: approval.id }, '요청을 처리했습니다.'));
        actions.append(button);
      }
      section.append(actions); $('questions').append(section);
    }
    for (const question of source.queuedQuestions || []) {
      if (pastQuestionEligible(node,source,question)) {
        const key = pastQuestionKey(node,source,question);
        if (!cleanup.questions.has(key)) past.push({key,question,source});
        continue;
      }
      count++; const questionKey = `${node.id}/${source.id}/${question.id}`, draft = questionDrafts.get(questionKey) || { answer: '', choices: [] };
      if (['failed','cancelled'].includes(question.reply?.phase) && !questionDeliveries.get(questionKey)?.busy && lastNetworkStartedAt > (questionDeliveries.get(questionKey)?.failedAt ?? questionDeliveries.get(questionKey)?.finishedAt ?? -Infinity)) {
        const state = questionDeliveries.get(questionKey) || {}; state.uncertain = false; state.sent = false;
        state.error = question.reply.phase === 'failed' ? question.reply.message : ''; state.message = question.reply.phase === 'cancelled' ? question.reply.message : ''; questionDeliveries.set(questionKey,state);
      }
      const form = make('form', 'question'); form.dataset.questionKey = questionKey; form.append(make('h4', '', question.title));
      const unavailable = ['sending', 'queued', 'uncertain'].includes(question.reply?.phase);
      form.dataset.readOnly = String(unavailable);
      if (question.reply?.phase) form.append(make('p', 'muted small', question.reply.message || { sending: '답변을 전달하고 있습니다.', queued: '답변을 접수했습니다.', uncertain: '전달 결과를 확인하지 못했습니다. 터미널에서 확인해주세요.', failed: '답변 전달에 실패했습니다.', cancelled: '대기 입력을 삭제해 답변 전달을 취소했습니다.' }[question.reply.phase] || question.reply.phase));
      const options = make('div', 'question-options');
      const heading = form.querySelector('h4'); heading.id = 'question-heading-' + uuid(); options.setAttribute('role',question.multiSelect ? 'group' : 'radiogroup'); options.setAttribute('aria-labelledby',heading.id);
      for (const option of question.options || []) {
        const label = make('label', 'question-option'), checkbox = make('input'); checkbox.type = question.multiSelect ? 'checkbox' : 'radio'; checkbox.name = 'choice-' + questionKey; checkbox.value = option; checkbox.checked = draft.choices.includes(option); checkbox.disabled = unavailable;
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
        if (value && !unavailable && !send.disabled) void sendQuestionAnswer(questionKey, node.id, { action: 'replyQuestion', sessionID: source.id, questionID: question.id, answer: value }, '답변을 전달했습니다.');
      });
      actions.append(send);
      if (['scheduled', 'paused', 'unavailable'].includes(question.automation?.phase)) {
        const cancel = make('button', 'secondary', '자동 응답 취소'); cancel.type = 'button';
        cancel.addEventListener('click', () => void action(node.id, { action: 'cancelQuestion', sessionID: source.id, questionID: question.id }, '이 질문의 자동 응답을 취소했습니다.')); actions.append(cancel);
      }
      appendQuestionDelivery(form); form.append(actions); $('questions').append(form);
    }
    if (source.pendingSummary && !(source.claudeApprovals || []).length && !(source.queuedQuestions || []).length && !(source.id === session.id && terminalQuestion)) {
      count++; const section = make('div', 'question'); section.append(make('h4', '', source.pendingSummary), make('p', 'muted small', '이 요청은 터미널 화면에서 직접 답해주세요.')); $('questions').append(section);
    }
    if (source.capacityResume) {
      count++; const section = make('div', 'question'); const recovery = source.capacityResume;
      section.append(make('h4', '', `${agents[source.agent]} 이어서 진행`), make('p', 'muted small', `${recovery.reason || '모델 용량 부족'} · ${recovery.limit > 0 ? `${recovery.attempt}/${recovery.limit}` : `${recovery.attempt}번째 시도`} · ${recovery.message}`),make('p','muted small',interruptionStatus(source)));
      if (['scheduled', 'paused'].includes(source.capacityResume.phase)) { const button = make('button', 'secondary', '이어서 진행 취소'); button.addEventListener('click', () => void action(node.id, { action: 'cancelCapacity', sessionID: source.id }, '이어서 진행을 취소했습니다.')); section.append(button); }
      $('questions').append(section);
    }
  }
  show($('past-questions'),past.length>0);
  text($('past-question-count'),`지난 질문·답변 ${past.length}개`);
  $('past-question-list').replaceChildren();
  for (const {key,question,source} of past.slice(-10).reverse()) {
    const row=make('li'), clean=make('button','secondary','질문 정리'); clean.type='button';
    row.append(make('p','',question.title),make('p','muted small',question.reply?.message || '이 질문 이후에 대화가 이어졌습니다. 아직 유효하다면 다시 답변할 수 있습니다.'));
    if(question.reply?.answer) row.append(make('p','past-answer',question.reply.answer));
    if(question.reply?.phase!=='queued') {
      const review=make('button','secondary','답변하기');review.type='button';review.disabled=questionCleanupBusy;
      review.addEventListener('click',()=>{questionReviewKeys.add(questionReviewKey(node,source,question));questionSignature='';renderQuestions();renderInteractions();const form=[...$('questions').querySelectorAll('form')].find(f=>f.dataset.questionKey===questionKeyFor(node,source,question));form?.querySelector('textarea')?.focus();});
      row.append(review);
    }
    clean.setAttribute('aria-label',`${question.title.slice(0,80)} 지난 질문 정리`);
    clean.disabled=questionCleanupBusy || !!question.cleanupToken && !node.online;clean.addEventListener('click',()=>void cleanPastQuestions([key])); row.append(clean); $('past-question-list').append(row);
  }
  $('clear-past-questions').onclick=()=>cleanPastQuestions(past.map(value=>value.key));
  show($('questions-section'), count > 0);
  text($('question-count'), count || '');
  updateInteractionControls();
  updateQuestionCleanupControls();
  if (activeQuestion && wasText) {
    const form = Array.from($('questions').querySelectorAll('form')).find(form => form.dataset.questionKey === activeQuestion);
    const answer = form?.querySelectorAll('textarea')[fieldIndex]; if (answer && !answer.disabled) { answer.focus({ preventScroll: true }); answer.setSelectionRange(selectionStart, selectionEnd); }
  } else if (activeQuestion && activeChoice) {
    const form = Array.from($('questions').querySelectorAll('form')).find(form => form.dataset.questionKey === activeQuestion);
    const choice = Array.from(form?.querySelectorAll('input') || []).find(input=>input.name===activeChoice.name&&input.value===activeChoice.value);
    if (choice && !choice.disabled) choice.focus({preventScroll:true});
  }
}
async function cleanPastQuestions(keys) {
  const chosen=new Set(keys);await cleanQuestionRecords(pastQuestionRecords().filter(record=>chosen.has(record.key)));
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
      input.name = 'question-' + key + '-' + field.id; input.value = option.value ?? option.label; input.checked = current.choices.includes(input.value);
      const description = make('span', '', option.label); if (option.description) description.append(make('span', 'option-description', option.description));
      label.append(input, description); choices.append(label);
    }
    group.append(choices); let answer;
    if (field.allowText !== false) {
      const answerID = 'answer-' + uuid(), label = make('label', 'question-label', field.options?.length ? '직접 답변 또는 추가 설명' : '답변'); label.htmlFor = answerID;
      answer = make('textarea'); answer.id = answerID; answer.name = 'question-answer'; answer.rows = 2; answer.maxLength = 8000; answer.value = current.text; group.append(label,answer);
    }
    form.append(group); controls.push({id:field.id, choices, answer});
  }
  function save() {
    const answers = Object.fromEntries(controls.map(({id,choices,answer}) => [id, {choices:Array.from(choices.querySelectorAll('input:checked')).map(input=>input.value), text:answer?.value || ''}]));
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
    + (source.queuedQuestions || []).filter(item => !['sending','queued'].includes(item.reply?.phase) && !pastQuestionEligible(selectedItem.node,source,item)).length
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
    const found = currentScreenShares().find(item=>item.share.id===link.get('share'));
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
  const terminal = present && selectedItem.session.phase !== 'approval' && !selectedItem.session.pendingInTerminal;
  const queueSupported = codex && supportsRelease(selectedItem.node,[0,2,46,57]);
  const chosenConversation = queueConversations.get(selectedKey), chosenSupported = !chosenConversation || selectedItem && supportsRelease(selectedItem.node,[0,2,51,62]);
  const directMessage = present && !selectedItem.view.pty && !chosenConversation && supportsRelease(selectedItem.node,[0,2,58,73]);
  const routeConnected = connected && selectedItem?.node.online || originalStreamSelected();
  const available = present && routeConnected && chosenSupported && (directMessage ? terminal && terminalFrameFresh() && !latestFrame?.inputReason && (inputKeys().includes('message') || inputKeys().includes('submit') || latestFrame?.streamID && inputKeys().includes('characters') && inputKeys().includes('enter')) : queueSupported || !codex && terminal && (inputKeys().includes('submit') || latestFrame?.streamID && inputKeys().includes('characters')));
  const messageSending = messageBusy(selectedKey), delivery = messageDeliveries.get(selectedKey);
  const uncertain = messageUncertain.has(selectedKey);
  show($('new-message'), uncertain); $('new-message').disabled = messageSending;
  $('message-input').disabled = !present || messageSending || uncertain;
  $('send-message').disabled = !available || mutation || inputInFlight || directSending || directQueue.length>0 || messageSending || uncertain || !$('message-input').value.trim();
  text($('send-message'), messageSending ? '전달 중…' : '메시지 보내기');
  show($('check-message'), uncertain && supportsRelease(selectedItem?.node,[0,2,58,73])); $('check-message').disabled = messageReceiptReads.has(delivery?.requestID);
  show($('use-original-message'), !!chosenConversation && supportsRelease(selectedItem?.node,[0,2,58,73]));
  $('use-original-message').disabled = messageSending;
  const messageError=delivery?.error || (messageCleanupError?.sessionKey===selectedKey ? messageCleanupError.message : '');
  text($('message-status'),delivery?.message || ''); text($('message-error'),messageError); show($('message-error'),!!messageError);
  show($('clear-message-status'),delivery?.phase==='accepted');
  const allArchives=[...messageDeliveries].filter(([key])=>key.startsWith(selectedKey+'#'));
  const archives=allArchives.slice(-10);
  show($('message-history'),archives.length>0);
  text($('message-history-summary'),`이전 메시지 · 전송 상태 ${allArchives.length}개`);
  updateQuestionCleanupControls();
  $('clear-message-history').disabled = !allArchives.some(([,record])=>record.phase!=='busy');
  const undo=messageCleanupUndo?.sessionKey===selectedKey ? messageCleanupUndo : null;
  show($('message-cleanup-result'),!!undo);
  text($('message-cleanup-status'),undo ? `지난 전송 기록 ${undo.entries.length}개를 정리했습니다. 1분 동안 되돌릴 수 있습니다.` : '');
  const archiveSignature=JSON.stringify(archives.map(([key,record])=>[key,record.phase,record.text]));
  if($('message-history-list').dataset.signature!==archiveSignature) {
    $('message-history-list').dataset.signature=archiveSignature; $('message-history-list').replaceChildren();
    for(const [key,record] of archives) {
      const row=make('li'), label=make('p','muted small',record.phase==='accepted' ? '전달 확인' : record.phase==='failed' ? '전송 전 중단' : '전달 결과 미확인');
      const clean=make('button','secondary','기록 정리');clean.type='button';clean.disabled=record.phase==='busy';
      clean.setAttribute('aria-label','지난 메시지 기록 정리');clean.addEventListener('click',()=>cleanMessageRecords([key]));
      row.append(label,make('p','',record.text),clean); $('message-history-list').append(row);
    }
  }
  text($('message-help'), !present ? '목록에서 메시지를 보낼 터미널을 선택해주세요.' : uncertain ? '접수 결과를 확인하고 있습니다. 작성한 메시지는 보관하며 자동으로 다시 보내지 않습니다.' : directMessage ? !terminal ? '원본 터미널의 질문에 먼저 답변해주세요. 초안은 보관합니다.' : !available ? '원본 터미널 연결을 확인해주세요. 초안은 보관합니다.' : '작업 중이거나 대기 중인 같은 원본 터미널에 메시지를 보냅니다.' : codex && !queueSupported ? '메시지 전송은 이 Mac을 AutoApprove 0.2.46 이상으로 업데이트하면 사용할 수 있습니다.' : codex && !chosenSupported ? '선택한 Codex 대화에 메시지를 보내려면 이 Mac을 AutoApprove 0.2.51 이상으로 업데이트해주세요.' : codex && chosenConversation ? `선택한 대화 ‘${chosenConversation.title}’의 메시지 대기열로 전달합니다.` : codex ? '작업 중에도 같은 Codex 대화의 메시지 대기열로 전달합니다.' : !terminal ? '현재 터미널의 질문에 먼저 답변한 뒤 새 메시지를 보내주세요.' : !available ? '원본 터미널 입력 연결을 확인해주세요. 초안은 보관합니다.' : inputKeys().includes('submit') ? '같은 원본 터미널의 입력창에 메시지를 보냅니다.' : '이 원본 연결에서는 한 줄 메시지를 지원합니다.');
  updateQueueControls(); updateScreenSessionControls();
}
function openInteraction() {
  text($('message-status'),''); show($('message-error'),false);
  if (selectedItem) { renderQuestions(); $('message-input').value=messageDrafts.get(selectedKey) || ''; }
  else { show($('questions-section'),false); $('message-input').value=''; }
  renderInteractions(); if (!$('interaction-dialog').open) $('interaction-dialog').showModal();
  void refreshCodexQueue(); void checkPendingMessages();
  if (!$('questions-section').hidden || $('web-question-forms').childElementCount) $('close-interaction').focus();
}
async function submitMessage(event) {
  event.preventDefault(); if ($('send-message').disabled || !selectedItem) return;
  messageCleanupError=null;
  const item = selectedItem, key = selectedKey, value=$('message-input').value; messageDrafts.set(key,value);
  const delivery = {requestID:uuid(),nodeID:item.node.id,sessionID:item.session.id,text:value,phase:'busy',error:'',message:'메시지를 전달하고 있습니다…'};
  messageDeliveries.set(key,delivery); saveMessageDrafts(); updateInteractionControls();
  try {
    const chosen = queueConversations.get(key);
    if (!item.view.pty && !chosen && supportsRelease(item.node,[0,2,58,73])) {
      const result = await api(endpoint('/api/action',item.node.id),{action:'sendMessage',transport:'terminal',sessionID:item.session.id,revision:latestFrame?.revision,streamID:latestFrame?.streamID,text:value,requestID:delivery.requestID});
      delivery.message=result.message || '같은 원본 터미널에 메시지를 전달했습니다.';
    } else if (item.session.agent==='codex') {
      const result=await api(endpoint('/api/action',item.node.id), {action:'sendMessage', sessionID:item.session.id, ...(chosen ? {threadID:chosen.id} : {}), text:value, requestID:delivery.requestID});
      delivery.message=result.message || '메시지 대기열에 등록했습니다.';
    } else {
      if (inputKeys().includes('submit')) {
        if (!await sendInput('submit',value,true)) throw new Error('메시지 전달 결과를 확인하지 못했습니다. 원본 터미널을 확인해주세요.');
      } else {
        if (/[\r\n]/.test(value) || byteLength(value,8000)>8000) throw Object.assign(new Error('이 원본 연결에는 8,000바이트 이내의 한 줄 메시지를 입력해주세요.'), {unsent:true});
        if (!await sendInput('characters',value,true)) throw new Error('메시지 전달 결과를 확인하지 못했습니다. 원본 터미널을 확인해주세요.');
        if (selectedKey!==key || !await freshInputFrame(key) || !await sendInput('enter','',true)) throw new Error('문자는 전달했지만 Enter 전달 결과를 확인하지 못했습니다. 원본 터미널을 확인해주세요.');
      }
      delivery.message='원본 터미널에 메시지를 전달했습니다.';
    }
    acceptMessage(key,delivery); void refreshNetwork();
  } catch (error) {
    delivery.phase = error.unsent || [400,403,404,413].includes(error.status) ? 'failed' : 'uncertain';
    delivery.error=error.message; delivery.message=delivery.phase==='failed' ? '메시지를 보내기 전에 중단됐습니다. 수정하거나 다시 연결한 뒤 보낼 수 있습니다.' : '접수 결과를 확인하고 있습니다…';
    if(delivery.phase==='uncertain') { messageUncertain.add(key); void checkMessageReceipt(key,delivery); }
  } finally { saveMessageDrafts(); updateControls(); }
}
function acceptMessage(key,delivery) {
  key = currentMessageKey(key,delivery); if (!key) return;
  delivery.phase='accepted'; delivery.error=''; messageUncertain.delete(key);
  if(messageDrafts.get(key)===delivery.text)messageDrafts.delete(key);
  if(selectedKey===key && $('message-input').value===delivery.text) $('message-input').value='';
  saveMessageDrafts(); updateInteractionControls();
}
async function checkMessageReceipt(key,delivery) {
  const node=nodes.find(item=>item.id===delivery.nodeID);
  if(!node || !supportsRelease(node,[0,2,58,73]) || document.hidden || messageReceiptReads.has(delivery.requestID) || delivery.phase!=='uncertain')return;
  messageReceiptReads.add(delivery.requestID); updateInteractionControls();
  delivery.receiptChecks=(delivery.receiptChecks || 0)+1;
  try {
    const result=await api(endpoint('/api/receipt',delivery.nodeID)+'&request='+encodeURIComponent(delivery.requestID));
    key=currentMessageKey(key,delivery); if(!key)return;
    if(result.requestID!==delivery.requestID)throw new Error('전송 요청의 접수 결과가 일치하지 않습니다.');
    if(result.phase==='completed') {
      if(result.status>=200 && result.status<300) { delivery.message=result.result?.message || '메시지 접수를 확인했습니다.'; acceptMessage(key,delivery); }
      else if(result.result?.diagnostics?.delivery==='not_started' || [400,403,404,413].includes(result.status)) {
        delivery.phase='failed'; delivery.error=result.result?.error || '메시지가 전송 전에 거부됐습니다.'; delivery.message='전송되지 않은 메시지입니다. 수정하거나 다시 연결한 뒤 보낼 수 있습니다.'; messageUncertain.delete(key);
      } else { delivery.receiptSettled=true; delivery.message='전달 여부를 확인하지 못했습니다. 원본 터미널을 확인해주세요.'; }
    }
  } catch (_) { if(currentMessageKey(key,delivery))delivery.message='연결이 복구되면 접수 결과를 다시 확인합니다. 작성한 메시지는 보관합니다.'; }
  finally { messageReceiptReads.delete(delivery.requestID); saveMessageDrafts(); updateInteractionControls(); scheduleMessageReceipts(); }
}
function currentMessageKey(key,delivery) {
  if(messageDeliveries.get(key)===delivery)return key;
  const archived=key+'#'+delivery.requestID;
  return messageDeliveries.get(archived)===delivery ? archived : null;
}
function commitMessageRecords(next) {
  try { sessionStorage.setItem(messageStorage,JSON.stringify({drafts:Object.fromEntries(messageDrafts),deliveries:Object.fromEntries(next)})); }
  catch (_) {
    const message='메시지 기록 정리를 저장하지 못했습니다. 기록은 유지했습니다.';
    messageCleanupError={sessionKey:selectedKey,message};updateInteractionControls();feedback(message,true);return false;
  }
  messageCleanupError=null;
  messageDeliveries.clear();for(const [key,value] of next)messageDeliveries.set(key,value);
  return true;
}
function cleanMessageRecords(keys) {
  if(!selectedKey)return;
  const entries=keys.filter(key=>key.startsWith(selectedKey+'#') || key===selectedKey && messageDeliveries.get(key)?.phase==='accepted')
    .map(key=>[key,messageDeliveries.get(key)]).filter(([,record])=>record && record.phase!=='busy');
  if(!entries.length)return;
  const next=new Map(messageDeliveries);for(const [key] of entries)next.delete(key);
  if(!commitMessageRecords(next))return;
  for(const [key] of entries)messageUncertain.delete(key);
  messageCleanupUndo={sessionKey:selectedKey,entries};clearTimeout(messageCleanupTimer);
  messageCleanupTimer=setTimeout(()=>{messageCleanupUndo=null;updateInteractionControls();},60000);
  updateInteractionControls();scheduleMessageReceipts();
  $('undo-message-cleanup').focus({preventScroll:true});
}
function undoMessageCleanup() {
  const undo=messageCleanupUndo;if(!undo || undo.sessionKey!==selectedKey)return;
  const next=new Map(messageDeliveries);
  for(const [key,record] of undo.entries) {
    const target=next.has(key) ? undo.sessionKey+'#'+record.requestID : key;
    if(!next.has(target))next.set(target,record);
  }
  if(!commitMessageRecords(next))return;
  for(const [key,record] of next)if(record.phase==='uncertain')messageUncertain.add(key);
  clearTimeout(messageCleanupTimer);messageCleanupUndo=null;updateInteractionControls();scheduleMessageReceipts();
  $('message-input').focus({preventScroll:true});
}
function scheduleMessageReceipts() {
  clearTimeout(messageReceiptTimer);
  if(!document.hidden && [...messageDeliveries.values()].some(value=>value.phase==='uncertain' && !value.receiptSettled && (value.receiptChecks || 0)<15 && supportsRelease(nodes.find(node=>node.id===value.nodeID),[0,2,58,73]))) messageReceiptTimer=setTimeout(checkPendingMessages,2000);
}
async function checkPendingMessages() {
  await Promise.all([...messageDeliveries].filter(([,value])=>value.phase==='uncertain' && !value.receiptSettled && (value.receiptChecks || 0)<15).map(([key,value])=>checkMessageReceipt(key,value)));
  scheduleMessageReceipts();
}
function currentScreenShares(){return nodes.flatMap(node=>(node.state?.screenShares || []).filter(share=>!stoppedScreenShares.has(share.id)).map(share=>({node,share})));}
function forgetTestScreen(id){stoppedScreenShares.add(id);if(stoppedScreenShares.size>64)stoppedScreenShares.delete(stoppedScreenShares.values().next().value);renderTestScreenList();}
function renderTestScreenList() {
  const shares=currentScreenShares();
  text($('screen-count'),shares.length || ''); text($('global-screens'),`화면 공유 ${shares.length}`); show($('global-screens'),shares.length>0); show($('screen-share-picker'),shares.length>1);
  const signature=JSON.stringify(shares.map(({node,share})=>[node.id,node.online,share])); if(signature===screenListSignature)return;
  screenListSignature=signature; $('test-screen-list').replaceChildren();
  if(!shares.length)$('test-screen-list').append(make('p','muted','공유 중인 화면이 없습니다.'));
  for(const {node,share} of shares){const row=make('div','test-screen-row'),info=make('div');info.append(make('strong','',share.title),make('p','muted small',`${node.name} · ${share.source.scope==='display'?'Mac 전체 화면':'Mac 창'} · ${nowLabel(share.expiresAt)}까지`));const open=make('button','secondary','화면 보기');open.disabled=!node.online;open.addEventListener('click',()=>selectTestScreen(node,share));row.append(info,open);$('test-screen-list').append(row);}
  // The selected capture endpoint authoritatively reports expiry/revocation.
  // An inventory timeout must not close a still-authorized image viewer.
}
async function openTestScreens(start = false, requested = null) {
  renderTestScreenList(); if (!$('test-screen-dialog').open) $('test-screen-dialog').showModal();
  screenStartNode = requested?.node || currentNode() || nodes.find(node => node.local && node.online) || nodes.find(node => node.online);
  text($('test-screen-source'), screenStartNode ? `${screenStartNode.name} · Mac 전체 화면 · 보기 전용` : '화면을 공유할 Mac에 연결해주세요.');
  const shares = currentScreenShares().filter(item => item.node.online);
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
    if (result.available === false) {
      text($('queue-count'),''); text($('queue-status'),result.unavailableReason || '이 실행 방식에서는 대기 입력 관리를 지원하지 않습니다. 질문 답변은 원본 터미널로 보낼 수 있습니다.');
      show($('connect-queue-conversation'),false); show($('queue-conversation-picker'),false); return;
    }
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
    if (result.available === false) { text($('queue-status'),result.unavailableReason); show($('connect-queue-conversation'),false); return; }
    $('queue-conversation').replaceChildren(new Option('연결할 대화를 선택해주세요.',''));
    for (const entry of result.items) { const option = new Option(`${entry.title || 'Codex 대화'} · ${entry.id}`,entry.id); option.dataset.title = entry.title || 'Codex 대화'; $('queue-conversation').append(option); }
    show($('queue-conversation-picker'),result.items.length>0); text($('queue-status'),result.items.length ? '원본 Codex의 대화와 일치하는 항목을 선택해주세요. 선택한 대화의 대기 입력을 관리하고 새 메시지를 보냅니다.' : '이 작업 폴더에서 실행 중인 Codex 대화를 찾지 못했습니다. Mac에서 Codex 연결을 확인해주세요.');
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
function screenDraftKey(value=sharedScreen){return value?value.node.id+'/'+value.share.id:'';}
function saveScreenDraft(value=sharedScreen){
  const key=screenDraftKey(value),field=$('screen-control-keyboard');if(!key||!field)return;
  if(field.value)screenControlDrafts.set(key,{text:field.value,expires:value.share.expiresAt});else screenControlDrafts.delete(key);
  for(const [id,draft]of screenControlDrafts)if(Date.parse(draft.expires)<=Date.now()||screenControlDrafts.size>8)screenControlDrafts.delete(id);
}
function renderScreenControl(){
  const button=$('toggle-screen-control');if(!button)return;
  const active=!!screenControl?.active,frame=sharedScreen?.frame,capable=frame?.controlVersion===1;
  const fresh=sharedScreen?.imageAt&&performance.now()-sharedScreen.imageAt<3000&&$('test-screen-image').naturalWidth>0;
  show(button,capable);button.disabled=screenControlBusy||(!active&&(!fresh||tunnelAuthExpired||document.hidden));
  text(button,screenControlBusy?'조작 연결 중…':active?'조작 종료':'조작하기');button.setAttribute('aria-pressed',String(active));
  $('test-screen-dialog').dataset.controlling=String(active);
  show($('screen-control-panel'),active||!!$('screen-control-keyboard').value);$('screen-control-keyboard').readOnly=!active;
  $('screen-send-text').disabled=!active||!$('screen-control-keyboard').value;
  for(const key of document.querySelectorAll('[data-screen-key],#screen-touch-secondary'))key.disabled=!active;
  if(!active){show($('screen-control-quality'),false);$('screen-touch-secondary').setAttribute('aria-pressed','false');}
  text($('screen-control-status'),screenControlBusy?'입력 연결을 확인하고 있습니다…':active?'키보드·마우스 조작 중 · Esc 키로 조작 종료':!sharedScreen&&$('screen-control-keyboard').value?'화면 공유가 종료되었습니다. 아직 보내지 않은 텍스트를 확인하세요.':frame&&!capable?'이 호스트는 보기 전용입니다. Mac을 최신 버전으로 업데이트하면 화면을 조작할 수 있습니다.':$('screen-control-keyboard').value?'아직 보내지 않은 텍스트가 남아 있습니다. 조작을 연결한 뒤 문자 전송을 누르세요.':capable?'보기 전용 · 조작하기를 켜면 키보드·마우스를 사용할 수 있습니다.':'');
  show($('screen-control-status'),!!$('screen-control-status').textContent);
  if(sharedScreen)text($('test-screen-source'),`${sharedScreen.node.name} · ${sharedScreen.share.source.scope==='display'?'Mac 전체 화면':'Mac 창'} · ${active?'조작 중':'보기 전용'}`);
  $('test-screen-image').alt=`공유 중인 Mac 화면. ${active?'키보드·마우스 조작 중':'보기 전용'}`;
  $('test-screen-zoom').setAttribute('aria-label',active?'공유 화면 조작 · Esc로 조작 종료':$('test-screen-image').dataset.zoom==='true'?'공유 화면 맞춤':'공유 화면 확대');
}
function stopScreenControl(){
  screenControlEpoch++;screenControlBusy=false;const previous=screenControl;screenControl=null;
  previous?.stop();saveScreenDraft();renderScreenControl();
}
function loadScreenControl(){
  if(window.AutoApproveScreenControl)return Promise.resolve();if(screenControlModuleTask)return screenControlModuleTask;
  const work=new Promise((resolve,reject)=>{
    const script=document.createElement('script'),timer=setTimeout(()=>finish(Error('화면 조작 도구를 받지 못했습니다. 조작하기를 눌러 다시 시도해주세요.')),8000);
    const finish=error=>{clearTimeout(timer);script.onload=script.onerror=null;if(error){script.remove();reject(error);}else resolve();};
    script.src='/screen-control.js?version='+encodeURIComponent(loadedWebVersion?.version||'')+'&attempt='+uuid();script.async=true;
    script.onload=()=>finish(window.AutoApproveScreenControl?null:Error('화면 조작 도구의 응답을 확인하지 못했습니다. 다시 시도해주세요.'));
    script.onerror=()=>finish(Error('화면 조작 도구를 받지 못했습니다. 연결을 확인하고 다시 시도해주세요.'));document.head.append(script);
  });
  screenControlModuleTask=work;work.finally(()=>{if(screenControlModuleTask===work)screenControlModuleTask=null;}).catch(()=>{});return work;
}
async function toggleScreenControl(){
  if(screenControl?.active){stopScreenControl();$('toggle-screen-control').focus();return;}
  if(screenControlBusy||!sharedScreen||$('toggle-screen-control').disabled)return;
  stopScreenControl();const owner=sharedScreen,epoch=++screenControlEpoch;screenControlBusy=true;show($('screen-control-error'),false);renderScreenControl();
  try{
    await loadScreenControl();if(epoch!==screenControlEpoch||sharedScreen!==owner||!$('test-screen-dialog').open)return;
    const post=async(path,body,options={})=>{
      const url=endpoint(path,owner.node.id);
      if(!options.keepalive)return api(url,body,undefined,5000);
      const reply=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body),keepalive:true,cache:'no-store',credentials:tunnelAccess?'same-origin':'omit'});
      if(!reply.ok)throw Error('화면 조작 연결이 종료되었습니다.');return reply.json();
    };
    const candidate=new window.AutoApproveScreenControl({node:owner.node,share:owner.share,image:$('test-screen-image'),surface:$('test-screen-zoom'),keyboard:$('screen-control-keyboard'),post,
      onState:()=>{if(screenControl===candidate)renderScreenControl();},
      onDraft:value=>{
        const key=screenDraftKey(owner),field=$('screen-control-keyboard');
        if(sharedScreen===owner){field.value=value+field.value;saveScreenDraft(owner);}else screenControlDrafts.set(key,{text:value,expires:owner.share.expiresAt});
      },
      onError:error=>{if(sharedScreen===owner){text($('screen-control-error'),error.message);show($('screen-control-error'),true);renderScreenControl();}},
      onQuality:value=>{if(screenControl===candidate&&candidate.active&&Number.isFinite(value.medianMS)){text($('screen-control-quality'),`${Math.round(value.medianMS)} ms`);$('screen-control-quality').title=`${value.transport} 입력 연결 왕복 · ${value.samples}개 표본`;show($('screen-control-quality'),true);}},
      onExit:()=>{$('toggle-screen-control').focus({preventScroll:true});},
      onDraftChanged:()=>{if(sharedScreen===owner){saveScreenDraft(owner);renderScreenControl();}}
    });
    screenControl=candidate;candidate.frame(owner.frame);await candidate.open();
    if(epoch===screenControlEpoch&&sharedScreen===owner&&candidate.active){clearTimeout(sharedScreenTimer);sharedScreenTimer=setTimeout(readTestScreen,0);}
  }catch(error){if(epoch===screenControlEpoch&&sharedScreen===owner){text($('screen-control-error'),error.message);show($('screen-control-error'),true);}}
  finally{if(epoch===screenControlEpoch){screenControlBusy=false;renderScreenControl();}}
}
function stopTestScreenRead(){stopScreenControl();clearTimeout(sharedScreenTimer);sharedScreenController?.abort();sharedScreenController=null;sharedScreenFailures=0;}
function selectTestScreen(node,share){stopTestScreenRead();sharedScreen={node,share,sessionKey:selectedItem?.node.id===node.id&&['codex','claude'].includes(selectedItem.session.agent)?selectedKey:''};if($('screen-control-keyboard')){$('screen-control-keyboard').value=screenControlDrafts.get(screenDraftKey())?.text||'';show($('screen-control-error'),false);}text($('test-screen-source'),`${node.name} · ${share.source.scope==='display'?'Mac 전체 화면':'Mac 창'} · 보기 전용`);$('test-screen-image').removeAttribute('src');$('test-screen-image').dataset.zoom='false';$('test-screen-zoom').setAttribute('aria-pressed','false');$('test-screen-zoom').setAttribute('aria-label','공유 화면 확대');$('test-screen-zoom').disabled=true;$('stop-test-screen').disabled=false;show($('test-screen-viewer'),true);show($('test-screen-error'),false);updateScreenSessionControls();renderScreenControl();void readTestScreen();}
function updateScreenSessionControls(){
  const key=sharedScreen?.sessionKey,item=key&&allSessions.find(item=>item.key===key);
  const same=item&&selectedKey===key&&item.node.id===sharedScreen.node.id&&item.session.phase!=='ended';
  show($('screen-message'),!!key);$('screen-message').disabled=!same||mutation||!(connected&&item.node.online||same&&originalStreamSelected());
  text($('screen-session-label'),!key?'':!same?'공유를 연 세션이 종료되거나 선택이 바뀌었습니다.':'테스트 지시 · '+agents[item.session.agent]+' · '+item.view.title);
}
async function readTestScreen(){
  if(!sharedScreen||document.hidden||!$('test-screen-dialog').open)return;
  clearTimeout(sharedScreenTimer);if(sharedScreenController)return;
  const current=sharedScreen,controller=new AbortController(),began=performance.now();sharedScreenController=controller;
  const validation=current.validation||={};
  try{const result=await api(endpoint('/api/test-screen',current.node.id)+`&share=${encodeURIComponent(current.share.id)}`,undefined,controller.signal,5000,validation);
    if(sharedScreen!==current||controller.signal.aborted)return;
    const image=result.image;if(result.shareID!==current.share.id||typeof image?.data!=='string'||image.data.length>1000000||!Number.isInteger(image.width)||!Number.isInteger(image.height)||image.width<1||image.height<1||image.width>2048||image.height>2048)throw new Error('공유 화면의 형식이나 크기를 확인하지 못했습니다.');
    sharedScreenFailures=0;current.observedAt=validation.notModified?validation.observedAt:result.observedAt;current.frame=result;
    const element=$('test-screen-image'),reuse=validation.notModified&&current.renderedTag===validation.etag&&element.hasAttribute('src')&&element.complete&&element.naturalWidth>0;
    if(reuse){current.imageAt=performance.now();screenControl?.frame(result);renderScreenControl();}
    else{current.pendingImageTag=validation.etag;element.width=image.width;element.height=image.height;element.src='data:image/jpeg;base64,'+image.data;}
    text($('test-screen-status'),`${current.share.title} · ${nowLabel(current.observedAt)} 갱신 · ${screenControl?.active?'클릭·드래그로 조작':'누르면 확대'}`);show($('test-screen-error'),false);show($('retry-test-screen'),false);
    sharedScreenTimer=setTimeout(readTestScreen,screenControl?.active?Math.max(0,150-(performance.now()-began)):750);
  }catch(error){
    if(controller.signal.aborted||sharedScreen!==current||document.hidden||!$('test-screen-dialog').open||error.name==='AbortError')return;
    stopScreenControl();
    const retry=error.retryable||[408,429,500,502,503,504].includes(error.status);
    text($('test-screen-error'),retry?'Mac 화면 연결이 잠시 끊겼습니다. 자동으로 다시 연결하고 있습니다.':error.message);show($('test-screen-error'),true);show($('retry-test-screen'),error.status!==410);
    if(retry){
      text($('test-screen-status'),current.observedAt?`${current.share.title} · ${nowLabel(current.observedAt)} 마지막 화면 · 다시 연결 중…`:'Mac 화면에 다시 연결하고 있습니다…');
      sharedScreenTimer=setTimeout(readTestScreen,Math.min(3000,500*2**Math.min(sharedScreenFailures++,3)));
    }
    if([403,410].includes(error.status)){$('test-screen-image').removeAttribute('src');$('test-screen-zoom').disabled=true;current.frame=null;current.imageAt=0;if(error.status===410){forgetTestScreen(current.share.id);sharedScreen=null;$('stop-test-screen').disabled=true;updateScreenSessionControls();}renderScreenControl();}
  }
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
$('message-form').addEventListener('submit',submitMessage);$('message-input').addEventListener('input',()=>{if(selectedKey)messageDrafts.set(selectedKey,$('message-input').value);saveMessageDrafts();updateInteractionControls();});
document.addEventListener('visibilitychange',()=>{if(document.hidden)clearTimeout(messageReceiptTimer);else void checkPendingMessages();});
$('check-message').addEventListener('click',()=>{const value=messageDeliveries.get(selectedKey);if(value)void checkMessageReceipt(selectedKey,value);});
$('use-original-message').addEventListener('click',()=>{if(messageBusy(selectedKey))return;queueConversations.delete(selectedKey);updateInteractionControls();});
$('new-message').addEventListener('click',()=>{if(!selectedKey||messageBusy(selectedKey))return;messageUncertain.delete(selectedKey);messageDrafts.delete(selectedKey);const previous=messageDeliveries.get(selectedKey);if(previous)messageDeliveries.set(selectedKey+'#'+previous.requestID,previous);messageDeliveries.delete(selectedKey);$('message-input').value='';saveMessageDrafts();updateInteractionControls();$('message-input').focus();});
$('global-screens').addEventListener('click',()=>void openTestScreens());$('terminal-screens').addEventListener('click',()=>void openTestScreens(true));
$('start-test-screen').addEventListener('click',()=>void startTestScreen());
$('screen-message').addEventListener('click',()=>{updateScreenSessionControls();if($('screen-message').disabled)return;openInteraction();});
$('refresh-queue').addEventListener('click',()=>void refreshCodexQueue());
$('clear-queue').addEventListener('click',()=>{if($('clear-queue').disabled)return;show($('queue-confirm'),true);text($('confirm-clear-queue'),`${Math.min(100,queueSnapshot.items.length)}개 삭제`);text($('queue-status'),'현재 목록의 대기 입력을 삭제합니다. 삭제 후 복원할 수 없습니다. 새로 들어오는 입력은 유지합니다.');$('confirm-clear-queue').focus();});
$('cancel-clear-queue').addEventListener('click',()=>{show($('queue-confirm'),false);text($('queue-status'),'삭제를 취소했습니다.');$('clear-queue').focus();});
$('confirm-clear-queue').addEventListener('click',()=>void clearCodexQueue());
$('close-test-screen').addEventListener('click',()=>$('test-screen-dialog').close());$('test-screen-dialog').addEventListener('close',()=>{stopTestScreenRead();$('test-screen-image').removeAttribute('src');});
$('retry-test-screen').addEventListener('click',()=>void readTestScreen());
$('test-screen-image').addEventListener('load',()=>{$('test-screen-zoom').disabled=false;if(sharedScreen?.frame){sharedScreen.imageAt=performance.now();sharedScreen.renderedTag=sharedScreen.pendingImageTag;screenControl?.frame(sharedScreen.frame);}renderScreenControl();});
$('test-screen-image').addEventListener('error',()=>{if(!$('test-screen-image').hasAttribute('src'))return;stopTestScreenRead();$('test-screen-zoom').disabled=true;text($('test-screen-error'),'공유 이미지를 표시하지 못했습니다. 화면을 다시 연결해주세요.');show($('test-screen-error'),true);show($('retry-test-screen'),true);});
$('test-screen-zoom').addEventListener('click',()=>{if(screenControl?.active)return;const zoom=$('test-screen-image').dataset.zoom!=='true';$('test-screen-image').dataset.zoom=String(zoom);$('test-screen-zoom').setAttribute('aria-pressed',String(zoom));$('test-screen-zoom').setAttribute('aria-label',zoom?'공유 화면 맞춤':'공유 화면 확대');});
$('toggle-screen-control')?.addEventListener('click',()=>void toggleScreenControl());
$('screen-control-keyboard')?.addEventListener('input',()=>queueMicrotask(()=>{saveScreenDraft();renderScreenControl();}));
$('screen-send-text')?.addEventListener('click',()=>{screenControl?.commit();saveScreenDraft();renderScreenControl();});
for(const button of document.querySelectorAll('[data-screen-key]'))button.addEventListener('click',()=>{screenControl?.key(button.dataset.screenKey,Number(button.dataset.screenModifiers||0));if(screenControl?.active&&!matchMedia('(pointer:coarse)').matches)screenControl.focusKeyboard();});
$('screen-touch-secondary')?.addEventListener('click',()=>{if(!screenControl?.active)return;screenControl.rightClick=!screenControl.rightClick;$('screen-touch-secondary').setAttribute('aria-pressed',String(screenControl.rightClick));});
$('stop-test-screen').addEventListener('click',async()=>{if(!sharedScreen||mutation)return;const current=sharedScreen;stopTestScreenRead();if(await action(current.node.id,{action:'stopScreenShare',shareID:current.share.id},'화면 공유를 종료했습니다.')){forgetTestScreen(current.share.id);$('test-screen-image').removeAttribute('src');$('test-screen-zoom').disabled=true;sharedScreen=null;text($('test-screen-status'),'화면 공유가 종료되었습니다.');$('stop-test-screen').disabled=true;updateScreenSessionControls();renderScreenControl();}});
document.addEventListener('visibilitychange',()=>{if(document.hidden){stopTestScreenRead();$('test-screen-image').removeAttribute('src');}else if(sharedScreen&&$('test-screen-dialog').open)void readTestScreen();});
function renderHistory() {
  if (!historyVisible()) { stopSessionHistory(); return; }
  const cached = sessionHistories.get(selectedKey);
  const deferred = selectedItem.node.state.historyDeferred;
  if (deferred && selectedItem.node.online && !cached?.loading && (!cached || Date.now()-cached.at > 5000 && !cached.error)) { void loadSessionHistory(selectedItem); return; }
  const events = historyEvents(selectedItem, deferred ? cached?.events || [] : selectedItem.node.state.snapshot.events || []);
  const loading = deferred && !!cached?.loading, error = deferred && cached?.error;
  $('history').setAttribute('aria-busy', String(loading));
  text($('history-status'), error || (!events.length ? loading ? '처리 내역을 불러오는 중…' : '아직 처리 내역이 없습니다.' : ''));
  $('history-status').className = error ? 'error-text' : 'muted small';
  show($('history-status'), !!error || !events.length);
  show($('history-retry'), !!error); $('history-retry').disabled = loading || !selectedItem.node.online;
  const signature = JSON.stringify(events); if (signature === historySignature) return; historySignature = signature;
  const expanded = new Set(Array.from($('history').querySelectorAll('details[open]')).map(item => item.dataset.id));
  $('history').replaceChildren();
  for (const event of events) {
    const detail = make('details', 'history-item'); detail.dataset.id = event.id; detail.open = expanded.has(event.id);
    detail.append(make('summary', '', `${nowLabel(event.date)} · ${event.outcome}`), make('pre', '', [event.request || event.summary, event.answer ? `답변: ${event.answer}` : '', event.source].filter(Boolean).join('\n\n'))); $('history').append(detail);
  }
}
function historyVisible(item = selectedItem) {
  return !!item && item.key === selectedKey && historyInView && !document.hidden && document.body.classList.contains('detail-open') && !document.body.classList.contains('terminal-focus');
}
function historyEvents(item, events) {
  const members = new Set([item.session.id, ...(item.session.backgroundSessions || []).map(child => child.id)]);
  const matching = [];
  for (const event of events) {
    if (!members.has(event.sessionID) && !members.has(event.originSessionID)) continue;
    matching.push(event); if (matching.length === 12) break;
  }
  return matching;
}
function rememberSessionHistory(key, value) {
  sessionHistories.delete(key); sessionHistories.set(key,value);
  while (sessionHistories.size > 8) sessionHistories.delete(sessionHistories.keys().next().value);
}
function stopSessionHistory() {
  const request = historyRequest; if (!request) return;
  historyRequest = null; request.controller.abort();
  if (sessionHistories.get(request.key) === request.entry) request.entry.loading = false;
  $('history').setAttribute('aria-busy','false');
}
async function loadSessionHistory(item) {
  if (!historyVisible(item) || !item.node.online || historyRequest?.key === item.key) return;
  stopSessionHistory();
  const cached = sessionHistories.get(item.key) || {}, entry = {...cached,loading:true,error:''};
  rememberSessionHistory(item.key,entry);
  const request = {key:item.key,entry,controller:new AbortController()}; historyRequest = request;
  renderHistory();
  try {
    const result = await api(endpoint(supportsRelease(item.node,[0,2,61,76]) ? '/api/history?session='+encodeURIComponent(item.session.id) : '/api/state',item.node.id),undefined,request.controller.signal);
    if (historyRequest !== request || !historyVisible(item)) return;
    rememberSessionHistory(item.key,{events:historyEvents(selectedItem,Array.isArray(result) ? result : result.snapshot?.events || []),loading:false,at:Date.now(),error:''});
  } catch (error) {
    if (historyRequest !== request || request.controller.signal.aborted || !historyVisible(item)) return;
    rememberSessionHistory(item.key,{...cached,loading:false,at:Date.now(),error:'처리 내역을 받지 못했습니다. '+error.message});
  } finally {
    if (historyRequest === request) { historyRequest = null; entry.loading = false; renderHistory(); }
  }
}
$('history-retry').addEventListener('click',()=>void loadSessionHistory(selectedItem));
if ('IntersectionObserver' in window) {
  // Preload just before scrolling into view without synchronous layout reads.
  const observer = new IntersectionObserver(entries=>{
    historyInView = entries[entries.length-1].isIntersecting;
    if (historyVisible()) renderHistory(); else stopSessionHistory();
  },{rootMargin:'160px 0px'});
  observer.observe($('history-section'));
}

$('search').addEventListener('input', renderList); $('node-filter').addEventListener('change', renderList);
$('clean-offline-macs').addEventListener('click',()=>cleanOfflineMacs());
$('clean-warnings').addEventListener('click',()=>cleanWarnings());
$('clean-all-past-questions').addEventListener('click',()=>void cleanQuestionRecords(pastQuestionRecords()));
for(const id of ['global-question-cleanup-undo','question-cleanup-undo'])$(id).addEventListener('click',()=>void undoQuestionCleanup());
$('restore-cleanup').addEventListener('click',()=>{
  if(!saveCleanup({macs:new Set(),warnings:new Set(),questions:new Set()}))return;
  questionSignature='';renderMachines();renderList();if(selectedItem){renderSessionSafety();renderQuestions();}
  feedback('정리한 표시를 다시 불러옵니다.');void refreshNetwork();
});
$('clear-message-status').addEventListener('click',()=>cleanMessageRecords([selectedKey]));
$('clear-message-history').addEventListener('click',()=>cleanMessageRecords([...messageDeliveries.keys()].filter(key=>key.startsWith(selectedKey+'#'))));
$('undo-message-cleanup').addEventListener('click',undoMessageCleanup);
for (const button of document.querySelectorAll('[data-filter]')) button.addEventListener('click', () => {
  filter = button.dataset.filter; for (const option of document.querySelectorAll('[data-filter]')) option.setAttribute('aria-pressed', String(option === button)); renderList();
});
$('automatic').addEventListener('change', () => { const enabled = $('automatic').checked; void action(selectedItem.node.id, { action: 'automatic', sessionID: selectedItem.session.id, enabled }, enabled ? '자동 승인을 켰습니다.' : '자동 승인을 껐습니다.'); });
$('reset-automation').addEventListener('click', () => void resetSelectedAutomation());
$('reset-all-automation').addEventListener('click', () => void resetAllAutomations());
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
$('terminal-settings').addEventListener('toggle', positionTerminalSettings);
$('detail').addEventListener('scroll', positionTerminalSettings, {passive:true});
window.addEventListener('scroll', positionTerminalSettings, {passive:true});
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
  stopSessionHistory();
  stopPTY(); stopTerminalStream(true);
  nativeSessionKey = ''; clearNativeImage();
  stopDirect(); composing = false;
  drafts.set(selectedKey, $('terminal-input').value); const previous = rows.get(selectedKey)?.firstChild;
  selectedKey = ''; selectedItem = null; latestFrame = null; detailGeneration++; frameController?.abort(); clearTimeout(frameTimer);
  terminalFocus(false);
  document.body.classList.remove('detail-open'); history.replaceState(null, '', location.pathname); show($('detail-content'), false); show($('detail-empty'), true); renderList(); previous?.focus();
});
$('refresh').addEventListener('click', () => { void refreshNetwork(false,true); void refreshFrame(); });
$('add-mac').addEventListener('click', () => { show($('add-error'), false); $('add-dialog').showModal(); $('mac-address').focus(); });
$('close-dialog').addEventListener('click', () => $('add-dialog').close());
$('add-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = $('connect-mac'); if (button.disabled) return;
  button.disabled = true; text(button, '연결 중…'); show($('add-error'), false);
  try { const result = await api('/api/peers', { address: $('mac-address').value }); $('add-dialog').close(); feedback(`${result.name}에 연결했습니다.`); await refreshNetwork(); }
  catch (error) { text($('add-error'), error.message); show($('add-error'), true); $('mac-address').focus(); }
  finally { button.disabled = false; text(button, 'Mac 연결'); }
});
function resumeTerminalPage() {
  if (document.hidden) return;
  restoreTerminalWarm();
  void refreshFrame(); void refreshNetwork(false,true);
}
document.addEventListener('visibilitychange', () => {
  clearTimeout(networkTimer); clearTimeout(frameTimer);
  if (document.hidden) { rememberTerminalWarm(); stopSessionHistory(); networkController?.abort(); nativeSessionKey = ''; clearNativeImage(); frameController?.abort(); stopTerminalStream(); latestFrame = null; terminalFrameReceivedAt = -Infinity; stopDirect(); stopPTY(); updateControls(); }
  else resumeTerminalPage();
});
window.addEventListener('pageshow',event=>{ if (event.persisted) resumeTerminalPage(); });
document.addEventListener('resume',resumeTerminalPage);
window.addEventListener('offline', () => {
  terminalNetworkOffline = true;
  if (terminalStream) pauseTerminalNetwork(terminalStream);
});
window.addEventListener('online', () => {
  terminalNetworkOffline = false;
  if (document.hidden) return;
  ptyClient?.resumeNetwork();
  const stream = terminalStream;
  if (stream?.offline || stream?.retryTimer) {
    stream.offline = false; stream.retries = 0;
    clearTimeout(stream.retryTimer); stream.retryTimer = null;
    if (terminalStreamCurrent(stream)) {
      stream.source?.close(); stopTerminalFallback(stream);
      openTerminalStream(stream); void readTerminalFallback(stream);
    }
  }
  void refreshNetwork(false,true); void refreshFrame();
});
window.addEventListener('hashchange', restoreSelection);
let accountModuleLoading,accountUI;
async function openAgentAccounts(id){
  const node=nodes.find(item=>item.id===id);if(!node?.online)return;
  try{
    if(!window.AutoApproveAgentAccounts){
      if(!accountModuleLoading)accountModuleLoading=new Promise((resolve,reject)=>{
        const script=document.createElement('script');script.src='/agent-accounts.js';
        const timer=setTimeout(()=>{script.remove();accountModuleLoading=null;reject(Error('AI 계정 화면을 받지 못했습니다. 다시 눌러주세요.'));},8000);
        script.onload=()=>{clearTimeout(timer);resolve();};script.onerror=()=>{clearTimeout(timer);script.remove();accountModuleLoading=null;reject(Error('AI 계정 화면을 불러오지 못했습니다. 다시 눌러주세요.'));};document.head.append(script);
      });await accountModuleLoading;
    }
    if(!accountUI)accountUI=new window.AutoApproveAgentAccounts({api,endpoint,uuid,launch:async(nodeID,agent,home)=>{
      const result=await api(endpoint('/api/pty',nodeID),{cwd:home,program:agent,automatic:false,columns:80,rows:24,requestID:uuid()});selectPTYDescriptor(nodeID,result,false,true);
    }});
    await accountUI.open(node);
  }catch(error){feedback(error.message,true);}
}
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
function renderCodexProgress(item){
  const session=item?.session,node=item?.node,supported=session?.agent==='codex'&&session.terminal==='terminal'&&supportsRelease(node,[0,2,207,234]);
  show($('codex-progress'),supported);if(!supported)return;
  const state=session.codexProgressRecovery,enabled=node.state.snapshot.codexProgressRecoveryEnabled!==false,busy=['interrupting','waiting','asking'].includes(state?.phase),online=node.online&&connected&&!sessionEnded(item);
  $('codex-progress-enabled').checked=enabled;$('codex-progress-enabled').disabled=!online;
  text($('codex-progress-status'),state?.detail||(enabled?'자동 승인이 켜진 작업에서 진척 신호를 확인합니다.':'이 Mac의 자동 진행 확인이 꺼져 있습니다.'));
  text($('codex-progress-time'),state?`${state.historyAvailable?'출력·대화 기록':'화면 출력'} · 감시 기준 ${new Date(state.lastProgressAt).toLocaleTimeString('ko-KR')} · 확인 ${state.checks}회`:'');
  const permissionWait=(node.state.snapshot.osPermissions?.requests||[]).some(r=>r.phase!=='resolved'&&(!r.sessionID||r.sessionID===session.id));
  $('codex-progress-check').disabled=!online||!enabled||!session.automatic||permissionWait||node.state.snapshot.paused||session.phase!=='working'||busy||['review','requested'].includes(state?.phase);
  const focused=document.activeElement;
  show($('codex-progress-cancel'),busy);$('codex-progress-cancel').disabled=!online;
  if(focused===$('codex-progress-check')&&busy)$('codex-progress-cancel').focus({preventScroll:true});
  else if(focused===$('codex-progress-cancel')&&!busy)$('codex-progress-enabled').focus({preventScroll:true});
}
const osPermissionKinds=[['automation','다른 앱 제어'],['accessibility','손쉬운 사용·기기 제어'],['screenRecording','화면 기록'],['camera','카메라'],['microphone','마이크'],['files','파일·폴더 접근'],['localNetwork','로컬 네트워크'],['fullDiskAccess','전체 디스크 접근'],['appManagement','앱 관리'],['other','기타 OS 접근 권한']];
let osPermissionSignature='';
for(const [kind,title]of osPermissionKinds){
  const label=make('label'),input=document.createElement('input');input.type='checkbox';input.name='osPermissionKind';input.value=kind;input.autocomplete='off';input.id='os-permission-'+kind;
  label.append(input,document.createTextNode(title));$('os-permission-kinds').querySelector('.permission-options').append(label);
  input.addEventListener('change',async()=>{if(!selectedItem)return;const item=selectedItem,restoreFocus=document.activeElement===input,allowed=osPermissionKinds.filter(([key])=>$('os-permission-'+key).checked).map(([key])=>key);
    const pending=action(item.node.id,{action:'osPermissionPolicy',sessionID:item.session.id,allowed},'이 세션의 OS 권한 정책을 저장했습니다.');renderOSPermissions(item);await pending;if(selectedItem)renderOSPermissions(selectedItem);
    if(restoreFocus&&selectedItem?.node.id===item.node.id&&selectedItem?.session.id===item.session.id&&document.activeElement===document.body&&!input.disabled)input.focus({preventScroll:true});
  });
}
function permissionAction(item,payload,message){void action(item.node.id,{...payload,sessionID:item.session.id},message).finally(()=>{if(selectedItem)renderOSPermissions(selectedItem);});renderOSPermissions(item);}
function renderOSPermissions(item){
  const supported=item&&item.session.agent!=='shell'&&supportsRelease(item.node,[0,2,208,235]);show($('os-permissions'),supported);if(!supported)return;
  const {session,node}=item,policy=session.osPermissionPolicy||{allowed:[],targets:[]},status=node.state.snapshot.osPermissions,online=node.online&&connected&&!sessionEnded(item),disabled=!online||mutation;
  text($('os-permission-summary'),policy.allowed.length?`이 세션에서 ${policy.allowed.length}종류 허용 · 등록 앱 ${policy.targets.length}개`:'직접 확인 · 이 세션의 OS 권한 자동 승인이 꺼져 있습니다.');
  text($('os-permission-status'),!online?'Mac 연결이 끊겼습니다. 다시 연결되면 설정을 변경할 수 있습니다.':node.state.snapshot.paused?'전체 일시정지 중에는 OS 권한을 조작하지 않습니다.':status?.detail||'OS 권한 연결을 확인하고 있습니다.');
  for(const [kind]of osPermissionKinds){const input=$('os-permission-'+kind);if(!mutation)input.checked=policy.allowed.includes(kind);input.disabled=disabled;}
  const requests=(status?.requests||[]).filter(r=>(!r.sessionID||r.sessionID===session.id)&&r.phase!=='resolved');
  const signature=JSON.stringify([node.id,session.id,policy.allowed,policy.targets,requests,disabled]);if(signature===osPermissionSignature)return;osPermissionSignature=signature;
  const focused=document.activeElement?.dataset.permissionFocus;
  const targets=$('os-permission-targets');targets.replaceChildren();
  if(!policy.targets.length)targets.append(make('p','muted small','등록한 앱이 없습니다. OS 요청이 나타나면 앱과 내용을 확인해 이 세션에 등록하세요.'));
  for(const target of policy.targets){const row=make('div','permission-target');row.append(make('strong','',target.name),make('p','path',target.path));
    const button=make('button','secondary','등록 해제');button.type='button';button.disabled=disabled;button.dataset.permissionFocus='remove-'+target.id;button.addEventListener('click',()=>permissionAction(item,{action:'removeOSPermissionTarget',targetID:target.id},'이 세션의 등록 앱을 해제했습니다.'));row.append(button);targets.append(row);
  }
  const rows=$('os-permission-requests');rows.replaceChildren();
  for(const request of requests){const row=make('article','permission-request');row.dataset.permissionId=request.id;
    row.append(make('h4','',`${request.requester?.name||'요청 앱 미확인'} · ${request.kind==='authentication'?'Mac 사용자 인증':osPermissionKinds.find(([key])=>key===request.kind)?.[1]||request.kind}`),make('p','',request.detail));
    if(request.requester)row.append(make('p','path',request.requester.path));
    const details=document.createElement('details'),summary=make('summary','','OS 요청 내용');details.append(summary,make('pre','terminal-text',request.content));row.append(details);
    const controls=make('div','question-actions'),token=request.id+'\u0000'+(request.requester?`${request.requester.pid}:${request.requester.started}:${request.requester.id}`:'?');
    const addButton=(title,key,payload,message)=>{const button=make('button','secondary',title);button.type='button';button.disabled=disabled;button.dataset.permissionFocus=key;button.addEventListener('click',()=>permissionAction(item,{...payload,permissionID:request.id,permissionToken:token},message));controls.append(button);};
    if(request.phase==='waiting'&&request.action!=='manual'&&!policy.allowed.includes(request.kind))addButton(`이 세션에서 ${osPermissionKinds.find(([key])=>key===request.kind)?.[1]||request.kind} 허용`,'allow-kind-'+request.id,{action:'osPermissionPolicy',allowed:[...policy.allowed,request.kind]},'이 세션의 해당 OS 권한을 허용했습니다.');
    if(request.phase==='waiting'&&!request.sessionID&&request.requester){addButton('이 요청만 이 세션에 연결','once-'+request.id,{action:'assignOSPermission',remember:false},'현재 요청을 이 세션의 정책에 연결했습니다.');
      const id=request.requester.bundleID,shared=['com.apple.Terminal','com.googlecode.iterm2','com.microsoft.VSCode','com.openai.chat','com.openai.codex','local.autoapprove.mac','com.anthropic.claudefordesktop','com.anthropic.claude','com.google.Chrome','com.google.Chrome.canary','org.mozilla.firefox','com.microsoft.edgemac','com.apple.Safari','com.brave.Browser'].includes(id)||/computer-?use/i.test(id);
      if(!shared)addButton('이 앱을 이 세션에 등록','remember-'+request.id,{action:'assignOSPermission',remember:true},'이 테스트 앱을 현재 세션에 등록했습니다.');
    }
    if(request.sessionID===session.id&&request.phase!=='approving')addButton('Mac에서 처리 완료로 표시','ack-'+request.id,{action:'acknowledgeOSPermission'},'직접 확인한 OS 요청을 처리 완료로 표시했습니다.');
    row.append(controls);rows.append(row);
  }
  if(focused){const next=[...$('os-permissions').querySelectorAll('[data-permission-focus]')].find(e=>e.dataset.permissionFocus===focused);(next||$('os-permission-options').querySelector('summary')).focus({preventScroll:true});}
}
$('codex-progress-enabled').addEventListener('change',()=>{if(selectedItem)void action(selectedItem.node.id,{action:'codexProgressRecovery',enabled:$('codex-progress-enabled').checked},'이 Mac의 Codex 진척 확인 설정을 적용했습니다.');});
for(const [id,name]of [['codex-progress-check','checkCodexProgress'],['codex-progress-cancel','cancelCodexProgress']])$(id).addEventListener('click',()=>{if(selectedItem)void action(selectedItem.node.id,{action:name,sessionID:selectedItem.session.id},name==='checkCodexProgress'?'원래 Codex의 진행 확인을 시작합니다.':'진행 확인을 취소했습니다.');});
$('terminal-history-open').addEventListener('click',()=>void openTerminalHistory());
resetKeyboard();
void refreshNetwork(true);
