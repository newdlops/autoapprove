import { execFileSync, spawn } from 'node:child_process';
import { mkdtemp, readdir, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { coreLinkArguments } from './swift-core-link.mjs';
import { startPTYStreamPeer } from '../Tests/fixtures/pty-stream-peer.mjs';

const build = path.resolve('.build', process.argv.includes('--release') ? 'release' : 'debug');
const root = await mkdtemp(path.join(tmpdir(), 'autoapprove-real-pty-'));
await writeFile(path.join(root,'.zshrc'),"PROMPT='QA> '\n");
const conversationID = randomUUID();
const rolloutDirectory = path.join(root,'.codex/sessions/2026/10/04');
await mkdir(rolloutDirectory,{recursive:true});
const rollout = path.join(rolloutDirectory,'rollout-fixture.jsonl');
await writeFile(rollout,JSON.stringify({type:'session_meta',payload:{id:conversationID,source:'cli'}})+'\n');
execFileSync('/usr/bin/cc',['Tests/fixtures/pty-agent.c','-o',path.join(root,'codex')]);
execFileSync('/usr/bin/cc',['Tests/fixtures/pty-dead-leader.c','-o',path.join(root,'pty-dead-leader')]);
const binary = path.join(root, 'PTYWebPreview');
const screenRaceOnly=process.argv.includes('--screen-close-race-only');
const moduleCache=path.resolve('.build/cache',screenRaceOnly?'PTYCloseRace':'PTYWebPreview');
await mkdir(moduleCache, { recursive: true });
const objects = (await readdir(path.join(build, 'AutoApproveCore.build'))).filter(x => x.endsWith('.swift.o')).map(x => path.join(build, 'AutoApproveCore.build', x));
execFileSync('/usr/bin/xcrun', ['swiftc', '-parse-as-library', '-module-cache-path', moduleCache, '-I', path.join(build, 'Modules'), '-I', path.resolve('Sources/CSQLite'), '-lsqlite3', ...await coreLinkArguments(build), ...objects, screenRaceOnly?'Tests/fixtures/pty-close-race.swift':'Tests/fixtures/pty-web-preview.swift', '-o', binary], { stdio: 'inherit' });
if(screenRaceOnly) {
  try { execFileSync(binary,[root],{stdio:'inherit',timeout:15000}); }
  finally { await rm(root,{recursive:true,force:true}); }
  process.exit(0);
}
const child = spawn(binary, [root], { stdio: ['ignore', 'pipe', 'inherit'], env:{...process.env,AUTOAPPROVE_QA_ROLLOUT:rollout} });
let url,fixtureInfo;
try {
  fixtureInfo = await new Promise((resolve, reject) => {
    let output = ''; const timer = setTimeout(() => reject(new Error('PTY fixture startup timed out')), 15000);
    child.stdout.on('data', data => { output += data; for (const line of output.split('\n')) { try { const item = JSON.parse(line); if (item.url) { clearTimeout(timer); resolve(item); return; } } catch {} } });
    child.on('exit', code => { clearTimeout(timer); reject(new Error('PTY fixture exited ' + code)); });
  });
  url=fixtureInfo.url;
  async function api(route, body, headers = {}) {
    const response = await fetch(url + route, { method: body ? 'POST' : 'GET', headers: { ...(body ? {'Content-Type':'application/json'} : {}), ...headers }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(15000) });
    return { status: response.status, data: await response.json() };
  }
  const startBody = { requestID: randomUUID(), cwd: root, program: 'shell', columns: 80, rows: 24 };
  const created = await api('/api/pty', startBody);
  assert.equal(created.status, 200, 'The browser must be able to create an actual PTY without Accessibility permission');
  assert.ok(created.data.ptyID && created.data.streamID);
  async function streamFor(pty, {client=randomUUID(),node,offset,headers={}}={}) {
    const query = new URLSearchParams({pty:pty.ptyID,stream:pty.streamID,client,...(node?{node}:{}),...(offset==null?{}:{offset:String(offset)})});
    const controller = new AbortController();
    const timer = setTimeout(()=>controller.abort(new Error('SSE response headers timed out')),5000);
    let response;
    try { response = await fetch(url+'/api/pty/stream?'+query,{headers,signal:controller.signal}); } finally { clearTimeout(timer); }
    assert.equal(response.status,200,'The terminal must expose an actual SSE connection');
    assert.match(response.headers.get('content-type')??'',/^text\/event-stream/);
    assert.equal(response.headers.get('content-length'),null,'An SSE connection must have a live response body');
    const reader = response.body.getReader(), decoder = new TextDecoder();
    let buffer='',ended=false;
    return {
      client, close(){controller.abort();},
      async next(timeout=6000) {
        const deadline = setTimeout(()=>controller.abort(new Error('SSE output timed out')),timeout);
        try {
          while(true) {
            const boundary=buffer.indexOf('\n\n');
            if(boundary>=0) {
              const frame=buffer.slice(0,boundary);buffer=buffer.slice(boundary+2);
              const event=frame.split('\n').find(line=>line.startsWith('event:'))?.slice(6).trim();
              if(!event)continue; // SSE heartbeat comment.
              const data=JSON.parse(frame.split('\n').filter(line=>line.startsWith('data:')).map(line=>line.slice(5).trimStart()).join('\n'));
              if(event==='failure')throw new Error(data.error);
              assert.equal(event,'output');
              const id=frame.split('\n').find(line=>line.startsWith('id:'))?.slice(3).trim();
              if(id!=null)assert.equal(Number(id),data.offset);
              return data;
            }
            if(ended)return null;
            const result=await reader.read();ended=result.done;
            if(result.value)buffer+=decoder.decode(result.value,{stream:true});
          }
        } finally {clearTimeout(deadline);}
      }
    };
  }
  async function checkStream(node) {
    const route=path=>path+(node?'?node='+node:'');
    const terminal=(await api(route('/api/pty'),{...startBody,requestID:randomUUID(),program:'codex'})).data;
    const stream=await streamFor(terminal,{node});
    let sequence=0, text='';
    const send=async value=>assert.equal((await api(route('/api/pty/input'),{requestID:randomUUID(),ptyID:terminal.ptyID,streamID:terminal.streamID,clientID:stream.client,sequence:++sequence,data:Buffer.from(value).toString('base64')})).status,200);
    async function until(predicate,timeout=6000){let update;do{update=await stream.next(timeout);assert.ok(update,'Output must be delivered before the stream closes');text+=Buffer.from(update.data,'base64').toString();}while(!predicate(update));return update;}
    try {
      const first=await stream.next();assert.equal(first.reset,true);assert.equal(first.canInput,true);
      await send('LIVE-UTF8=한글😀\r');await until(()=>/RECEIVED:LIVE-UTF8=한글😀\r\n/.test(text));
      const observer=await streamFor(terminal,{node});
      try {
        assert.equal((await observer.next()).canInput,false,'Another browser must observe the active writer lease');
        let available;
        do {available=await observer.next(4500);assert.ok(available);} while(!available.canInput);
        assert.equal(available.canInput,true,'Lease expiry must push updated controls even without PTY output');
      } finally {observer.close();}
      if(!node){
        const held=[];
        try {
          for(let n=0;n<11;n++)held.push(await streamFor(terminal));
          const limited=await api('/api/pty/stream?'+new URLSearchParams({pty:terminal.ptyID,stream:terminal.streamID}));
          assert.equal(limited.status,429,'Concurrent SSE streams must leave capacity for normal requests');
          assert.equal((await api('/api/state')).status,200);
          assert.equal((await fetch(url+'/pty.js')).status,200);
        } finally {held.forEach(item=>item.close());}
        await new Promise(resolve=>setTimeout(resolve,50));
        const invalid='/api/pty/stream?'+new URLSearchParams({pty:terminal.ptyID,stream:randomUUID()});
        assert.equal((await api(invalid)).status,409);
        assert.equal((await api('/api/pty/stream?'+new URLSearchParams({pty:terminal.ptyID,stream:terminal.streamID}),undefined,{Origin:'https://example.com'})).status,403);
        // The old generic HTTP deadline must not terminate an idle event stream.
        await new Promise(resolve=>setTimeout(resolve,31200));
        await send('AFTER-30-SECONDS\r');await until(()=>/RECEIVED:AFTER-30-SECONDS\r\n/.test(text));
      }
      text='';await send('burst\r');
      const final=await until(update=>update.exitCode!=null);
      assert.equal(final.exitCode,7);assert.match(text,/BURST-END\r\n/);
      assert.equal((text.match(/BURST-OUTPUT-/g)??[]).length,2500,'SSE must deliver every buffered final burst chunk before exit');
      assert.equal(await stream.next(),null,'The completed terminal stream must finish after its last output');
      const ended=(await api(route('/api/state'))).data;
      assert.ok(!ended.sessions.some(view=>view.ptyID===terminal.ptyID||view.session.pid===terminal.pid),'A natural exit must immediately leave the active inventory');
      assert.ok(!ended.snapshot.sessions.some(session=>session.pid===terminal.pid&&session.phase!=='ended'),'A natural exit must also retire detected CLI and native active counts');
      console.log('PASS '+(node?'peer':'local')+' pushed SSE bytes, lease expiry, final drain and natural-exit inventory'+(node?'':', bounded connections and idle lifetime'));
    } finally {stream.close();}
  }
  async function checkDeadLeader() {
    const orphanShell=(await api('/api/pty',{...startBody,requestID:randomUUID()})).data;
    await api('/api/pty/input',{requestID:randomUUID(),ptyID:orphanShell.ptyID,streamID:orphanShell.streamID,clientID:randomUUID(),sequence:1,data:Buffer.from(root+'/pty-dead-leader leader | '+root+'/pty-dead-leader member\r').toString('base64')});
    let orphanOffset,orphanText='',orphan;
    for(let n=0;n<30&&!orphan;n++){
      const result=(await api('/api/pty/output?'+new URLSearchParams({pty:orphanShell.ptyID,stream:orphanShell.streamID,...(orphanOffset==null?{}:{offset:String(orphanOffset)})}))).data;
      orphanOffset=result.offset;orphanText+=Buffer.from(result.data,'base64').toString();orphan=orphanText.match(/DEAD-GROUP:(\d+) MEMBER:(\d+) SID:(\d+)/);
    }
    assert.ok(orphan,'The inert foreground group must retain a live member after its leader exits');
    const group=Number(orphan[1]),member=Number(orphan[2]);
    try {
      assert.equal(Number(orphan[3]),orphanShell.pid,'The foreground member belongs to this ManagedPTY session');
      assert.throws(()=>process.kill(group,0),{code:'ESRCH'},'The process group leader must already be gone');
      assert.equal(Number(execFileSync('/bin/ps',['-p',String(member),'-o','tpgid='],{encoding:'utf8'}).trim()),group);
      await api('/api/pty/close',{requestID:randomUUID(),ptyID:orphanShell.ptyID,streamID:orphanShell.streamID});
      await new Promise(resolve=>setTimeout(resolve,500));
      assert.throws(()=>process.kill(member,0),{code:'ESRCH'},'Close must terminate a live foreground member even after its PGID leader exited');
      console.log('PASS bounded close identifies an owned foreground group through a live member');
    } finally {try{process.kill(member,'SIGKILL');}catch{}}
  }
  async function checkClosedInventory() {
    const original=(await api('/api/state')).data.sessions.find(view=>view.title==='기존 대화 · PTY 검증');
    assert.ok(original);
    const body={requestID:randomUUID(),sessionID:original.session.id,reuse:true,conversationID:randomUUID(),columns:80,rows:24};
    const owned=(await api('/api/pty',body)).data;
    let before;
    for(let n=0;n<50;n++) {
      before=(await api('/api/state')).data;
      if(before.sessions.some(view=>view.session.pid===owned.pid&&view.session.agent==='codex'))break;
      await new Promise(resolve=>setTimeout(resolve,100));
    }
    assert.ok(before.sessions.some(view=>view.session.pid===owned.pid&&view.session.agent==='codex'),'The owned CLI must be detected before close');
    assert.equal((await api('/api/pty/close',{requestID:randomUUID(),ptyID:owned.ptyID,streamID:owned.streamID})).status,200);
    const after=(await api('/api/state')).data;
    assert.ok(!after.sessions.some(view=>view.ptyID===owned.ptyID||view.session.pid===owned.pid),'An explicitly closed PTY must leave the active inventory immediately');
    assert.ok(!after.snapshot.sessions.some(session=>session.pid===owned.pid&&session.phase!=='ended'),'The native snapshot must not classify the closed container or CLI as active');
    assert.ok(after.sessions.some(view=>view.session.pid===original.session.pid),'Closing a continuation must preserve the original CLI');
    let screen;
    for(let n=0;n<10;n++) {
      screen=await api('/api/pty/output?'+new URLSearchParams({pty:owned.ptyID,stream:owned.streamID}));
      assert.equal(screen.status,200);
      if(screen.data.exitCode!=null)break;
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    assert.ok(screen.data.exitCode!=null,'The final screen stays available outside the active inventory');
    assert.throws(()=>process.kill(owned.pid,0),{code:'ESRCH'});
    const retained=await api('/api/pty',{...body,requestID:randomUUID()});
    assert.equal(retained.status,200);assert.equal(retained.data.ptyID,owned.ptyID);assert.ok(retained.data.exitCode!=null,'Reopening a closed continuation must not silently launch a new process');
    for(let n=0;n<24;n++) {
      const disposable=(await api('/api/pty',{...startBody,requestID:randomUUID()})).data;
      await api('/api/pty/close',{requestID:randomUUID(),ptyID:disposable.ptyID,streamID:disposable.streamID});
      for(let attempt=0;attempt<20;attempt++) {
        const output=(await api('/api/pty/output?'+new URLSearchParams({pty:disposable.ptyID,stream:disposable.streamID}))).data;
        if(output.exitCode!=null)break;
        await new Promise(resolve=>setTimeout(resolve,50));
      }
    }
    assert.equal((await api('/api/pty/output?'+new URLSearchParams({pty:owned.ptyID,stream:owned.streamID}))).status,404,'The bounded store must evict old completed screens');
    assert.equal((await api('/api/pty',{...body,requestID:randomUUID()})).status,410,'An evicted completed continuation must stay ended rather than start a new CLI');
    console.log('PASS closed PTY leaves active inventory/counts, retains final screen, preserves original and never reforks after history eviction');
  }
  async function checkPeerTransport() {
    const peer=await startPTYStreamPeer((await api('/api/state')).data);
    const route='/api/pty/stream?'+new URLSearchParams({node:peer.nodeID,pty:peer.pty.ptyID,stream:peer.pty.streamID});
    try {
      assert.equal((await api('/api/peers',{address:peer.url})).status,200);
      const fragmented=await streamFor(peer.pty,{node:peer.nodeID});
      try {assert.equal(Buffer.from((await fragmented.next()).data,'base64').toString(),'FRAGMENTED-PEER\r\n');assert.equal(await fragmented.next(),null);}
      finally {fragmented.close();}
      for(const mode of ['incomplete','oversized']){
        peer.setMode(mode);
        const response=await fetch(url+route,{signal:AbortSignal.timeout(5000)});
        assert.equal(response.status,200);
        const text=await response.text();
        assert.match(text,/^event: failure\ndata: \{[^\n]+\}\n\n$/,'A failed peer must produce a complete failure event between output frames');
        const failure=JSON.parse(text.split('\n').find(line=>line.startsWith('data:')).slice(6));
        assert.equal(typeof failure.error,'string');
        assert.equal(failure.retryable,mode==='incomplete','Only transient transport truncation is retryable; oversized output must remain blocked');
        assert.ok(!text.includes('event: output'),'Partial or oversized upstream output must stay inside the bounded peer source');
      }
      peer.setMode('mismatch');assert.equal((await api(route)).status,502,'Changed peer identity must fail before SSE headers');
      peer.setMode('cancel');
      const cancelled=await streamFor(peer.pty,{node:peer.nodeID});await cancelled.next();cancelled.close();
      await peer.waitForStreamClose();
      console.log('PASS peer SSE fragment assembly, frame bounds, clean failure, identity and disconnect cancellation');
    } finally {await peer.stop();}
  }
  if (process.argv.includes('--serve')) {
    console.log(JSON.stringify({ url, root, pty: created.data, conversationID }));
    await new Promise(resolve => process.on('SIGTERM', resolve));
  } else if (process.argv.includes('--peer-transport-only')) {
    await checkPeerTransport();
  } else if (process.argv.includes('--dead-leader-only')) {
    await checkDeadLeader();
  } else if (process.argv.includes('--closed-inventory-only')) {
    await checkClosedInventory();
  } else {
    await checkClosedInventory();
    await checkStream();
    const original=(await api('/api/state')).data.sessions.find(view=>view.title==='기존 대화 · PTY 검증');
    assert.ok(original,'The private fixture must expose its original inert CLI');
    const attach=()=>api('/api/pty',{requestID:randomUUID(),sessionID:original.session.id,reuse:true,columns:80,rows:24});
    const [firstAttach,secondAttach]=await Promise.all([attach(),attach()]);
    assert.equal(firstAttach.status,200,firstAttach.data.error);assert.equal(secondAttach.status,200,secondAttach.data.error);
    assert.equal(firstAttach.data.ptyID,secondAttach.data.ptyID);assert.equal(firstAttach.data.pid,secondAttach.data.pid);
    assert.equal((await attach()).data.ptyID,firstAttach.data.ptyID,'Reopening the same original source must reuse its exact PTY');
    assert.ok((await api('/api/state')).data.sessions.some(view=>view.session.pid===original.session.pid),'Opening a PTY copy must preserve the original CLI');
    const attachments=[firstAttach.data];
    try {
      const changedConversation=randomUUID();
      await writeFile(rollout,JSON.stringify({type:'session_meta',payload:{id:changedConversation,source:'cli'}})+'\n');
      const changed=await attach();assert.equal(changed.status,200,changed.data.error);attachments.push(changed.data);
      assert.notEqual(changed.data.ptyID,firstAttach.data.ptyID,'A changed conversation on the same source PID requires its own PTY');
      assert.notEqual(changed.data.pid,firstAttach.data.pid);
      let changedText='',changedOffset;
      for(let n=0;n<20&&!changedText.includes('RESUMED-ID:'+changedConversation);n++){
        const response=await api('/api/pty/output?'+new URLSearchParams({pty:changed.data.ptyID,stream:changed.data.streamID,...(changedOffset==null?{}:{offset:String(changedOffset)})}));
        assert.equal(response.status,200,response.data.error);changedOffset=response.data.offset;changedText+=Buffer.from(response.data.data,'base64').toString();
      }
      assert.ok(changedText.includes('RESUMED-ID:'+changedConversation),'The copied CLI must resume the newly observed exact conversation');
      const explicit=await api('/api/pty',{requestID:randomUUID(),sessionID:original.session.id,reuse:true,conversationID:randomUUID(),columns:80,rows:24});
      assert.equal(explicit.status,200,explicit.data.error);attachments.push(explicit.data);
      assert.notEqual(explicit.data.ptyID,changed.data.ptyID,'An explicit different conversation cannot reuse another conversation PTY');
    } finally {
      for(const item of attachments)await api('/api/pty/close',{requestID:randomUUID(),ptyID:item.ptyID,streamID:item.streamID});
      await writeFile(rollout,JSON.stringify({type:'session_meta',payload:{id:conversationID,source:'cli'}})+'\n');
    }
    console.log('PASS simultaneous attach reuse and exact conversation identity on a changing source PID');
    const pty = created.data, client = randomUUID(); let sequence = 0, offset, received = '';
    const sendBody = text => ({ requestID:randomUUID(), ptyID:pty.ptyID, streamID:pty.streamID, clientID:client, sequence:++sequence, data:Buffer.from(text).toString('base64') });
    async function input(text) { const body = sendBody(text); const response = await api('/api/pty/input', body); assert.equal(response.status,200,response.data.error); return body; }
    async function read() {
      const query = new URLSearchParams({pty:pty.ptyID,stream:pty.streamID,...(offset===undefined?{}:{offset:String(offset)})});
      const response = await api('/api/pty/output?' + query); assert.equal(response.status,200,response.data.error);
      offset = response.data.offset; received += Buffer.from(response.data.data,'base64').toString('utf8'); return response.data;
    }
    async function until(pattern) { const deadline=Date.now()+7000; while(!pattern.test(received)&&Date.now()<deadline) await read(); assert.match(received,pattern); }
    await read();
    await input("printf '\\033[31mPTY-RED\\033[0m\\nUTF8=한글😀\\n'\r");
    await until(/\x1b\[31mPTY-RED\x1b\[0m\r?\nUTF8=한글😀/);
    console.log('PASS actual PTY output preserves ANSI and UTF-8');
    received='';
    // Editing happens in zsh's real line editor, not a web compose field.
    await input("printf 'AB\\n'"); await input('\x1b[D\x1b[D\x1b[D\x1b[D');
    await input('X'); await input('\r');
    await until(/AXB/); console.log('PASS direct characters and cursor editing');
    const duplicate = await input("printf 'ONCE-MARK\\n'\r");
    assert.equal((await api('/api/pty/input',duplicate)).status,200);
    const reused = {...duplicate,requestID:randomUUID()}; assert.equal((await api('/api/pty/input',reused)).status,409);
    const wrongStream = {...sendBody('NO-WRONG-STREAM'),streamID:randomUUID()}; assert.equal((await api('/api/pty/input',wrongStream)).status,409); sequence--;
    const foreign = {...sendBody('NO-OTHER-WRITER'),clientID:randomUUID(),sequence:1}; assert.equal((await api('/api/pty/input',foreign)).status,409); sequence--;
    const crossOrigin = {...sendBody('NO-CROSS-ORIGIN')}; assert.equal((await api('/api/pty/input',crossOrigin, {Origin:'https://example.com'})).status,403); sequence--;
    await until(/ONCE-MARK\r?\n/);
    console.log('PASS duplicate receipts, stream identity, sequence, writer and origin isolation');
    assert.equal((await api('/api/pty/resize',{requestID:randomUUID(),ptyID:pty.ptyID,streamID:pty.streamID,clientID:client,columns:52,rows:19})).status,200);
    received=''; await input("stty size\r"); await until(/19 52\r?\n/);
    received=''; await input("printf '\\033[2J\\033[HRESTORED-CURRENT\\033[2;5H'\r"); await until(/RESTORED-CURRENT/);
    const savedOffset = offset; offset=undefined; const restored = await read(); assert.equal(restored.reset,true); assert.match(Buffer.from(restored.data,'base64').toString(),/RESTORED-CURRENT/); assert.equal(restored.columns,52); assert.ok(restored.offset>=savedOffset);
    console.log('PASS real TIOCSWINSZ and current-screen recovery');
    const second = await api('/api/pty',{...startBody,requestID:randomUUID()}); assert.equal(second.status,200);
    const isolated = await api('/api/pty/output?'+new URLSearchParams({pty:second.data.ptyID,stream:second.data.streamID}));
    assert.ok(!Buffer.from(isolated.data.data,'base64').toString().includes('RESTORED-CURRENT'));
    await api('/api/pty/close',{requestID:randomUUID(),ptyID:second.data.ptyID,streamID:second.data.streamID});
    received=''; await input('sleep 30\r'); await new Promise(resolve=>setTimeout(resolve,200)); await input('\x03'); await input("printf 'AFTER-INTERRUPT\\n'\r"); await until(/AFTER-INTERRUPT\r?\n/);
    console.log('PASS PTY separation and Ctrl C foreground signal');
    await input('yes PTY-FLOOD\r');await new Promise(resolve=>setTimeout(resolve,250));
    const interruptStarted=Date.now();await input('\x03');assert.ok(Date.now()-interruptStarted<2000,'Continuous output must allow prompt Ctrl C');
    received='';await input("printf 'AFTER-FLOOD\\n'\r");await until(/(?:\r?\n|\x1b\[0m)AFTER-FLOOD(?:\r?\n|\s{2,})/);
    console.log('PASS continuous output remains interruptible');
    await input('exit 7\r'); let ended;
    for(let attempt=0;attempt<20;attempt++){ ended=await read(); if(ended.exitCode!=null)break; }
    assert.equal(ended.exitCode,7); assert.equal((await api('/api/pty/input',sendBody('NO-AFTER-EXIT'))).status,409);
    console.log('PASS process exit and post-exit input rejection');
    const burst=(await api('/api/pty',{...startBody,requestID:randomUUID(),program:'codex'})).data;
    let burstOffset=(await api('/api/pty/output?'+new URLSearchParams({pty:burst.ptyID,stream:burst.streamID}))).data.offset;
    await api('/api/pty/input',{requestID:randomUUID(),ptyID:burst.ptyID,streamID:burst.streamID,clientID:randomUUID(),sequence:1,data:Buffer.from('burst\r').toString('base64')});
    await new Promise(resolve=>setTimeout(resolve,600));
    let burstText='',final;
    for(let n=0;n<30;n++){
      final=(await api('/api/pty/output?'+new URLSearchParams({pty:burst.ptyID,stream:burst.streamID,offset:String(burstOffset)}))).data;
      burstOffset=final.offset;burstText+=Buffer.from(final.data,'base64').toString();if(final.exitCode!=null)break;
    }
    assert.equal(final.exitCode,7);assert.match(burstText,/BURST-END\r\n/,'Completion must follow the last output chunk');
    console.log('PASS final burst is fully drained before reporting exit');
    const stubborn=(await api('/api/pty',{...startBody,requestID:randomUUID(),program:'codex'})).data;
    await api('/api/pty/input',{requestID:randomUUID(),ptyID:stubborn.ptyID,streamID:stubborn.streamID,clientID:randomUUID(),sequence:1,data:Buffer.from('ignore-hup\r').toString('base64')});
    let stubbornOffset,stubbornText='';
    for(let n=0;n<20&&!stubbornText.includes('IGNORING-HUP');n++){
      const result=(await api('/api/pty/output?'+new URLSearchParams({pty:stubborn.ptyID,stream:stubborn.streamID,...(stubbornOffset==null?{}:{offset:String(stubbornOffset)})}))).data;
      stubbornOffset=result.offset;stubbornText+=Buffer.from(result.data,'base64').toString();
    }
    assert.match(stubbornText,/IGNORING-HUP/);
    await api('/api/pty/close',{requestID:randomUUID(),ptyID:stubborn.ptyID,streamID:stubborn.streamID});
    let terminated;
    for(let n=0;n<30;n++){
      terminated=(await api('/api/pty/output?'+new URLSearchParams({pty:stubborn.ptyID,stream:stubborn.streamID,offset:String(stubbornOffset)}))).data;
      stubbornOffset=terminated.offset;if(terminated.exitCode!=null)break;
      await new Promise(resolve=>setTimeout(resolve,50));
    }
    assert.ok(terminated.exitCode!=null,'Explicit close must reap a child ignoring HUP');
    const replacement=(await api('/api/pty',{...startBody,requestID:randomUUID()})).data;
    await new Promise(resolve=>setTimeout(resolve,200));
    const inventory=(await api('/api/state')).data.sessions;
    assert.ok(!inventory.some(view=>view.ptyID===stubborn.ptyID),'A closed PTY must not remain an active container');
    assert.equal(inventory.find(view=>view.session.id==='pty:'+replacement.ptyID)?.ptyID,replacement.ptyID,'A reused TTY must keep exact PTY identity');
    console.log('PASS bounded close, reaping and exact container identity');
    const childShell=(await api('/api/pty',{...startBody,requestID:randomUUID()})).data;
    await api('/api/pty/input',{requestID:randomUUID(),ptyID:childShell.ptyID,streamID:childShell.streamID,clientID:randomUUID(),sequence:1,data:Buffer.from(root+'/codex --ignore-hup\r').toString('base64')});
    let childPID,childOffset,childText='';
    for(let n=0;n<20&&!childPID;n++){
      const result=(await api('/api/pty/output?'+new URLSearchParams({pty:childShell.ptyID,stream:childShell.streamID,...(childOffset==null?{}:{offset:String(childOffset)})}))).data;
      childOffset=result.offset;childText+=Buffer.from(result.data,'base64').toString();childPID=Number(childText.match(/CHILD-PID:(\d+)/)?.[1])||null;
    }
    assert.ok(childPID&&childPID!==childShell.pid,'The foreground job has its own process group');
    await api('/api/pty/close',{requestID:randomUUID(),ptyID:childShell.ptyID,streamID:childShell.streamID});
    await new Promise(resolve=>setTimeout(resolve,500));
    assert.throws(()=>process.kill(childPID,0),{code:'ESRCH'},'Closing the shell must also finish its HUP-ignoring foreground child');
    console.log('PASS owned foreground child is terminated with its shell');
    await checkDeadLeader();
    assert.equal((await api('/api/peers',{address:fixtureInfo.peerURL})).status,200);
    await checkStream(fixtureInfo.peerID);
    const relayed=(await api('/api/pty?node='+fixtureInfo.peerID,{...startBody,requestID:randomUUID()}));assert.equal(relayed.status,200);
    const remote=relayed.data,remoteClient=randomUUID();
    assert.equal((await api('/api/pty/input?node='+fixtureInfo.peerID,{requestID:randomUUID(),ptyID:remote.ptyID,streamID:remote.streamID,clientID:remoteClient,sequence:1,data:Buffer.from("printf 'PEER-PTY-MARK\\n'\r").toString('base64')})).status,200);
    let remoteText='',remoteOffset;
    for(let n=0;n<20&&!/PEER-PTY-MARK(?:\r?\n|\s{2,})/.test(remoteText);n++){
      const response=await api('/api/pty/output?'+new URLSearchParams({node:fixtureInfo.peerID,pty:remote.ptyID,stream:remote.streamID,client:remoteClient,...(remoteOffset==null?{}:{offset:String(remoteOffset)})}));assert.equal(response.status,200);
      remoteOffset=response.data.offset;remoteText+=Buffer.from(response.data.data,'base64').toString();
    }
    assert.match(remoteText,/PEER-PTY-MARK(?:\r?\n|\s{2,})/);
    assert.equal((await api('/api/pty/close?node='+fixtureInfo.peerID,{requestID:randomUUID(),ptyID:remote.ptyID,streamID:remote.streamID})).status,200);
    console.log('PASS cross-Mac PTY creation, byte input/output and close through the gateway');
    await checkPeerTransport();
  }
} finally {
  child.kill('SIGTERM'); await new Promise(resolve => { if (child.exitCode !== null || child.signalCode !== null) resolve(); else child.once('exit', resolve); });
  await rm(root, { recursive: true, force: true });
}
