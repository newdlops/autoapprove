// Production native browser queue and transport, with a serial 400ms receiver.
// No browser, actual socket, Terminal automation or user input is used.
import assert from 'node:assert/strict';
import vm from 'node:vm';
import {readFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
const baseline=process.argv.includes('--baseline');
const source=name=>baseline?execFileSync('git',['show','v0.2.264:Sources/AutoApproveCore/Resources/RemoteWeb/'+name],{encoding:'utf8'}):readFileSync('Sources/AutoApproveCore/Resources/RemoteWeb/'+name,'utf8');
const app=source('app.js'),channel=source('input-channel.js');
function fixture({hold=false}={}) {
  let now=0,next=0,busyUntil=0,Channel;const timers=new Map(),writes=[],quality=[],failures=[];
  const later=(fn,delay,repeat=0)=>{const id=++next;timers.set(id,{fn,due:now+delay,repeat});return id;};
  const flush=async()=>{for(let n=0;n<12;n++)await Promise.resolve();};
  async function advance(ms) {const end=now+ms;for(let n=0;n<10000;n++) {const item=[...timers].filter(([,t])=>t.due<=end).sort((a,b)=>a[1].due-b[1].due)[0];if(!item)break;const[id,t]=item;now=t.due;if(t.repeat)t.due+=t.repeat;else timers.delete(id);t.fn();await flush();}now=end;await flush();}
  class Socket {
    static OPEN=1;
    constructor(){this.readyState=1;this.bufferedAmount=0;queueMicrotask(()=>this.onopen?.());}
    emit(kind,sequence=0,payload=new Uint8Array()){this.onmessage?.({data:Channel.packet(kind,sequence,payload).buffer});}
    send(bytes){const kind=bytes[3],sequence=new DataView(bytes.buffer).getUint32(4),payload=bytes.slice(8);
      if(kind===0){queueMicrotask(()=>this.emit(1));return;}
      if(kind===6){queueMicrotask(()=>this.emit(7,0,payload));return;}
      assert.equal(kind,3);const inputKind=Channel.keys[payload[0]],text=new TextDecoder().decode(payload.slice(1));
      writes.push({kind:inputKind,text,sequence,sent:now});busyUntil=Math.max(busyUntil,now)+400;
      if(!hold)later(()=>this.emit(4,sequence),busyUntil-now);
    }
    close(){this.readyState=3;}
    break(){this.readyState=3;this.onclose?.();}
  }
  const elements={'terminal-input':{value:''},'terminal-keyboard':{disabled:false,blur(){}}};
  const context={window:{},document:{activeElement:null},location:new URL('http://fixture.invalid/'),URL,WebSocket:Socket,
    TextEncoder,TextDecoder,Uint8Array,ArrayBuffer,DataView,queueMicrotask,performance:{now:()=>now},
    setTimeout:(fn,ms)=>later(fn,ms),clearTimeout:id=>timers.delete(id),setInterval:(fn,ms)=>later(fn,ms,ms),clearInterval:id=>timers.delete(id),
    directMode:true,directSending:false,directTimer:null,directTimerDue:Infinity,directQueue:[],directChannel:null,directCandidate:null,
    directChannelState:'ready',directChannelRetry:null,directChannelRetries:0,directChannelStreamID:'stream',directFreshening:false,
    selectedKey:'source',latestFrame:{streamID:'stream'},inputGeneration:0,inputFailure:'',mutation:false,directStreamID:'stream',composing:false,
    drafts:new Map(),composePreferred:false,$:id=>elements[id],messageBusy:()=>false,terminalFrameFresh:()=>true,
    byteLength:(text)=>Buffer.byteLength(text),inputKeys:()=>Channel.keys,keyboardText:()=>'',resetKeyboard(){},sizeInput(){},
    inputQuality(){},updateControls(){},freshInputFrame:async()=>true,prepareDirectChannel(){throw Error('Unexpected reconnect');}};
  vm.createContext(context);vm.runInContext(channel,context);Channel=context.window.AutoApproveInputChannel;
  vm.runInContext(app.slice(app.indexOf('function restoreDirectDraft('),app.indexOf('function armDirect('))+
    app.slice(app.indexOf('function queueDirect('),app.indexOf('function captureDirectText(')),context);
  const client=new Channel('source',{mode:'native'},{onChange:()=>{context.directSending=client.pendingCount>0;if(context.directMode&&context.directQueue.length)context.scheduleDirect(0);},
    onQuality:q=>quality.push(q),onFailure:error=>{failures.push(error);context.stopDirect();}});
  context.directChannel=client;
  return {context,client,writes,quality,failures,advance,async open(){await client.open();await flush();},type:(kind,text='')=>context.queueDirect(kind,text),get now(){return now;}};
}
const burst=fixture();await burst.open();
const text='abcdefghijklmnopqrstuvwxyz0123456789'.repeat(2);
for(const char of text){assert.equal(burst.type('characters',char),true);await burst.advance(25);}
await burst.advance(32000);
assert.equal(burst.writes.map(w=>w.text).join(''),text);assert.equal(burst.client.pendingCount,0);assert.equal(burst.context.directQueue.length,0);
const result=burst.quality.at(-1),requests=burst.writes.length;
if(baseline)assert.ok(result.p95MS>2000);else {assert.ok(requests<=7);assert.ok(result.p95MS<1200);assert.ok(result.medianMS>=400);assert.equal(burst.failures.length,0);}
burst.client.close();
if(!baseline) {
  const ordered=fixture();await ordered.open();ordered.type('characters','A');await ordered.advance(0);
  ordered.type('characters','한');ordered.type('characters','😀');ordered.type('left');ordered.type('characters','B');ordered.type('backspace');ordered.type('characters','C');
  await ordered.advance(4000);
  assert.deepEqual(ordered.writes.map(({kind,text})=>[kind,text]),[['characters','A'],['characters','한😀'],['left',''],['characters','B'],['backspace',''],['characters','C']]);
  const measured=ordered.quality.at(-1);await ordered.advance(30000);assert.deepEqual(ordered.quality.at(-1),measured,'Idle pings must not replace real input samples');ordered.client.close();
  const uncertain=fixture({hold:true});await uncertain.open();uncertain.type('characters','UNCERTAIN');await uncertain.advance(0);uncertain.type('characters','PRESERVE');
  uncertain.client.socket.break();await uncertain.advance(20000);assert.equal(uncertain.writes.length,1);assert.equal(uncertain.context.drafts.get('source'),'PRESERVE');assert.equal(uncertain.failures.length,1);
  const changed=fixture({hold:true});await changed.open();changed.type('characters','A');await changed.advance(0);changed.type('characters','B');changed.context.latestFrame.streamID='changed';changed.client.socket.emit(4,1);await changed.advance(0);
  assert.equal(changed.writes.length,1);assert.equal(changed.context.directMode,false);assert.equal(changed.context.drafts.get('source'),'B');
  const bounded=fixture({hold:true});await bounded.open();bounded.type('characters','A');await bounded.advance(0);bounded.type('characters','한'.repeat(2666));bounded.type('characters','글'.repeat(2666));
  assert.equal(bounded.context.directQueue.length,2);assert.ok(bounded.context.directQueue.every(item=>Buffer.byteLength(item.value)<=8000));bounded.context.stopDirect();
}
console.log(JSON.stringify({passed:true,mode:baseline?'baseline':'candidate',typedCharacters:text.length,requests,latencyMS:{median:result.medianMS,p95:result.p95MS},scope:'Production queue/transport; simulated 400ms serial receiver, not measured Mac performance'}));
