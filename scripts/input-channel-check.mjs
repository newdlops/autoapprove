// Transport faults and bounded acknowledgement windows, without user data.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFile} from 'node:fs/promises';
import {performance} from 'node:perf_hooks';

const source=await readFile('Sources/AutoApproveCore/Resources/RemoteWeb/input-channel.js','utf8');
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const until=async(predicate)=>{const end=performance.now()+3000;while(!predicate()){assert.ok(performance.now()<end,'transport condition timed out');await sleep(2);}};
const summary=values=>{const sorted=values.toSorted((a,b)=>a-b);return {median:sorted[Math.ceil(sorted.length*.5)-1],p95:sorted[Math.ceil(sorted.length*.95)-1]};};
const checks=[],instances=[];

function fixture({rtt=0,hold=false,bindStatus=200}={}){
  const sockets=[],accepted=[],attempts=[],quality=[],failures=[];
  let Channel;
  class Socket{
    static OPEN=1;
    constructor(){this.readyState=0;this.bufferedAmount=0;sockets.push(this);queueMicrotask(()=>{if(this.readyState===3)return;this.readyState=1;this.onopen?.();});}
    emit(kind,sequence=0,payload=new Uint8Array()){if(this.readyState===1)this.onmessage?.({data:Channel.packet(kind,sequence,payload).buffer});}
    send(value){
      const bytes=new Uint8Array(value),sequence=new DataView(bytes.buffer,bytes.byteOffset,bytes.length).getUint32(4),kind=bytes[3],payload=bytes.slice(8);
      assert.deepEqual([...bytes.slice(0,3)],[65,73,1]);
      if(kind===0){assert.equal(sequence,0);assert.equal(JSON.parse(new TextDecoder().decode(payload)).mode,'pty');queueMicrotask(()=>this.emit(bindStatus===200?1:5,0,bindStatus===200?new Uint8Array():new TextEncoder().encode(JSON.stringify({status:bindStatus,message:'binding rejected'}))));return;}
      if(kind===6){setTimeout(()=>this.emit(7,0,payload),rtt);return;}
      assert.equal(kind,2);attempts.push({sequence,payload,sent:performance.now()});
      setTimeout(()=>{accepted.push({sequence,payload,at:performance.now()});if(!hold)setTimeout(()=>this.emit(4,sequence),rtt/2);},rtt/2);
    }
    close(){this.readyState=3;queueMicrotask(()=>this.onclose?.());}
    break(){this.readyState=3;this.onclose?.();this.onerror?.();}
  }
  const context={window:{},location:new URL('https://fixture.invalid/'),WebSocket:Socket,URL,TextEncoder,TextDecoder,Uint8Array,ArrayBuffer,DataView,performance,queueMicrotask,setTimeout,clearTimeout,setInterval,clearInterval};
  vm.runInNewContext(source,context);Channel=context.window.AutoApproveInputChannel;
  const channel=new Channel('fixture-node',{mode:'pty',ptyID:'fixture-pty',streamID:'fixture-stream',clientID:'fixture-client',sequenceBase:0},{onQuality:value=>quality.push(value),onFailure:error=>failures.push(error.message)});
  instances.push(channel);return {channel,sockets,accepted,attempts,quality,failures};
}

try{
  const a=fixture({hold:true});assert.equal(await a.channel.open(),a.channel);
  for(let i=0;i<16;i++)assert.equal(a.channel.send(2,new Uint8Array([i])),true);
  assert.equal(a.channel.canSend(1),false);assert.equal(a.channel.pendingCount,16);assert.equal(a.channel.pendingBytes,16);
  a.sockets[0].emit(4,16);assert.equal(a.channel.pendingCount,0);assert.equal(a.channel.pendingBytes,0);assert.equal(a.attempts.length,16);
  const payload=new Uint8Array(16000);
  for(let i=0;i<4;i++)assert.equal(a.channel.send(2,payload),true);
  assert.equal(a.channel.pendingBytes,64000);assert.equal(a.channel.canSend(1),false);
  a.sockets[0].emit(4,18);assert.equal(a.channel.pendingBytes,32000);assert.equal(a.channel.canSend(16000),true);
  a.channel.close();checks.push('16-message/64KB windows, cumulative acknowledgements and bounded pending metadata');

  const b=fixture({hold:true});await b.channel.open();b.channel.send(2,new TextEncoder().encode('한글😀\x1b[D'));
  await until(()=>b.accepted.length===1);b.sockets[0].break();await sleep(10);
  assert.equal(b.failures.length,1);assert.equal(b.channel.pendingCount,1);assert.equal(b.sockets.length,1);assert.equal(b.attempts.length,1);
  assert.equal(b.channel.send(2,new Uint8Array([1])),false);await sleep(30);assert.equal(b.attempts.length,1);
  checks.push('accepted input with lost ACK closes once, preserves uncertainty and never reconnects or replays');

  const old=fixture({bindStatus:404});assert.equal(await old.channel.open(),null);assert.equal(old.attempts.length,0);assert.equal(old.failures.length,0);
  const wrong=fixture({bindStatus:409});await assert.rejects(wrong.channel.open(),/binding rejected/);assert.equal(wrong.attempts.length,0);
  const bad=fixture({hold:true});await bad.channel.open();bad.channel.send(2,new Uint8Array([1]));bad.sockets[0].emit(4,2);await sleep(5);assert.equal(bad.channel.state,'closed');assert.equal(bad.attempts.length,1);
  checks.push('legacy fallback before writes; identity/binding failures and impossible acknowledgements fail closed');

  const rtt=200,duplex=fixture({rtt}),nativeTimes=new Map(),legacyTimes=new Map(),legacyAccepted=[],queued=[];
  await duplex.channel.open();let sending=false;
  function drainLegacy(){
    if(sending||!queued.length)return;sending=true;const batch=queued.splice(0);
    setTimeout(()=>{for(const id of batch)legacyAccepted.push({id,at:performance.now()});},rtt/2);
    setTimeout(()=>{sending=false;drainLegacy();},rtt);
  }
  for(let id=0;id<12;id++){
    nativeTimes.set(id,performance.now());assert.equal(duplex.channel.send(2,new Uint8Array([id])),true);
    legacyTimes.set(id,performance.now());queued.push(id);drainLegacy();await sleep(20);
  }
  await until(()=>duplex.accepted.length===12&&legacyAccepted.length===12&&duplex.channel.pendingCount===0);
  assert.deepEqual(duplex.accepted.map(value=>value.payload[0]),Array.from({length:12},(_,i)=>i));
  const continuous=summary(duplex.accepted.map(value=>value.at-nativeTimes.get(value.payload[0]))),serial=summary(legacyAccepted.map(value=>value.at-legacyTimes.get(value.id)));
  assert.ok(continuous.median+40<serial.median,JSON.stringify({continuous,serial}));assert.ok(continuous.p95+80<serial.p95);
  checks.push('200ms RTT typing simulation reduces queued-key delay while preserving byte order');
  console.log(JSON.stringify({passed:true,checks,simulatedRTTMS:rtt,keyToReceiverMS:{duplex:continuous,serialHTTP:serial},scope:'Browser protocol simulation; real Swift/PTY/Workers checks are separate.'},null,2));
}finally{for(const channel of instances)channel.close();}
